-- 0039_delta_gamma_band.sql
--
-- Run this whole file in the Supabase SQL Editor after 0038_futures.sql.
--
-- The target delta band stops being two numbers somebody typed and becomes a
-- reading off the book itself:
--
--     band = +/- |Gp| x gamma_multiplier
--
-- recomputed every cycle, so it moves as gamma does. At a net gamma of 0.5 a
-- multiplier of 2 gives [-1, +1]; let gamma grow to 0.8 and the band is at
-- [-1.6, +1.6] on the next pass with nothing edited.
--
-- ---------------------------------------------------------------------------
-- Why gamma is the right thing to scale it by
-- ---------------------------------------------------------------------------
-- Gamma is the rate Dp itself moves at. A book with twice the gamma runs through
-- the same delta in half the underlying move, so holding it to the same fixed
-- band means correcting twice as often for behaviour that has not actually
-- changed. Tying the two puts the tolerance in units of "how fast will this book
-- breach" instead of in absolute delta.
--
-- Read the consequence before switching it on, because it cuts the other way
-- too: gamma is largest where the strikes are nearest the money, so a book being
-- run over gets a *wider* tolerance at exactly the moment Dp is moving fastest.
-- That is the intended behaviour of the rule as specified -- the band scales with
-- breach speed -- but it is the opposite of a risk limit. The margin guard from
-- 0031, not this, is what bounds the book.
--
-- ---------------------------------------------------------------------------
-- Off by default, and the fallback
-- ---------------------------------------------------------------------------
-- `gamma_multiplier` defaults to 0, which reads as off and leaves `band_low` and
-- `band_high` in force exactly as before. No existing account changes behaviour
-- until the number is moved. `band_low`/`band_high` are not dropped and are not
-- dead: they are the fallback whenever a derived band cannot be computed, which
-- is two real cases --
--
--     * a flat book, before the daily entry has run
--     * a book whose gamma has rounded to nothing
--
-- -- and in both a derived band would come out [0, 0], which every non-zero Dp
-- breaches. The engine would then "correct" a book it cannot measure. Falling
-- back to the typed pair is the only safe reading of a zero width.
--
-- The magnitude of Gp is used, not its signed value. This strategy only sells, so
-- its gamma is negative; a signed band would come out inverted, with `low` above
-- `high`, and the sign says which way the book is convex rather than how wide the
-- tolerance should be.
--
-- ---------------------------------------------------------------------------
-- What had to move
-- ---------------------------------------------------------------------------
-- `delta_chain` never carried gamma -- the engine had no use for it until now --
-- so the column is added and the chain builder inside `apply_delta_strategy`
-- populates it from the same `greeks` object it already reads delta out of. No
-- extra HTTP call: it was in the payload all along.
--
-- Gamma then becomes required on the same terms as delta. The engine already
-- refuses to act on a book with a leg whose delta has not arrived, because one
-- missing leg makes the whole sum meaningless; with a multiplier set the same is
-- true of gamma, since a leg absent from Gp moves the band by that leg's entire
-- share. So `v_missing` counts both.
--
-- The band is derived once per account per pass, ahead of the margin guard,
-- because the guard's side preference reads it too. Every branch that trades ends
-- in `continue`, so positions cannot change underneath that one reading.
--
-- `effectiveBand` in `src/lib/deltaStrategy.ts` is the same rule in TypeScript and
-- draws the readout. As with every rule here, the two copies have to be kept in
-- step by hand.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------
alter table public.delta_strategy_settings
  add column if not exists gamma_multiplier numeric(20, 8) not null default 0;

alter table public.delta_strategy_settings drop constraint if exists delta_gamma_mult_chk;
alter table public.delta_strategy_settings
  add constraint delta_gamma_mult_chk check (gamma_multiplier >= 0);

comment on column public.delta_strategy_settings.gamma_multiplier is
  'Band half-width as a multiple of |Gp|, recomputed each cycle. 0 = off, band_low/band_high stand.';

-- ---------------------------------------------------------------------------
-- 2. The chain carries gamma
-- ---------------------------------------------------------------------------
alter table public.delta_chain add column if not exists gamma numeric;

-- ---------------------------------------------------------------------------
-- 3. The book's net gamma
--
-- The exact shape of delta_book_dp (0033), against the same chain and with the
-- same all-or-nothing rule: one leg without a published gamma and the answer is
-- null, because a partial sum would understate the book and so narrow the band.
-- Scaled by the contract value, so it reads in the unit the band is set in.
-- ---------------------------------------------------------------------------
create or replace function public.delta_book_gp(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when count(*) filter (where c.gamma is null) > 0 then null::numeric
           else coalesce(sum(p.net_qty * c.gamma), 0) * coalesce(max(p.contract_value), 1)
         end
  from public.positions p
  left join public.delta_chain c on c.symbol = p.symbol
  where p.account_id = p_account and p.net_qty <> 0;
$$;

-- ---------------------------------------------------------------------------
-- 4. The band in force
--
-- One function so the rule lives in one place: the breach test, the landing
-- target and the margin cut's side preference all read the same two numbers.
-- Mirrors `effectiveBand` in src/lib/deltaStrategy.ts.
-- ---------------------------------------------------------------------------
create or replace function public.delta_band(
  p_low   numeric,
  p_high  numeric,
  p_mult  numeric,
  p_gp    numeric,
  out low  numeric,
  out high numeric
)
language plpgsql
immutable
as $$
declare
  v_width numeric;
begin
  low  := p_low;
  high := p_high;
  if p_mult is null or p_mult <= 0 or p_gp is null then
    return;
  end if;
  v_width := abs(p_gp) * p_mult;
  -- A zero width is a book with no gamma to measure, not a band of nothing.
  if v_width > 0 then
    low  := -v_width;
    high :=  v_width;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. The engine, reading the derived band
--
-- Otherwise unchanged from 0036: the chain insert gains gamma, `v_missing`
-- counts a missing gamma too, the band is derived once per account, and the six
-- reads of `s.band_low`/`s.band_high` become the derived pair.
-- ---------------------------------------------------------------------------
create or replace function public.apply_delta_strategy()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_tickers   jsonb;
  v_spot      numeric;
  r           record;
  s           record;
  v_phase     text;
  v_day       text;
  v_exp       text;
  v_legs      int;
  v_desc      text;
  v_dp        numeric;
  v_cv        numeric;
  v_missing   int;
  v_target    numeric;
  v_breach    text;
  -- The book's net gamma, and the band actually defended this cycle.
  v_gp        numeric;
  v_band_low  numeric;
  v_band_high numeric;
  v_rollside  text;
  v_sellside  text;
  v_used      int;
  v_leg       record;
  v_repl      record;
  v_pick      record;
  v_q         int;
  v_gap       numeric;
  v_acted     boolean;
  v_n         int := 0;
  -- Margin guard, per account.
  v_margin    numeric;
  v_equity    numeric;
  v_cap       numeric;
  v_goal      numeric;
  v_hold      boolean;
  v_cutside   text;
  v_short     numeric;
  v_perlot    numeric;
begin
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200
    and created > now() - interval '30 seconds'
    and content like '%"result":[%'
    and content like '%XAUT%'
    and (content::jsonb -> 'result' -> 0) ? 'greeks'
  order by created desc limit 1;

  if v_tickers is null then
    raise log 'apply_delta_strategy: no XAUT tickers reply inside 30s — standing down';
    return 0;
  end if;

  if not pg_try_advisory_xact_lock(hashtext('delta_strategy_engine')) then
    return 0;
  end if;

  delete from public.delta_chain;
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, gamma, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
         nullif(t -> 'greeks' ->> 'gamma', '')::numeric,
         nullif(t ->> 'spot_price', '')::numeric,
         nullif(t ->> 'mark_price', '')::numeric
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%'
  on conflict (symbol) do nothing;

  select max(spot_price) into v_spot from public.delta_chain where spot_price is not null;
  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no spot in the chain';
    return 0;
  end if;

  for r in
    select s2.*, a.user_id
    from public.delta_strategy_settings s2
    join public.accounts a on a.id = s2.account_id
    where s2.armed
  loop
    v_acted := false;
    select * into s from public.delta_strategy_settings where account_id = r.account_id;

    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    select phase, sday into v_phase, v_day
    from public.delta_session(s.session_open, s.session_close, s.trade_days);

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session closed: no entry stands for today, and flatten if anything is open
    --
    -- entered_day is cleared unconditionally, not just when a flatten fires. While
    -- the session is shut there is no entry for today by definition, and tying the
    -- clearing to "had a book to flatten" is what left an already-flat account
    -- refusing to enter when its session reopened.
    --
    -- The flatten sits ahead of the expiry check on purpose: a stale expiry must
    -- never strand an open book. Flattening reads the positions, not the setting.
    --
    -- It also sits ahead of the margin guard, and has to: the close flattens
    -- everything, which is a strictly stronger cut than the guard would make.
    if v_phase <> 'open' then
      if s.entered_day is not null then
        update public.delta_strategy_settings set entered_day = null
        where account_id = r.account_id;
      end if;

      if s.flattened_day is distinct from v_day
         and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        -- Read before the flatten: afterwards the book is empty and Δp is 0 by
        -- construction, which says nothing about what was being carried.
        select count(*) into v_legs
        from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        update public.delta_strategy_settings
        set flattened_day = v_day, touched_symbols = '{}', pass_open = false
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'flatten', v_spot, v_dp);

        raise log 'apply_delta_strategy: account % flattened % leg(s) at the close', r.account_id, v_legs;
        v_n := v_n + 1;
      end if;
      continue;
    end if;

    -- ---- The band this cycle defends -------------------------------------
    -- Derived once, here, rather than at each of the three places that read it:
    -- the margin cut needs it before the rebalance section has computed
    -- anything, and a band that differed between the cut's side preference and
    -- the breach test would be two rules wearing one name.
    --
    -- Positions cannot change between here and the rebalance below -- every
    -- branch that trades ends in `continue` -- so one reading stays correct for
    -- the whole pass.
    v_gp := public.delta_book_gp(r.account_id);
    select low, high into v_band_low, v_band_high
    from public.delta_band(s.band_low, s.band_high, s.gamma_multiplier, v_gp);

    -- ---- Margin: where this account stands before it is allowed to sell ----
    select margin, equity into v_margin, v_equity
    from public.delta_account_margin(r.account_id, v_spot);

    v_cap  := v_equity * s.margin_cap_pct / 100.0;
    v_goal := v_equity * s.margin_target_pct / 100.0;
    -- Wiped equity lands here too: at or below zero every threshold is at or
    -- below zero, so any open short is over it and the cut branch takes over.
    v_hold := s.margin_cap_pct > 0 and v_margin > v_goal;

    -- ---- Margin cut: over the cap, so nothing else runs this cycle ---------
    --
    -- Ahead of the expiry check deliberately. delta_close_leg reads the leg's own
    -- row in the chain, not the expiry the strategy trades, so a cut does not need
    -- a contract to be tradeable — and an unlisted or settled expiry standing the
    -- strategy down while the book is past its equity is precisely the failure
    -- this control exists to prevent. Only the session-close flatten outranks it,
    -- and that is a strictly larger cut.
    -- `v_margin > 0` is not redundant with the cap test: on a wiped account every
    -- threshold is negative, so a flat book would enter this branch, find nothing
    -- to cut and log it every couple of seconds. Nothing with zero blocked margin
    -- has anything to cut, so testing it costs no real case.
    if s.margin_cap_pct > 0 and v_margin > v_cap and v_margin > 0 then
      -- Δp only decides which side to prefer, so it is best-effort: one leg
      -- without a published greek makes the whole sum meaningless, and that
      -- leaves the walk ordering on ITM distance alone rather than standing down.
      v_dp := public.delta_book_dp(r.account_id);

      v_cutside := case when v_dp is null then null
                        when v_dp < v_band_low then 'call_options'
                        when v_dp > v_band_high then 'put_options' end;

      -- How much margin has to come off to reach the target, and the first leg
      -- to take it off. Ordered by side preference, then by how deep in the
      -- money it is.
      v_short := v_margin - v_goal;

      select p.symbol, p.net_qty, coalesce(p.contract_value, 1) as cv,
             coalesce(c.mark_price, c.best_ask, p.avg_entry_price::numeric) as mark
        into v_leg
      from public.positions p
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id and p.net_qty < 0
      order by (case when v_cutside is not null and p.contract_type = v_cutside then 0 else 1 end),
               (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                     else p.strike_price::numeric - v_spot end) desc
      limit 1;

      -- No short to cut: the margin is all long premium, which is already capped
      -- at what was paid and cannot be reduced by closing at a loss.
      if not found then
        raise log 'apply_delta_strategy: account % margin % over cap % but no short to cut',
          r.account_id, round(v_margin, 2), round(v_cap, 2);
        continue;
      end if;

      v_perlot := (0.01 * v_spot + v_leg.mark) * v_leg.cv;
      if v_perlot <= 0 then
        raise log 'apply_delta_strategy: account % cannot price margin on % — skipping cut',
          r.account_id, v_leg.symbol;
        continue;
      end if;

      -- Rounded up, unlike every other size here: a roll rounds down so a
      -- correction cannot overshoot the band, but a cut landing a hair above the
      -- target has resolved nothing and would just fire again. Capped at the leg,
      -- so the rest falls to the next cycle and the next leg — which is what keeps
      -- the booked loss to the smallest one that clears the breach.
      v_q := least(ceil(v_short / v_perlot)::int, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      -- No target: a cut answers to equity, not to the band.
      perform public.delta_reason(r.account_id, 'cut', v_spot, v_dp);

      raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
        r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
      v_n := v_n + 1;
      continue;
    end if;

    -- Expiry. A chosen date wins outright, honoured only while listed and
    -- unsettled; with none chosen, expiry_pick's nearest/next applies.
    if s.expiry_label is not null then
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label = s.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label ~ '^\d{6}$'
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      order by to_date(expiry_label, 'DDMMYY') asc
      offset (case when s.expiry_pick = 'next' then 1 else 0 end)
      limit 1;
      if v_exp is null then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
        group by expiry_label
        order by to_date(expiry_label, 'DDMMYY') asc limit 1;
      end if;
    end if;

    if v_exp is null then
      raise log 'apply_delta_strategy: account % — expiry % unavailable, standing down',
        r.account_id, coalesce(s.expiry_label, '(by rule)');
      continue;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    if s.entered_day is distinct from v_day then
      -- Held back in the hold zone: an entry is two fresh shorts, which is the
      -- last thing an account already near its cap should add. entered_day is
      -- left unset, so the entry is retried as soon as margin allows.
      if v_hold then
        raise log 'apply_delta_strategy: account % entry held — margin % over target % of equity %',
          r.account_id, round(v_margin, 2), round(v_goal, 2), round(v_equity, 2);
        continue;
      end if;

      -- Read before the sale, so the reason on the two new legs says what the
      -- book was before they joined it.
      v_dp := public.delta_book_dp(r.account_id);

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_desc := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot);
      if v_desc is null then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;

      perform public.delta_reason(r.account_id, 'entry', v_spot, v_dp);

      raise log 'apply_delta_strategy: account % opened the session — %', r.account_id, v_desc;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    -- Gamma is required on the same terms as delta: with a multiplier set it is
    -- what the band is made of, so a leg silently absent from it would move the
    -- band by that leg's whole share.
    select count(*) filter (where c.delta is null or c.gamma is null),
           coalesce(sum(p.net_qty * c.delta), 0),
           max(p.contract_value)
      into v_missing, v_dp, v_cv
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on greeks for % leg(s)', r.account_id, v_missing;
      continue;
    end if;

    -- Δp in qty (underlying) units, the unit the band is set in: net_qty counts
    -- venue lots, so the lot-sized delta sum is scaled by the contract value.
    -- Sizing below divides it back out, since a correction is still placed in lots
    -- — leaving the lot count it computes identical to before, only the breach
    -- threshold now reads in the trader's own delta unit.
    v_cv := coalesce(v_cv, 1);
    v_dp := v_dp * v_cv;

    v_breach := case when v_dp < v_band_low then 'low'
                     when v_dp > v_band_high then 'high' end;

    if v_breach is null then
      if s.pass_open then
        update public.delta_strategy_settings
        set pass_open = false, touched_symbols = '{}' where account_id = r.account_id;
      end if;
      continue;
    end if;

    if s.target_landing = 'mid' then
      v_target := (v_band_low + v_band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(v_band_low + s.band_buffer, (v_band_low + v_band_high) / 2);
    else
      v_target := greatest(v_band_high - s.band_buffer, (v_band_low + v_band_high) / 2);
    end if;

    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

    -- ---- S5.1/5.2: walk the ITM queue, most-ITM first ----------------------
    -- Runs in the hold zone as well. A roll closes q and sells q further out, so
    -- it does not grow the book and the replacement's lower mark makes it very
    -- slightly cheaper in margin; blocking it would strand the ITM queue exactly
    -- when the account can least afford an unmanaged in-the-money short.
    for v_leg in
      select p.id, p.symbol, p.net_qty, p.strike_price::numeric as strike, p.contract_value,
             p.product_id, c.delta, c.best_ask,
             case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end as itm_distance
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type = v_rollside
        and not (p.symbol = any (s.touched_symbols))
        and (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end) >= s.itm_trigger
      order by itm_distance desc
    loop
      if v_used >= s.max_rolls then
        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'exit', v_spot, v_dp, v_target);

        raise log 'apply_delta_strategy: account % exit-only — closed % in full', r.account_id, v_leg.symbol;
        v_acted := true;
        exit;
      end if;

      select * into v_repl from public.delta_pick_premium(
        v_exp, v_rollside, s.entry_premium, 0, s.tie_break, v_leg.strike);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      v_q := floor(abs(v_target - v_dp) / (v_cv * v_gap) + 1e-9)::int;
      v_q := least(v_q, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      perform public.delta_sell(r.account_id, r.user_id, v_repl.symbol, v_q, v_spot);

      update public.delta_strategy_settings
      set touched_symbols = array_append(touched_symbols, v_leg.symbol),
          pass_open = true,
          rolls_used_call = rolls_used_call
            + case when v_rollside = 'call_options'
                        and (s.roll_counts = 'strike' or not s.pass_open) then 1 else 0 end,
          rolls_used_put = rolls_used_put
            + case when v_rollside = 'put_options'
                        and (s.roll_counts = 'strike' or not s.pass_open) then 1 else 0 end
      where account_id = r.account_id;

      -- One call, both rows: the leg bought back gets it as its exit reason, the
      -- leg sold in its place as its entry reason. They are the same decision.
      perform public.delta_reason(r.account_id, 'roll', v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % rolled % of % out to %',
        r.account_id, v_q, v_leg.symbol, v_repl.symbol;
      v_acted := true;
      exit;
    end loop;

    if v_acted then
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- S5.4: band correction, no ITM leg left to roll --------------------
    -- Picked at entry_premium, the same rule every other sale uses. The spec sized
    -- these off a separate delta range; a price rule already says which strike that
    -- is, and one rule on screen beats two that have to be kept in step. No
    -- `beyond`: a correction is a fresh sell, not a replacement for a leg.
    --
    -- This is the branch that grows the book without bound, and so the one the
    -- hold zone exists to stop. Δp stays outside the band for now; the cut branch
    -- is what brings it back once margin passes the cap, and it prefers exactly
    -- the side this sell would have corrected.
    if v_hold then
      raise log 'apply_delta_strategy: account % band correction held — margin % over target % of equity %',
        r.account_id, round(v_margin, 2), round(v_goal, 2), round(v_equity, 2);
      continue;
    end if;

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null::numeric);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike quoted to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    if v_q <= 0 then continue; end if;

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    perform public.delta_reason(r.account_id, 'band', v_spot, v_dp, v_target);

    raise log 'apply_delta_strategy: account % band correction — sold % of %',
      r.account_id, v_q, v_pick.symbol;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;
