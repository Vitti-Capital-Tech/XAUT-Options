-- ============================================================================
-- XAUT Options Paper Trading — server-side Delta Management Strategy
-- Run this whole file in the Supabase SQL Editor after 0011_strategy_expiry_fix.sql.
--
-- 0010 put the delta strategy's engine in the browser, because every cycle needs
-- per-strike greeks and those looked like a client-only thing. They are not:
-- /v2/tickers carries greeks.delta, quotes.best_bid/best_ask, spot_price and
-- contract_value on every symbol, and it accepts underlying_asset_symbols=XAUT,
-- which cuts the reply from ~964KB to ~143KB. So the whole loop can run on
-- pg_cron exactly as the auto strategy's does, and the tab no longer has to be
-- open for the strategy to trade.
--
-- This file implements Gold_Options_Delta_Strategy.docx and nothing besides it:
--
--   S2   session 06:00-22:00 Sydney; flatten at close; counters reset at open
--   S3   band [L,U], buffer B, ITM_trigger, max_rolls_per_side, entry_premium,
--        min_premium, band_correction_delta
--   S4   daily entry: N symmetric pairs nearest entry_premium
--   S5.1 rebuild the ITM queue every cycle, most-ITM first
--   S5.2 partial exit and replace, q = (target - dp) / (d_itm - d_repl), round down
--   S5.3 per-side roll budget; exit-only once spent
--   S5.4 band correction with fresh OTM sells, q = (target - dp) / d_selected
--   S6   never buy to hedge; never sell below min_premium; ITM before band
--
-- The nine OPEN items stay OPEN: each is a column with a default and a control
-- on screen. Where the doc names candidates (target_landing) those are the only
-- choices offered.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- target_landing: the doc names exactly two candidates in 3.1 — the breached
-- boundary, or the band midpoint. The 'buffer' option 0010 carried was not one
-- of them; B is not a third landing rule but the distance back from the edge,
-- per the parameter table in Section 3, so it applies to 'edge'. Setting B to 0
-- gives 3.1's "land exactly on the breached boundary" and reproduces the worked
-- example in 5.2.
-- ---------------------------------------------------------------------------
update public.delta_strategy_settings set target_landing = 'edge' where target_landing = 'buffer';
alter table public.delta_strategy_settings drop constraint if exists delta_target_landing_chk;
alter table public.delta_strategy_settings
  add constraint delta_target_landing_chk check (target_landing in ('edge', 'mid'));

-- Pass state, which the browser engine held in memory. 5.2 touches a strike at
-- most once per pass, and 5.3's budget can be charged per pass, so both have to
-- survive between cron ticks now.
alter table public.delta_strategy_settings
  add column if not exists touched_symbols text[] not null default '{}';
alter table public.delta_strategy_settings
  add column if not exists pass_open boolean not null default false;
-- Honours cycle_seconds: cron ticks every minute, this spaces the actual work.
alter table public.delta_strategy_settings
  add column if not exists last_cycle timestamptz;

-- ---------------------------------------------------------------------------
-- Where the Sydney clock sits relative to a session, and which session day that
-- is. Read through the zone, not a fixed offset, so AEST and AEDT are both right.
-- A close before the open spans midnight; the day is then keyed to the date the
-- session opened on.
-- ---------------------------------------------------------------------------
create or replace function public.delta_session(p_open text, p_close text,
                                                out phase text, out sday text)
language plpgsql
stable
as $$
declare
  v_local timestamp := now() at time zone 'Australia/Sydney';
  v_min   int;
  v_day   date;
  v_o     int;
  v_c     int;
begin
  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_day := v_local::date;
  v_o   := split_part(p_open,  ':', 1)::int * 60 + split_part(p_open,  ':', 2)::int;
  v_c   := split_part(p_close, ':', 1)::int * 60 + split_part(p_close, ':', 2)::int;

  if v_o <= v_c then
    sday  := v_day::text;
    phase := case when v_min < v_o then 'before'
                  when v_min <= v_c then 'open'
                  else 'closed' end;
  elsif v_min >= v_o then
    phase := 'open';  sday := v_day::text;
  elsif v_min <= v_c then
    phase := 'open';  sday := (v_day - 1)::text;
  else
    phase := 'closed'; sday := (v_day - 1)::text;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Poll. Only when something is armed, and only the XAUT slice of the chain.
-- ---------------------------------------------------------------------------
create or replace function public.queue_delta_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
begin
  if not exists (select 1 from public.delta_strategy_settings where armed) then
    return 0;
  end if;

  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/tickers'
           || '?contract_types=call_options,put_options&underlying_asset_symbols=XAUT',
    timeout_milliseconds := 8000
  );
  return 1;
end;
$$;

-- ---------------------------------------------------------------------------
-- Apply. One cycle per armed account, at most one action each, exactly as the
-- browser engine did: Δp is re-read from fresh marks before every step, so a
-- correction is never sized against a book it has already changed.
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
  v_dp        numeric;
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
  v_lots      int;
  v_n         int := 0;
begin
  -- Freshest XAUT tickers reply. Ours is the only array-shaped one carrying
  -- 'greeks', which keeps the (cheap) text prefilter honest.
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200
    and created > now() - interval '180 seconds'
    and content like '%"result":[%'
    and content like '%XAUT%'
    and (content::jsonb -> 'result' -> 0) ? 'greeks'
  order by created desc limit 1;

  if v_tickers is null then
    raise log 'apply_delta_strategy: no fresh XAUT tickers reply';
    return 0;
  end if;

  drop table if exists _dchain;
  create temp table _dchain on commit drop as
  select (t ->> 'symbol')                                  as symbol,
         (t ->> 'contract_type')                           as contract_type,
         (t ->> 'strike_price')::numeric                   as strike,
         split_part((t ->> 'symbol'), '-', 4)              as expiry_label,
         nullif(t ->> 'contract_value', '')::numeric       as contract_value,
         (t ->> 'product_id')::bigint                      as product_id,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric as best_bid,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric as best_ask,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric    as delta,
         nullif(t ->> 'spot_price', '')::numeric           as spot_price
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%';

  select max(spot_price) into v_spot from _dchain where spot_price is not null;
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

    -- cycle_seconds spacing.
    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    select phase, sday into v_phase, v_day from public.delta_session(s.session_open, s.session_close);

    -- A new session day resets the counters, the touched flags and the pass.
    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session close: flatten, whatever the band says --------------------
    if v_phase <> 'open' then
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

    -- Expiry to trade.
    select expiry_label into v_exp
    from _dchain
    where expiry_label ~ '^\d{6}$'
      and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
    group by expiry_label
    order by to_date(expiry_label, 'DDMMYY') asc
    offset (case when s.expiry_pick = 'next' then 1 else 0 end)
    limit 1;
    if v_exp is null then
      select expiry_label into v_exp
      from _dchain
      where expiry_label ~ '^\d{6}$'
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      order by to_date(expiry_label, 'DDMMYY') asc limit 1;
    end if;
    if v_exp is null then
      raise log 'apply_delta_strategy: no unsettled expiry';
      continue;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    if s.entered_day is distinct from v_day then
      if s.pairs > 0 then
        perform public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.pairs, v_spot);
      end if;
      update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    -- Δp = Σ (signed lots × the leg's option delta). No contract-value factor:
    -- that is the unit the worked example in 5.2 is written in, and the band is
    -- calibrated to the same one.
    select count(*) filter (where c.delta is null), coalesce(sum(p.net_qty * c.delta), 0)
      into v_missing, v_dp
    from public.positions p
    left join _dchain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on greeks for % leg(s)', r.account_id, v_missing;
      continue;
    end if;

    v_breach := case when v_dp < s.band_low then 'low'
                     when v_dp > s.band_high then 'high' end;

    if v_breach is null then
      if s.pass_open then
        update public.delta_strategy_settings
        set pass_open = false, touched_symbols = '{}' where account_id = r.account_id;
      end if;
      continue;
    end if;

    -- Landing point. 'edge' is the breached boundary drawn back inside by B
    -- (Section 3's definition of the buffer); 'mid' is the band midpoint.
    if s.target_landing = 'mid' then
      v_target := (s.band_low + s.band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(s.band_low + s.band_buffer, (s.band_low + s.band_high) / 2);
    else
      v_target := greatest(s.band_high - s.band_buffer, (s.band_low + s.band_high) / 2);
    end if;

    -- Δp below the band is a book too short-call heavy, so exiting an ITM call
    -- lifts it; above the band it is the puts. Selling fresh is the mirror.
    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

    -- ---- S5.1/5.2: walk the ITM queue, most-ITM first ----------------------
    for v_leg in
      select p.id, p.symbol, p.net_qty, p.strike_price::numeric as strike, p.contract_value,
             p.product_id, c.delta, c.best_ask,
             case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end as itm_distance
      from public.positions p
      join _dchain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type = v_rollside
        and not (p.symbol = any (s.touched_symbols))
        and (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                  else p.strike_price::numeric - v_spot end) >= s.itm_trigger
      order by itm_distance desc
    loop
      -- 5.3: budget spent means exit in full, no replacement, loss booked.
      if v_used >= s.max_rolls then
        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;
        v_acted := true;
        exit;
      end if;

      -- Replacement: same side, further out, nearest entry_premium, never below
      -- the floor.
      select * into v_repl from public.delta_pick_premium(
        v_exp, v_rollside, s.entry_premium, s.min_premium, s.tie_break, v_leg.strike);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      -- Round down, with a hair of tolerance: the deltas are two-decimal
      -- quantities but 0.55 - 0.30 is 0.2500000000000001 in binary, which would
      -- floor the doc's own worked example from 2 contracts to 1.
      v_q := floor(abs(v_target - v_dp) / v_gap + 1e-9)::int;
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
    select * into v_pick from public.delta_pick_delta(
      v_exp, v_sellside, s.band_delta_low, s.band_delta_high, s.min_premium);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike in the %-% delta range',
        r.account_id, v_sellside, s.band_delta_low, s.band_delta_high;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / abs(v_pick.delta) + 1e-9)::int;
    if v_q <= 0 then continue; end if;

    -- Band-correction sells are fresh positions, not replacements: they draw on
    -- neither side's roll budget.
    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Order helpers. Every one places a market order and fills it through
-- execute_fill, exactly as the ticket does.
-- ---------------------------------------------------------------------------

/** Sell to open `p_lots` of a symbol, into the bid. */
create or replace function public.delta_sell(p_account uuid, p_user uuid, p_symbol text,
                                             p_lots int, p_spot numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  v_order  uuid;
begin
  select * into c from _dchain where symbol = p_symbol;
  if not found or c.best_bid is null or c.best_bid <= 0 then
    raise log 'delta_sell: % has no bid', p_symbol;
    return;
  end if;

  insert into public.orders (account_id, user_id, symbol, product_id, contract_type,
                             strike_price, expiry_label, contract_value, side, order_type,
                             qty, limit_price)
  values (p_account, p_user, c.symbol, c.product_id, c.contract_type, c.strike,
          c.expiry_label, c.contract_value, 'sell', 'market', p_lots, null)
  returning id into v_order;

  begin
    perform public.execute_fill(v_order, p_lots, c.best_bid, 0, p_spot);
  exception when others then
    raise log 'delta_sell: fill failed on % — %', p_symbol, sqlerrm;
    update public.orders set status = 'cancelled', cancel_reason = 'delta strategy fill failed'
    where id = v_order;
  end;
end;
$$;

/** Buy back `p_lots` of a short leg, lifting the ask. Reduce-only. */
create or replace function public.delta_close_leg(p_account uuid, p_user uuid, p_symbol text,
                                                  p_lots int, p_spot numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c       record;
  v_order uuid;
begin
  select * into c from _dchain where symbol = p_symbol;
  if not found or c.best_ask is null or c.best_ask <= 0 then
    raise log 'delta_close_leg: % has no ask', p_symbol;
    return;
  end if;

  insert into public.orders (account_id, user_id, symbol, product_id, contract_type,
                             strike_price, expiry_label, contract_value, side, order_type,
                             qty, limit_price, reduce_only)
  values (p_account, p_user, c.symbol, c.product_id, c.contract_type, c.strike,
          c.expiry_label, c.contract_value, 'buy', 'market', p_lots, null, true)
  returning id into v_order;

  begin
    perform public.execute_fill(v_order, p_lots, c.best_ask, 0, p_spot);
  exception when others then
    raise log 'delta_close_leg: fill failed on % — %', p_symbol, sqlerrm;
    update public.orders set status = 'cancelled', cancel_reason = 'delta strategy fill failed'
    where id = v_order;
  end;
end;
$$;

/** S2: exit every open leg on the account. */
create or replace function public.delta_flatten(p_account uuid, p_user uuid, p_spot numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
begin
  for p in select symbol, net_qty from public.positions
           where account_id = p_account and net_qty <> 0
  loop
    if p.net_qty < 0 then
      perform public.delta_close_leg(p_account, p_user, p.symbol, abs(p.net_qty), p_spot);
    else
      perform public.delta_sell(p_account, p_user, p.symbol, p.net_qty, p_spot);
    end if;
  end loop;
end;
$$;

/**
 * S4: sell one symmetric call/put pair, N lots each, at the strikes nearest the
 * entry premium.
 */
create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_pairs int, p_spot numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
  p record;
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie, null);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie, null);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor', p_floor;
    return;
  end if;

  perform public.delta_sell(p_account, p_user, c.symbol, p_pairs, p_spot);
  perform public.delta_sell(p_account, p_user, p.symbol, p_pairs, p_spot);
end;
$$;

/**
 * The strike to sell for an entry or a roll replacement: premium nearest the
 * entry premium, never below the floor. `p_beyond` restricts the search to
 * strikes further out than a given one, which is what makes a roll a roll.
 */
create or replace function public.delta_pick_premium(p_exp text, p_kind text, p_entry numeric,
                                                     p_floor numeric, p_tie text, p_beyond numeric)
returns table (symbol text, strike numeric, premium numeric, delta numeric)
language sql
stable
as $$
  with candidates as (
    select c.symbol, c.strike, c.best_bid as premium, c.delta
    from _dchain c
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
  -- rank 0 is the requested tie-break, rank 1 the absolute-closest fallback for
  -- when a one-sided rule finds nothing. An explicit ordering, because UNION ALL
  -- does not promise to return its branches in order.
  ranked as (
    select c.*, 0 as rank, c.premium - p_entry as tiebreak
    from candidates c where p_tie = 'above' and c.premium >= p_entry
    union all
    select c.*, 0, p_entry - c.premium
    from candidates c where p_tie = 'below' and c.premium <= p_entry
    union all
    select c.*, 1, abs(c.premium - p_entry) from candidates c
  )
  select symbol, strike, premium, delta
  from ranked order by rank asc, tiebreak asc limit 1;
$$;

/**
 * S5.4: the strike to sell for a band correction — one inside the
 * band_correction_delta range, nearest the middle of it, floor still applying.
 */
create or replace function public.delta_pick_delta(p_exp text, p_kind text, p_lo numeric,
                                                   p_hi numeric, p_floor numeric)
returns table (symbol text, strike numeric, premium numeric, delta numeric)
language sql
stable
as $$
  select c.symbol, c.strike, c.best_bid, c.delta
  from _dchain c
  where c.expiry_label = p_exp
    and c.contract_type = p_kind
    and c.best_bid is not null
    and c.delta is not null
    and c.best_bid >= p_floor
    and abs(c.delta) between least(p_lo, p_hi) and greatest(p_lo, p_hi)
  order by abs(abs(c.delta) - (least(p_lo, p_hi) + greatest(p_lo, p_hi)) / 2) asc
  limit 1;
$$;

revoke all on function public.queue_delta_checks() from public, anon, authenticated;
revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
revoke all on function public.delta_sell(uuid, uuid, text, int, numeric) from public, anon, authenticated;
revoke all on function public.delta_close_leg(uuid, uuid, text, int, numeric) from public, anon, authenticated;
revoke all on function public.delta_flatten(uuid, uuid, numeric) from public, anon, authenticated;
revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Schedule. Both gate themselves on something being armed, so an idle install
-- costs one index lookup a minute.
-- ---------------------------------------------------------------------------
select cron.unschedule('delta-poll')  where exists (select 1 from cron.job where jobname = 'delta-poll');
select cron.unschedule('delta-apply') where exists (select 1 from cron.job where jobname = 'delta-apply');
select cron.schedule('delta-poll',  '* * * * *', $$select public.queue_delta_checks()$$);
select cron.schedule('delta-apply', '* * * * *', $$select public.apply_delta_strategy()$$);
