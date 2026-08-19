-- 0042_notional_cap_per_strike.sql
--
-- Run this whole file in the Supabase SQL Editor after 0041_always_manage_delta.sql.
--
-- A ceiling on how much notional the strategy will stack into any one contract.
-- Past it, the sale moves to the next strike instead.
--
--     notional at a strike = spot x contract_value x |net_qty|
--     cap                  = max_notional_per_strike, default 95,000 USD
--
-- At a spot of 4,341 one lot is $4.34 of notional, so the cap is about 21,880
-- lots -- 21.9 XAUT -- per contract. At a qty of 10 XAUT a leg that is two sales
-- into one strike; the third goes elsewhere.
--
-- ---------------------------------------------------------------------------
-- Where it applies
-- ---------------------------------------------------------------------------
-- Every sale this strategy makes goes through `delta_pick_premium` -- the daily
-- entry, the roll replacement and the band correction all pick with the same
-- rule -- so the cap is one filter in one function rather than three separate
-- changes.
--
-- The rule stays "the strike quoted closest to entry_premium". The cap only
-- removes candidates that are already full, so the price rule is unchanged and
-- the sale simply lands on the next-nearest strike with room.
--
-- ---------------------------------------------------------------------------
-- Per contract, not per strike price
-- ---------------------------------------------------------------------------
-- `C-XAUT-4400` and `P-XAUT-4400` get 95,000 each. They are different
-- instruments carrying unrelated exposure, and the strategy sells calls above
-- spot and puts below it, so a strike number is never short on both sides except
-- transiently after spot has moved through it.
--
-- ---------------------------------------------------------------------------
-- Partial fills, and why the picker returns room
-- ---------------------------------------------------------------------------
-- `delta_pick_premium` now returns `room_lots` alongside the strike: how many
-- more lots that contract can take before the cap. Callers size as they always
-- did and then trim to it, so a sale that does not fit is not skipped -- it sells
-- what fits and the next cycle continues from the next strike. Delta keeps being
-- managed, which is the whole reason the hold zone went in 0041.
--
-- `room_lots` is null when the cap is off, and `least` ignores nulls, so an
-- account with `max_notional_per_strike = 0` sizes exactly as it did before.
--
-- ---------------------------------------------------------------------------
-- What it does not do
-- ---------------------------------------------------------------------------
-- It governs where new sales go. Nothing is closed because a strike drifted past
-- the cap on a spot move -- notional is `spot x cv x qty` and spot is not
-- something the book chose. A strike over the cap simply stops receiving.
--
-- The entry trims *both* legs to the smaller of the two rooms rather than
-- selling different sizes. Symmetric or not at all is the invariant that entry
-- has always had, and a cap is not a reason to open a directional position.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------
alter table public.delta_strategy_settings
  add column if not exists max_notional_per_strike numeric(20, 8) not null default 95000;

alter table public.delta_strategy_settings drop constraint if exists delta_max_notional_chk;
alter table public.delta_strategy_settings
  add constraint delta_max_notional_chk check (max_notional_per_strike >= 0);

comment on column public.delta_strategy_settings.max_notional_per_strike is
  'USD notional ceiling per contract. A sale that would pass it moves to the next strike. 0 = no cap.';

-- ---------------------------------------------------------------------------
-- 2. The strike picker, now aware of what is already held
--
-- Dropped rather than replaced: the signature and the return type both change,
-- and `create or replace` cannot alter a function's return columns.
--
-- `room_lots` is `floor(cap / (spot x contract_value)) - |net_qty|`, floored at
-- zero, and null when there is no cap to apply. Strikes with no room left are
-- dropped from the candidate set entirely, which is what makes the pick fall
-- through to the next-nearest premium on its own.
-- ---------------------------------------------------------------------------
drop function if exists public.delta_pick_premium(text, text, numeric, numeric, text, numeric);

create or replace function public.delta_pick_premium(
  p_exp     text,
  p_kind    text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_beyond  numeric,
  p_account uuid    default null,
  p_cap     numeric default 0,
  p_spot    numeric default null
)
returns table (symbol text, strike numeric, premium numeric, delta numeric, room_lots int)
language sql
stable
as $$
  with priced as (
    select c.symbol, c.strike, c.best_bid as premium, c.delta, c.contract_value,
           coalesce(abs(pos.net_qty), 0) as held
    from public.delta_chain c
    left join public.positions pos
           on pos.account_id = p_account and pos.symbol = c.symbol
    where c.expiry_label = p_exp
      and c.contract_type = p_kind
      and c.best_bid is not null
      and c.delta is not null
      -- S6: nothing is ever sold below the floor.
      and c.best_bid >= p_floor
      and (p_beyond is null
           or (p_kind = 'call_options' and c.strike > p_beyond)
           or (p_kind = 'put_options'  and c.strike < p_beyond))
  ),
  candidates as (
    select p.symbol, p.strike, p.premium, p.delta,
           case when p_cap > 0 and coalesce(p_spot, 0) > 0 and coalesce(p.contract_value, 0) > 0
                then greatest(0, floor(p_cap / (p_spot * p.contract_value))::int - p.held)
           end as room_lots
    from priced p
  ),
  open_strikes as (
    -- No cap, or room left. A full strike is not a candidate, which is the whole
    -- mechanism: the ranking below then lands on the next-nearest premium.
    select * from candidates c where c.room_lots is null or c.room_lots > 0
  ),
  -- pri 0 is the requested tie-break, pri 1 the absolute-closest fallback for
  -- when a one-sided rule finds nothing. An explicit ordering, because UNION ALL
  -- does not promise to return its branches in order.
  ranked as (
    select c.*, 0 as pri, c.premium - p_entry as nearness
    from open_strikes c where p_tie = 'above' and c.premium >= p_entry
    union all
    select c.*, 0, p_entry - c.premium
    from open_strikes c where p_tie = 'below' and c.premium <= p_entry
    union all
    select c.*, 1, abs(c.premium - p_entry) from open_strikes c
  )
  -- Every reference qualified: the RETURNS TABLE columns are parameters in this
  -- scope, and a bare `symbol` here is ambiguous against them.
  select k.symbol, k.strike, k.premium, k.delta, k.room_lots
  from ranked k order by k.pri asc, k.nearness asc limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 3. The daily entry, trimmed to the room both legs have
--
-- Otherwise the 0033 function. Both legs take the smaller of the two rooms, so a
-- capped entry stays symmetric; selling 21,880 calls against 10,000 puts because
-- one strike happened to be fuller would open exactly the directional position
-- the symmetric rule exists to prevent.
-- ---------------------------------------------------------------------------
drop function if exists public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, numeric, numeric);

create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_qty numeric, p_spot numeric,
                                                   p_cap numeric default 0)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  p        record;
  v_before numeric;
  v_after  numeric;
  v_lots_c int;
  v_lots_p int;
  v_room   int;
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie,
                                                 null, p_account, p_cap, p_spot);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie,
                                                 null, p_account, p_cap, p_spot);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor with room under the cap', p_floor;
    return null;
  end if;

  -- XAUT to lots, per leg, off that contract's own value. A missing or zero
  -- contract_value falls back to one lot rather than sizing off a guess.
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_c from public.delta_chain where symbol = c.symbol;
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_p from public.delta_chain where symbol = p.symbol;

  -- The tighter of the two rooms, applied to both. `least` ignores nulls, so an
  -- unset cap leaves this at the sizes above.
  v_room := least(c.room_lots, p.room_lots);
  if v_room is not null then
    v_lots_c := least(v_lots_c, v_room);
    v_lots_p := least(v_lots_p, v_room);
  end if;

  if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
    raise log 'delta_sell_entry: qty % sized to no lots', p_qty;
    return null;
  end if;

  -- One block, one implicit savepoint. delta_sell swallows a failed fill and
  -- returns normally, so a leg that did not open is detected by the position not
  -- moving and turned into an exception here — which unwinds everything this block
  -- did, including the other leg's fill.
  begin
    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    perform public.delta_sell(p_account, p_user, c.symbol, v_lots_c, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    -- Selling makes net_qty more negative, so a fill moves this the other way.
    if v_before - v_after <= 0 then
      raise exception 'call leg % did not fill', c.symbol;
    end if;

    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    perform public.delta_sell(p_account, p_user, p.symbol, v_lots_p, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    if v_before - v_after <= 0 then
      raise exception 'put leg % did not fill', p.symbol;
    end if;
  exception when others then
    raise log 'delta_sell_entry: % — entry rolled back, nothing left open', sqlerrm;
    return null;
  end;

  return format('%s × %sC @ $%s / %s × %sP @ $%s',
                v_lots_c, round(c.strike, 0), round(c.premium, 2),
                v_lots_p, round(p.strike, 0), round(p.premium, 2));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. The engine, passing the cap into every pick and trimming to the room
--
-- Otherwise unchanged from 0041.
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
      -- No margin gate here. An entry only ever runs on a book the previous
      -- close has flattened, so blocked margin is at or near zero when it fires;
      -- the gate that used to sit here was guarding a state the session clock
      -- already makes unreachable. Above the cap the cut branch returned long ago.

      -- Read before the sale, so the reason on the two new legs says what the
      -- book was before they joined it.
      v_dp := public.delta_book_dp(r.account_id);

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_desc := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot,
                                        s.max_notional_per_strike);
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
    -- A roll closes q and sells q further out, so it does not grow the book and
    -- the replacement's lower mark makes it very slightly cheaper in margin. It
    -- ran even under the old hold zone, for the reason that zone is now gone
    -- entirely: stranding the ITM queue when the account can least afford an
    -- unmanaged in-the-money short is the wrong trade-off at any margin level.
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
        v_exp, v_rollside, s.entry_premium, 0, s.tie_break, v_leg.strike,
        r.account_id, s.max_notional_per_strike, v_spot);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      v_q := floor(abs(v_target - v_dp) / (v_cv * v_gap) + 1e-9)::int;
      -- Never more than the leg being replaced holds, and never more than the
      -- replacement strike has room for. `least` ignores nulls, so an unset cap
      -- (room_lots null) leaves the size exactly as it was.
      v_q := least(v_q, abs(v_leg.net_qty), v_repl.room_lots);
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
    -- This is the branch that grows the book without bound, and it now runs at
    -- any margin below the cap. It used to be frozen above margin_target_pct,
    -- which left a breached band uncorrected through that whole zone -- the
    -- strategy's one job, not done, in precisely the state where Dp is most
    -- likely to be moving. The cut branch answers the risk instead, and it prefers
    -- exactly the side this sell would have corrected, so the two pull the same
    -- way rather than against each other.

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null::numeric,
      r.account_id, s.max_notional_per_strike, v_spot);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike with room to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    -- Sell what fits. The picker has already skipped strikes with no room at all,
    -- so this only trims the last partial one, and the next cycle carries on from
    -- the strike after it.
    v_q := least(v_q, v_pick.room_lots);
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
