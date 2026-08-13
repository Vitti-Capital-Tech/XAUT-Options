-- 0031_delta_margin_guard.sql
--
-- Run this whole file in the Supabase SQL Editor after 0030_delta_faster_apply_and_fresher_data.sql.
--
-- The delta engine had no idea what margin was. Grep 0012 through 0030 for
-- `margin`, `equity` or `balance` and you get nothing: every rule in it is about
-- Δp and premium, and none of them can tell an account with room to sell from
-- one that is already past its equity.
--
-- That gap is not cosmetic, because the strategy is sell-only. Three places open
-- risk — the daily entry, the roll replacement, and the fresh out-of-the-money
-- band correction in S5.4 — and only the last of those is unbounded. Every time
-- Δp leaves the band with the ITM queue exhausted, S5.4 sells another leg that
-- nothing ever pairs off. The book only shrinks on a take-profit, a stop, or the
-- session-close flatten. So margin ratchets up while unrealized losses pull
-- equity down, and the two meet.
--
-- This adds the missing control: when blocked margin passes equity, stop selling
-- and start cutting, choosing the legs whose exit also pulls Δp back toward the
-- band, and booking the loss rather than refusing to close a leg that is down.
--
-- ---------------------------------------------------------------------------
-- What "margin" means here
-- ---------------------------------------------------------------------------
--
-- The same thing it means in src/engine/paper.ts, so the engine and the screen
-- cannot disagree:
--
--   short leg:  (im_rate * spot + mark) * contract_value * lots
--   long leg:   avg_entry * contract_value * lots      -- risk capped at premium
--   equity:     cash_balance + unrealized
--
-- `im_rate` is 1%. That is not a guess and not the old 10% placeholder: Delta
-- publishes `initial_margin` per product and every live XAUT option reads '1'.
-- It is a constant here rather than a column because the engine's only feed is
-- /v2/tickers, which does not carry the field — /v2/products does, and adding a
-- second venue call to the poll to fetch a number that is uniform across the
-- chain would cost more than it settles. If Delta ever lists XAUT options at a
-- different rate, this is the line that has to move.
--
-- Delta's own figure will not match to the cent, and cannot:
--
--   * They raise the rate with size via `initial_margin_scaling_factor`
--     (0.000005, above a `max_leverage_notional` of $100,000). At one lot the
--     notional is spot * 0.001 ~ $4.45, so the scaling term is zero for any
--     position this strategy can realistically hold, and modelling it would be
--     dead code. This is why it is deliberately not modelled.
--   * They margin options as a portfolio — stress tested, with offsetting
--     between opposing legs. This sums each leg on its own, so a book with legs
--     on both sides is margined more conservatively here than there.
--
-- Conservative is the right direction for a control whose job is to cut.
--
-- ---------------------------------------------------------------------------
-- The two thresholds
-- ---------------------------------------------------------------------------
--
-- One threshold would flap: cut at 100%, land at 99.9%, sell again, cut again.
-- So the trigger and the release are separate, and the band between them is a
-- no-selling zone rather than a no-op.
--
--   margin > equity * margin_cap_pct       -> cut. Nothing else runs this cycle.
--   margin > equity * margin_target_pct    -> hold: no entry, no S5.4 sell.
--   otherwise                              -> unchanged.
--
-- Rolls keep running in the hold zone on purpose. A roll closes q lots and sells
-- q lots further out, so it is size-neutral and marginally margin-reducing (the
-- replacement is further from the money, so its mark is lower). Blocking it
-- would take away the one tool that manages Δp without growing the book, and
-- would strand the ITM queue exactly when it matters most.
--
-- `margin_cap_pct = 0` disables the guard outright, matching how take_profit_mark
-- and stop_loss_mark read zero.
--
-- ---------------------------------------------------------------------------
-- Which leg gets cut
-- ---------------------------------------------------------------------------
--
-- Most in-the-money first, on the side whose exit moves Δp toward the band.
--
-- Both halves matter. Most-ITM first is where the margin and the risk are
-- concentrated, so it frees the most per lot closed. The side preference is what
-- makes this a delta control and not just a deleveraging: Δp below the band is a
-- book too heavy in short calls, so closing a call is what lifts it — the same
-- reading `correctiveRollSide` already uses for the roll queue.
--
-- The preference is a sort key, not a filter. If the corrective side has nothing
-- left the walk falls through to the other side, because a margin breach has to
-- resolve whether or not the pleasant version of it is available.
--
-- With Δp unknown — greeks missing for a leg — the guard still cuts, ordered by
-- ITM distance alone. Standing down on a margin breach to wait for a greek is
-- the one failure this control exists to prevent.
--
-- Lots are sized to the shortfall, rounded up, and capped at what the leg holds:
-- enough to reach `margin_target_pct` and no more, so the realized loss is the
-- smallest one that clears the breach. One leg per cycle, which at a 2-second
-- apply converges in seconds and keeps every step priced off fresh marks — the
-- same reason every other rule here returns a single action.

-- ---------------------------------------------------------------------------
-- 1. The chain needs a mark price
-- ---------------------------------------------------------------------------
-- Margin and unrealized are both struck off the mark, the way Delta values a
-- position. /v2/tickers has carried `mark_price` all along; the chain simply
-- never stored it, because until now nothing server-side priced a position.
alter table public.delta_chain
  add column if not exists mark_price numeric;

-- ---------------------------------------------------------------------------
-- 2. Settings
-- ---------------------------------------------------------------------------
alter table public.delta_strategy_settings
  add column if not exists margin_cap_pct numeric(20, 8) not null default 100;

alter table public.delta_strategy_settings
  add column if not exists margin_target_pct numeric(20, 8) not null default 90;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'delta_margin_pct_chk') then
    alter table public.delta_strategy_settings
      add constraint delta_margin_pct_chk
      check (margin_cap_pct >= 0 and margin_target_pct >= 0
             and margin_target_pct <= margin_cap_pct);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Blocked margin and equity for an account
-- ---------------------------------------------------------------------------
-- Mirrors summarizeAccount/valuePosition in src/engine/paper.ts line for line.
--
-- The mark falls back the way the app's does: Delta's published mark, then the
-- price the position would actually exit at (a short buys back at the ask, a
-- long sells into the bid), then entry. A leg with no quote at all is valued at
-- entry, which contributes zero unrealized rather than dropping out of the sum —
-- silently omitting a leg would understate margin, which is the one error this
-- function must not make.
create or replace function public.delta_account_margin(p_account uuid, p_spot numeric)
returns table (margin numeric, equity numeric, unrealized numeric)
language sql
stable
security definer
set search_path = public
as $$
  with valued as (
    select
      p.net_qty,
      abs(p.net_qty)                          as lots,
      p.avg_entry_price::numeric              as avg_entry,
      coalesce(p.contract_value, 1)           as cv,
      coalesce(
        c.mark_price,
        case when p.net_qty > 0 then c.best_bid else c.best_ask end,
        p.avg_entry_price::numeric
      )                                       as mark
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = p_account and p.net_qty <> 0
  ),
  legs as (
    select
      case
        when net_qty > 0 then avg_entry * cv * lots
        else (0.01 * p_spot + mark) * cv * lots
      end as leg_margin,
      case
        when net_qty > 0 then (mark - avg_entry) * lots * cv
        else (avg_entry - mark) * lots * cv
      end as leg_unrealized
    from valued
  )
  select
    coalesce(sum(leg_margin), 0),
    (select cash_balance from public.accounts where id = p_account)
      + coalesce(sum(leg_unrealized), 0),
    coalesce(sum(leg_unrealized), 0)
  from legs;
$$;

revoke all on function public.delta_account_margin(uuid, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The engine, with the guard wired in
-- ---------------------------------------------------------------------------
-- Unchanged from 0030 except: the chain insert now carries mark_price, margin
-- and equity are read once per account before the entry, the cut branch sits
-- between the expiry check and the entry, and the entry and the S5.4 sell are
-- both gated on the hold zone.
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
  v_dp        numeric;
  v_cv        numeric;
  v_missing   int;
  v_target    numeric;
  v_breach    text;
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
                                  delta, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
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
        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        update public.delta_strategy_settings
        set flattened_day = v_day, touched_symbols = '{}', pass_open = false
        where account_id = r.account_id;
        v_n := v_n + 1;
      end if;
      continue;
    end if;

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
      select count(*) filter (where c.delta is null),
             coalesce(sum(p.net_qty * c.delta), 0) * coalesce(max(p.contract_value), 1)
        into v_missing, v_dp
      from public.positions p
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id and p.net_qty <> 0;

      if v_missing > 0 then v_dp := null; end if;

      v_cutside := case when v_dp is null then null
                        when v_dp < s.band_low then 'call_options'
                        when v_dp > s.band_high then 'put_options' end;

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

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_legs := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot);
      if v_legs < 2 then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    select count(*) filter (where c.delta is null),
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

    v_breach := case when v_dp < s.band_low then 'low'
                     when v_dp > s.band_high then 'high' end;

    if v_breach is null then
      if s.pass_open then
        update public.delta_strategy_settings
        set pass_open = false, touched_symbols = '{}' where account_id = r.account_id;
      end if;
      continue;
    end if;

    if s.target_landing = 'mid' then
      v_target := (s.band_low + s.band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(s.band_low + s.band_buffer, (s.band_low + s.band_high) / 2);
    else
      v_target := greatest(s.band_high - s.band_buffer, (s.band_low + s.band_high) / 2);
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
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
