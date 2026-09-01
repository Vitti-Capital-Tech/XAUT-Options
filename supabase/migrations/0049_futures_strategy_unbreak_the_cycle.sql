-- 0049_futures_strategy_unbreak_the_cycle.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0048_futures_strategy_atm_shift_and_pairs.sql.
--
-- 0048 shipped four faults that between them stopped the engine dead. Each one
-- aborts apply_delta_strategy() mid-transaction, and because pg_cron calls that
-- function as the whole statement, an abort rolls back the `last_cycle = now()`
-- stamp with it — so the engine retried, threw again, and never got past the
-- first armed account. From the tab that looks like a strategy that is switched
-- on and doing nothing, at random.
--
--   1. delta_sell_entry called public.delta_qty_to_lots(qty, symbol), which does
--      not exist and never has: 0048 replaced 0042's inline lot sizing with a
--      call to a helper it did not create. plpgsql resolves function calls at
--      run time, so the migration applied cleanly and then raised
--      undefined_function on the first entry attempt of every armed account.
--      Nothing below the entry branch ever ran — no ATM exit, no empty-wing
--      flatten, no futures hedge, no band correction, no session-close flatten.
--
--   2. 0048 added a tenth parameter (p_ceil) to delta_pick_premium with
--      `create or replace`. A different argument count is a new overload, not a
--      replacement, so 0042's nine-parameter version is still in the database
--      beside it. The three nine-argument call sites in the engine — the ATM
--      shift, the roll replacement and the band correction — then match both
--      candidates and raise "function ... is not unique". Same story for
--      delta_sell_entry, which went from nine parameters to eleven.
--
--   3. The 0048 rewrite of delta_sell_entry dropped 0019's all-or-nothing fill
--      check. delta_sell swallows a failed fill and returns void, so without the
--      before/after net_qty comparison the entry reported "sold ..." whether or
--      not anything opened: the engine stamped entered_day and wrote the day off
--      with an empty book — or worse, with one leg of the pair open and the
--      other not, a naked directional short the strategy never intends to hold.
--
--   4. An entry that could not fill did `continue`, skipping the rest of the
--      cycle. So a book opened by hand — which is what a trader does when the
--      engine will not open one — was never managed: entered_day stayed null,
--      the engine went back to trying to enter on every cycle, and the band was
--      left alone all day.
--
-- This migration fixes all four, plus the stale Δp the ATM branch reported.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Drop the superseded overloads
-- ---------------------------------------------------------------------------
-- Every migration in this series that widened one of these dropped the previous
-- signature in the same file — 0019, 0024, 0033 and 0042 all do. 0048 is the one
-- that did not, which is why 0042's nine-parameter versions are still live
-- alongside it and a nine-argument pick matches two candidates.
--
-- The first two lines are the ones that actually bite today. The rest are the
-- earlier signatures from across the series: each was already dropped by the
-- migration that superseded it, so these are no-ops on a database that has run
-- the whole sequence — they are here so the check at the foot of this file
-- cannot trip over a signature left behind by a hand-patched database.
drop function if exists public.delta_pick_premium(
  text, text, numeric, numeric, text, numeric, uuid, numeric, numeric);          -- 0042
drop function if exists public.delta_sell_entry(
  uuid, uuid, text, numeric, numeric, text, numeric, numeric, numeric);          -- 0042
drop function if exists public.delta_pick_premium(
  text, text, numeric, numeric, text, numeric);                                  -- 0012
drop function if exists public.delta_sell_entry(
  uuid, uuid, text, numeric, numeric, text, int, numeric);                       -- 0012, 0019
drop function if exists public.delta_sell_entry(
  uuid, uuid, text, numeric, numeric, text, int, numeric, numeric);              -- 0021
drop function if exists public.delta_sell_entry(
  uuid, uuid, text, numeric, numeric, text, numeric, numeric);                   -- 0024, 0033

-- ---------------------------------------------------------------------------
-- 2. delta_pick_premium_ranked: the picker's ranking, N strikes deep
-- ---------------------------------------------------------------------------
-- The entry needs more than the single best strike once pairs_count is above
-- one, and the tab's readout already shows what that should look like:
-- pickMultipleByPremium in src/lib/deltaStrategy.ts ranks every quoted strike by
-- the same rule and takes the top N *distinct* ones, one per pair. The engine had
-- no way to say that — delta_pick_premium is `limit 1` — so this exposes the
-- ranking the picker was already computing and throwing away.
--
-- delta_pick_premium then becomes a thin `rank = 1` wrapper over it. That keeps
-- one ranking rule in one place, and keeps the picker's signature exactly as
-- 0048 left it, so the ATM shift, the roll replacement and the band correction
-- carry on calling it untouched.
--
-- The dedup is the one thing the `limit 1` version did not need: `ranked` lists a
-- strike twice when it satisfies the tie-break — once at pri 0 and again in the
-- catch-all at pri 1. At one row deep the pri-0 copy always won and the
-- duplicate was invisible. N rows deep it would hand the same strike back as
-- both pair one and pair two, so `distinct on (symbol)` keeps each strike's best
-- ranking and drops the shadow.
create or replace function public.delta_pick_premium_ranked(
  p_exp     text,
  p_kind    text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_beyond  numeric,
  p_account uuid    default null,
  p_cap     numeric default 0,
  p_spot    numeric default null,
  p_ceil    numeric default 0,
  p_limit   int     default 1
)
returns table (rank int, symbol text, strike numeric, premium numeric,
               delta numeric, room_lots int)
language sql
stable
as $$
  with bounds as (
    select case when p_floor > 0 and p_ceil > 0 then least(p_floor, p_ceil)
                when p_floor > 0 then p_floor
                else 0 end as floor_val,
           case when p_floor > 0 and p_ceil > 0 then greatest(p_floor, p_ceil)
                when p_ceil > 0 then p_ceil
                else 0 end as ceil_val
  ),
  priced as (
    select c.symbol, c.strike, c.best_bid as premium, c.delta, c.contract_value,
           coalesce(abs(pos.net_qty), 0) as held
    from public.delta_chain c
    cross join bounds b
    left join public.positions pos
           on pos.account_id = p_account and pos.symbol = c.symbol
    where c.expiry_label = p_exp
      and c.contract_type = p_kind
      and c.best_bid is not null
      and c.delta is not null
      and (b.floor_val <= 0 or c.best_bid >= b.floor_val)
      and (b.ceil_val <= 0 or c.best_bid <= b.ceil_val)
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
    select * from candidates c where c.room_lots is null or c.room_lots > 0
  ),
  ranked as (
    select c.*, 0 as pri, c.premium - p_entry as nearness
    from open_strikes c where p_tie = 'above' and c.premium >= p_entry
    union all
    select c.*, 0, p_entry - c.premium
    from open_strikes c where p_tie = 'below' and c.premium <= p_entry
    union all
    select c.*, 1, abs(c.premium - p_entry) from open_strikes c
  ),
  best as (
    select distinct on (k.symbol) k.*
    from ranked k
    order by k.symbol, k.pri asc, k.nearness asc
  )
  select (row_number() over (order by b.pri asc, b.nearness asc))::int,
         b.symbol, b.strike, b.premium, b.delta, b.room_lots
  from best b
  order by b.pri asc, b.nearness asc
  limit greatest(1, coalesce(p_limit, 1));
$$;
revoke all on function public.delta_pick_premium_ranked(
  text, text, numeric, numeric, text, numeric, uuid, numeric, numeric, numeric, int)
  from public, anon, authenticated;

-- The single-strike picker every other branch uses, now expressed as the top of
-- the ranking above. Signature and result columns are exactly 0048's.
create or replace function public.delta_pick_premium(
  p_exp     text,
  p_kind    text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_beyond  numeric,
  p_account uuid    default null,
  p_cap     numeric default 0,
  p_spot    numeric default null,
  p_ceil    numeric default 0
)
returns table (symbol text, strike numeric, premium numeric, delta numeric, room_lots int)
language sql
stable
as $$
  select k.symbol, k.strike, k.premium, k.delta, k.room_lots
  from public.delta_pick_premium_ranked(p_exp, p_kind, p_entry, p_floor, p_tie,
                                        p_beyond, p_account, p_cap, p_spot, p_ceil, 1) k
  where k.rank = 1;
$$;

-- ---------------------------------------------------------------------------
-- 3. delta_sell_entry: real lot sizing, real pairs, all-or-nothing again
-- ---------------------------------------------------------------------------
-- Lot sizing is inline again, off each leg's own contract_value, the way it was
-- before 0048 reached for a helper that was never written.
--
-- p_pairs is now actually honoured. 0048 accepted it and ignored it, so the
-- Pairs control on the tab did nothing at all. Pair i is the i-th ranked strike
-- on each side — the same N distinct strikes, in the same order, that the tab's
-- readout lists before the entry fires. Both sides are ranked once, up front, and
-- joined on rank, so the strike a pair opens at is not moved by what an earlier
-- pair in the same entry just sold.
--
-- Every pair is atomic in its own right. The first pair is the entry: if it
-- cannot be opened in full the function returns null, nothing is left open and
-- the day is not stamped, so the next refresh tries again. Later pairs are
-- best-effort — a chain that can only fill two of three pairs should open two
-- rather than wedge the session — and each still opens whole or not at all, so
-- no pair can leave a naked leg behind.
create or replace function public.delta_sell_entry(
  p_account uuid,
  p_user    uuid,
  p_exp     text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_qty     numeric,
  p_spot    numeric,
  p_cap     numeric default 0,
  p_pairs   int     default 1,
  p_ceil    numeric default 0
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  pair     record;
  v_before numeric;
  v_after  numeric;
  v_lots_c int;
  v_lots_p int;
  v_room   int;
  v_want   int := greatest(1, coalesce(p_pairs, 1));
  v_done   int := 0;
  v_seen   int := 0;
  v_ok     boolean;
  v_desc   text := '';
begin
  -- Both sides ranked to the requested depth and joined on rank: pair 1 is the
  -- best call against the best put, pair 2 the second against the second, and so
  -- on — which is the pairing the readout draws. The inner join is what keeps the
  -- entry symmetric: a side that ranks fewer strikes than the other simply ends
  -- the list, rather than pairing a call with a put from a different rank.
  --
  -- Ranked once, before the first sale. delta_pick_premium_ranked is `stable`, so
  -- it is read against this statement's snapshot and the strikes do not shuffle
  -- underneath the loop as earlier pairs fill and consume their own room.
  for pair in
    select ca.rank,
           ca.symbol as c_symbol, ca.strike as c_strike,
           ca.premium as c_premium, ca.room_lots as c_room,
           pu.symbol as p_symbol, pu.strike as p_strike,
           pu.premium as p_premium, pu.room_lots as p_room
    from public.delta_pick_premium_ranked(p_exp, 'call_options', p_entry, p_floor,
                                          p_tie, null, p_account, p_cap, p_spot,
                                          p_ceil, v_want) ca
    join public.delta_pick_premium_ranked(p_exp, 'put_options', p_entry, p_floor,
                                          p_tie, null, p_account, p_cap, p_spot,
                                          p_ceil, v_want) pu on pu.rank = ca.rank
    order by ca.rank
  loop
    v_seen := v_seen + 1;

    -- XAUT to lots, per leg, off that contract's own value. A missing or zero
    -- contract_value falls back to one lot rather than sizing off a guess.
    select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
      into v_lots_c from public.delta_chain where symbol = pair.c_symbol;
    select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
      into v_lots_p from public.delta_chain where symbol = pair.p_symbol;

    -- The tighter of the two rooms, applied to both. `least` ignores nulls, so
    -- an unset cap leaves this at the sizes above.
    v_room := least(pair.c_room, pair.p_room);
    if v_room is not null then
      v_lots_c := least(v_lots_c, v_room);
      v_lots_p := least(v_lots_p, v_room);
    end if;

    if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
      raise log 'delta_sell_entry: pair %/% — qty % sized to no lots', pair.rank, v_want, p_qty;
      exit;
    end if;

    -- One block, one implicit savepoint. delta_sell swallows a failed fill and
    -- returns normally, so a leg that did not open is detected by the position
    -- not moving and turned into an exception here — which unwinds everything
    -- this block did, including the other leg's fill.
    --
    -- The outcome leaves the block in v_ok rather than exiting the loop from
    -- inside the handler: an exception rolls back the block's database work but
    -- leaves plpgsql variables as they stood, so a flag set on the last line is
    -- a reliable "both legs landed" and needs no reasoning about control flow
    -- out of a handler.
    v_ok := false;
    begin
      v_before := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = pair.c_symbol), 0);
      perform public.delta_sell(p_account, p_user, pair.c_symbol, v_lots_c, p_spot);
      v_after  := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = pair.c_symbol), 0);
      -- Selling makes net_qty more negative, so a fill moves this the other way.
      if v_before - v_after <= 0 then
        raise exception 'call leg % did not fill', pair.c_symbol;
      end if;

      v_before := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = pair.p_symbol), 0);
      perform public.delta_sell(p_account, p_user, pair.p_symbol, v_lots_p, p_spot);
      v_after  := coalesce((select net_qty from public.positions
                            where account_id = p_account and symbol = pair.p_symbol), 0);
      if v_before - v_after <= 0 then
        raise exception 'put leg % did not fill', pair.p_symbol;
      end if;

      v_ok := true;
    exception when others then
      raise log 'delta_sell_entry: pair %/% — % — pair rolled back, nothing left open',
        pair.rank, v_want, sqlerrm;
    end;

    if not v_ok then
      exit;
    end if;

    v_done := v_done + 1;
    v_desc := v_desc
      || case when v_desc = '' then '' else ', ' end
      || format('%s × %sC @ $%s / %s × %sP @ $%s',
                v_lots_c, round(pair.c_strike, 0), round(pair.c_premium, 2),
                v_lots_p, round(pair.p_strike, 0), round(pair.p_premium, 2));
  end loop;

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open, so an empty ranking on either side opens nothing.
  if v_seen = 0 then
    raise log 'delta_sell_entry: no symmetric pair in [%, %] with room under the cap',
      p_floor, p_ceil;
  end if;

  -- No pair at all is a failed entry: the caller must not stamp the day, so the
  -- next refresh tries again rather than writing the session off.
  if v_done = 0 then
    return null;
  end if;

  return case when v_done = v_want then v_desc
              else format('%s of %s pairs — %s', v_done, v_want, v_desc) end;
end;
$$;
revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text,
                                               numeric, numeric, numeric, int, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The engine
-- ---------------------------------------------------------------------------
-- Unchanged from 0048 except for the three fixes marked `0049:` inline —
-- adopting a book opened by hand, a Δp that is actually this account's, and a
-- failed entry that no longer takes the rest of the cycle down with it.
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
  v_gp        numeric;
  v_band_low  numeric;
  v_band_high numeric;
  v_mode      text;
  v_need      numeric;
  v_rollside  text;
  v_sellside  text;
  v_used      int;
  v_leg       record;
  v_repl      record;
  v_pick      record;
  v_q         int;
  v_gap       numeric;
  v_acted     boolean;
  v_adopted   boolean;
  v_n         int := 0;
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

  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, gamma, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         null,
         'PERP',
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         1,
         0,
         nullif(t ->> 'spot_price', '')::numeric,
         nullif(t ->> 'mark_price', '')::numeric
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'contract_type') = 'perpetual_futures'
  on conflict (symbol) do nothing;

  select max(spot_price) into v_spot from public.delta_chain where spot_price is not null;
  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no spot in the chain';
    return 0;
  end if;

  for r in
    select s2.*, a.user_id, a.kind
    from public.delta_strategy_settings s2
    join public.accounts a on a.id = s2.account_id
    where s2.armed
  loop
    v_acted   := false;
    v_adopted := false;
    -- 0049: cleared per account. The ATM branch reads v_dp without setting it,
    -- so whatever the previous account left here was being written into this
    -- account's fill reason. Null at least reads as "—" rather than as another
    -- book's number.
    v_dp      := null;
    v_mode    := case when r.kind = 'futures' then 'futures' else 'options' end;
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
          shifts_used_call = 0, shifts_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session closed: flatten -------------------------------------------
    if v_phase <> 'open' then
      if s.entered_day is not null then
        update public.delta_strategy_settings set entered_day = null
        where account_id = r.account_id;
      end if;

      if s.flattened_day is distinct from v_day
         and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
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

    -- ---- The band this cycle defends ---------------------------------------
    if v_mode = 'futures' then
      v_gp        := null;
      v_band_low  := s.band_low;
      v_band_high := s.band_high;
    else
      v_gp := public.delta_book_gp(r.account_id);
      select low, high into v_band_low, v_band_high
      from public.delta_band(s.band_low, s.band_high, s.gamma_multiplier, v_gp);
    end if;

    -- ---- Margin guard: over the cap ----------------------------------------
    select margin, equity into v_margin, v_equity
    from public.delta_account_margin(r.account_id, v_spot);

    v_cap  := v_equity * s.margin_cap_pct / 100.0;
    v_goal := v_equity * s.margin_target_pct / 100.0;

    if s.margin_cap_pct > 0 and v_margin > v_cap and v_margin > 0 then
      v_dp := public.delta_book_dp(r.account_id);
      v_cutside := case
        when v_dp is null then null
        when v_dp < (v_band_low + v_band_high) / 2 then 'call_options'
        when v_dp > (v_band_low + v_band_high) / 2 then 'put_options'
      end;

      v_short := v_margin - v_goal;
      select p.symbol, p.net_qty, coalesce(p.contract_value, 1) as cv,
             coalesce(c.mark_price, c.best_ask, p.avg_entry_price::numeric) as mark
        into v_leg
      from public.positions p
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type <> 'perpetual_futures'
      order by (case when v_cutside is not null and p.contract_type = v_cutside then 0 else 1 end),
               (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                     else p.strike_price::numeric - v_spot end) desc
      limit 1;

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

      v_q := least(ceil(v_short / v_perlot)::int, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      perform public.delta_reason(r.account_id, 'cut', v_spot, v_dp);

      raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
        r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Expiry selection --------------------------------------------------
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

    -- ---- 0049: adopt a book that is already open ---------------------------
    -- The entry branch below is gated on entered_day, which only the engine's
    -- own entry ever stamps. So a book the trader opened by hand — the usual
    -- response to an engine that will not open one — left the engine stuck in
    -- the entry branch every cycle, never once reaching the ATM check, the
    -- hedge or the band correction. Two-sided and short is the shape this
    -- strategy manages, whoever sold it, so the day is stamped and the cycle
    -- carries on into management.
    --
    -- Deliberately both sides: a one-sided book is not this strategy's position,
    -- and adopting one would hand it straight to the empty-wing rule, which
    -- would close a leg the trader put on for their own reasons.
    if s.entered_day is distinct from v_day
       and exists (select 1 from public.positions
                   where account_id = r.account_id and contract_type = 'call_options' and net_qty < 0)
       and exists (select 1 from public.positions
                   where account_id = r.account_id and contract_type = 'put_options' and net_qty < 0) then
      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
      v_adopted := true;
      raise log 'apply_delta_strategy: account % adopted an already-open two-sided book', r.account_id;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    if s.entered_day is distinct from v_day then
      v_dp := public.delta_book_dp(r.account_id);

      v_desc := public.delta_sell_entry(
        r.account_id, r.user_id, v_exp, s.entry_premium,
        coalesce(s.entry_premium_min, 0), s.tie_break, s.qty, v_spot,
        s.max_notional_per_strike,
        case when v_mode = 'futures' then coalesce(s.pairs_count, 1) else 1 end,
        coalesce(s.entry_premium_max, 0)
      );

      -- 0049: a failed entry no longer takes the rest of the cycle with it.
      -- It used to `continue` unconditionally, so on a day the entry could not
      -- fill nothing else the engine does ran at all. The day stays unstamped
      -- either way — that is what makes the next refresh retry — but a book that
      -- is already open still gets managed while the entry keeps trying.
      if v_desc is null then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh', r.account_id;
        if not exists (select 1 from public.positions
                       where account_id = r.account_id and net_qty <> 0) then
          continue;
        end if;
      else
        update public.delta_strategy_settings
        set entered_day = v_day, flattened_day = null
        where account_id = r.account_id;
        select * into s from public.delta_strategy_settings where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'entry', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % opened the session — %', r.account_id, v_desc;
        v_n := v_n + 1;
        continue;
      end if;
    end if;

    -- ---- Empty side check (Futures strategy) --------------------------------
    -- If there is no position on either side (Call or Put), close all remaining positions.
    -- 0049: skipped on the cycle that adopted the book, so a book taken over
    -- mid-flight is read once more with fresh eyes before anything is closed.
    if v_mode = 'futures' and not v_adopted and s.entered_day = v_day
       and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
      if not exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'call_options' and net_qty < 0)
         or not exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'put_options' and net_qty < 0) then
        select count(*) into v_legs from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        update public.delta_strategy_settings
        set touched_symbols = '{}', pass_open = false
        where account_id = r.account_id;
        perform public.delta_reason(r.account_id, 'empty_side_flatten', v_spot, v_dp);

        raise log 'apply_delta_strategy: account % wing empty — closed all % remaining leg(s)', r.account_id, v_legs;
        v_n := v_n + 1;
        continue;
      end if;
    end if;

    -- ---- ATM Exit & Shift (Futures strategy) --------------------------------
    if v_mode = 'futures' then
      -- 0049: this account's Δp, read before the branch that reports it. It was
      -- left at whatever the previous account in the loop happened to set.
      v_dp := public.delta_book_dp(r.account_id);

      for v_leg in
        select p.id, p.symbol, p.net_qty, p.contract_type, p.strike_price::numeric as strike,
               p.contract_value, p.product_id, c.delta,
               coalesce(c.best_ask, c.mark_price, p.avg_entry_price::numeric) as mark,
               case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                    else p.strike_price::numeric - v_spot end as itm_distance
        from public.positions p
        join public.delta_chain c on c.symbol = p.symbol
        where p.account_id = r.account_id
          and p.net_qty < 0
          and p.contract_type in ('call_options', 'put_options')
          and not (p.symbol = any (s.touched_symbols))
          and (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                    else p.strike_price::numeric - v_spot end) >= 0
        order by itm_distance desc
        limit 1
      loop
        v_used := case when v_leg.contract_type = 'call_options' then coalesce(s.shifts_used_call, 0)
                       else coalesce(s.shifts_used_put, 0) end;

        if v_used < coalesce(s.max_shifts, 1) then
          select * into v_repl from public.delta_pick_premium(
            v_exp, v_leg.contract_type, v_leg.mark * (coalesce(s.shift_pct, 50) / 100.0),
            0, s.tie_break, v_leg.strike, r.account_id, s.max_notional_per_strike, v_spot);

          if v_repl.symbol is not null then
            v_q := least(abs(v_leg.net_qty), coalesce(v_repl.room_lots, abs(v_leg.net_qty)));
            if v_q > 0 then
              perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
              perform public.delta_sell(r.account_id, r.user_id, v_repl.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set touched_symbols = array_append(touched_symbols, v_leg.symbol),
                  shifts_used_call = shifts_used_call + case when v_leg.contract_type = 'call_options' then 1 else 0 end,
                  shifts_used_put  = shifts_used_put  + case when v_leg.contract_type = 'put_options'  then 1 else 0 end
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'atm_shift', v_spot, v_dp);
              raise log 'apply_delta_strategy: account % ATM exit & shifted % of % to %',
                r.account_id, v_q, v_leg.symbol, v_repl.symbol;
              v_n := v_n + 1;
              v_acted := true;
              exit;
            end if;
          end if;
        end if;

        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'atm_exit', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % ATM exit-only — closed % in full', r.account_id, v_leg.symbol;
        v_n := v_n + 1;
        v_acted := true;
        exit;
      end loop;

      if v_acted then
        continue;
      end if;
    end if;

    -- ---- Net portfolio delta -----------------------------------------------
    select count(*) filter (where c.delta is null
                              or (v_mode = 'options' and c.gamma is null)),
           coalesce(sum(p.net_qty * c.delta), 0),
           max(p.contract_value)
      into v_missing, v_dp, v_cv
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on % for % leg(s)',
        r.account_id,
        case when v_mode = 'options' then 'greeks' else 'a delta' end,
        v_missing;
      continue;
    end if;

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

    -- ---- Futures hedge -----------------------------------------------------
    if v_mode = 'futures' then
      v_need := (v_target - v_dp) / v_cv;
      v_q := floor(abs(v_need) + 1e-9)::int;
      if v_q <= 0 then
        raise log 'apply_delta_strategy: account % Dp % breach is under one contract',
          r.account_id, round(v_dp, 2);
        continue;
      end if;

      perform public.delta_hedge(r.account_id, r.user_id,
                                 case when v_need > 0 then 'buy' else 'sell' end,
                                 v_q, v_spot, s.hedge_leverage);
      perform public.delta_reason(r.account_id,
                                 case when v_need > 0 then 'hedge_buy' else 'hedge_sell' end,
                                 v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % hedged — % % futures lots at Dp % toward %',
        r.account_id, case when v_need > 0 then 'bought' else 'sold' end, v_q,
        round(v_dp, 2), round(v_target, 2);
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Options mode rolls ------------------------------------------------
    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

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

      perform public.delta_reason(r.account_id, 'roll', v_spot, v_dp, v_target);
      raise log 'apply_delta_strategy: account % rolled % of % out to %',
        r.account_id, v_q, v_leg.symbol, v_repl.symbol;
      v_n := v_n + 1;
      v_acted := true;
      exit;
    end loop;

    if v_acted then continue; end if;

    -- ---- Options band correction -------------------------------------------
    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null,
      r.account_id, s.max_notional_per_strike, v_spot);

    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike with room to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    v_q := least(v_q, v_pick.room_lots);

    if s.margin_cap_pct > 0 then
      v_perlot := (0.01 * v_spot + v_pick.premium) * v_cv;
      if v_perlot > 0 then
        v_q := least(v_q, greatest(0, floor((v_cap - v_margin) / v_perlot))::int);
      end if;
    end if;

    if v_q <= 0 then
      continue;
    end if;

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    perform public.delta_reason(r.account_id, 'band', v_spot, v_dp, v_target);

    raise log 'apply_delta_strategy: account % band correction — sold % of %',
      r.account_id, v_q, v_pick.symbol;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;
revoke all on function public.apply_delta_strategy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sanity check
-- ---------------------------------------------------------------------------
-- Fails loudly here rather than silently at the open tomorrow. Both of the
-- ambiguities below were live after 0048 and are what the engine kept dying on,
-- and neither shows up until the branch that calls the function actually runs.
do $$
declare
  v_picks   int;
  v_entries int;
begin
  select count(*) into v_picks
  from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_pick_premium';
  if v_picks <> 1 then
    raise exception
      'delta_pick_premium has % definitions, expected exactly 1 — nine-argument calls stay ambiguous',
      v_picks;
  end if;

  select count(*) into v_entries
  from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_sell_entry';
  if v_entries <> 1 then
    raise exception 'delta_sell_entry has % definitions, expected exactly 1', v_entries;
  end if;

  -- The three functions the engine reaches for by name. Resolving them here is
  -- the cheap version of the failure that took 0048 down: an entry that raises
  -- undefined_function at 06:00 and takes the whole cycle with it.
  if to_regprocedure('public.delta_pick_premium_ranked(text, text, numeric, numeric, text,'
                     || ' numeric, uuid, numeric, numeric, numeric, int)') is null then
    raise exception 'delta_pick_premium_ranked did not get created';
  end if;
  if to_regprocedure('public.delta_pick_premium(text, text, numeric, numeric, text,'
                     || ' numeric, uuid, numeric, numeric, numeric)') is null then
    raise exception 'delta_pick_premium is not at the signature the engine calls';
  end if;
  if to_regprocedure('public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text,'
                     || ' numeric, numeric, numeric, int, numeric)') is null then
    raise exception 'delta_sell_entry is not at the signature the engine calls';
  end if;

  raise log '0049: picker and entry each resolve to exactly one definition';
end;
$$;
