-- ============================================================================
-- XAUT Options Paper Trading — a size in XAUT for delta, a take-profit for auto
-- Run this whole file in the Supabase SQL Editor after 0020_auto_strategy_stop_pct.sql.
--
--     delta_strategy_settings.qty        XAUT per leg, converted to lots at placement
--     strategy_settings.take_profit_pct  percent of the premium captured; 0 = no TP
--
-- ---------------------------------------------------------------------------
-- delta.qty — size expressed the way the auto strategy expresses it
-- ---------------------------------------------------------------------------
-- The delta entry was sized in raw lots (`pairs`), while the auto strategy is
-- sized in XAUT and divides by contract_value at placement. This gives delta the
-- same shape:
--
--     lots per leg = greatest(1, round(qty / contract_value)) * pairs
--
-- Default 0.001 XAUT, which at the venue's 0.001 contract_value is exactly 1 lot —
-- so with pairs = 1 nothing changes for an existing account.
--
-- READ THIS BEFORE RAISING IT. Δp is Σ(signed lots × option delta) with no
-- contract-value factor, so lots scale Δp one-for-one. At 1 XAUT a leg is 1000
-- lots and a 0.30-delta option contributes 300 to Δp — against the default band of
-- [-1, 1] that is breached from the first fill and never recovers, so the engine
-- would sell corrective premium every cycle. The sizing formulas are scale-free
-- and will compute the right contract counts, but **the band has to be scaled with
-- the size or it stops meaning anything.** As a rule of thumb, a band that was
-- right at 1 lot per leg wants multiplying by the new lots per leg.
--
-- ---------------------------------------------------------------------------
-- auto.take_profit_pct — the mirror of 0020's stop
-- ---------------------------------------------------------------------------
-- 0020 gave the auto strategy a stop as a percent of the premium given back. This
-- is the same idea in the other direction — a percent of the premium *captured*:
--
--     take_profit = avg_entry_price x (1 - take_profit_pct / 100)
--
--      70  ->  0.30x entry   a $4 short is bought back at $1.20 (keep 70%)
--      50  ->  0.50x entry   a $4 short is bought back at $2.00
--       0             no take-profit armed
--
-- Default 0, so nothing changes until it is set. Capped below 100: at 100 the level
-- is zero, which no option ever marks at, so the bracket would simply never fire.
--
-- Both levels are read off avg_entry_price, so adding to a symbol re-bases them
-- onto the blended entry rather than leaving them pinned to the first fill.
-- ============================================================================

alter table public.delta_strategy_settings
  add column if not exists qty numeric(20, 8) not null default 0.001;

alter table public.delta_strategy_settings drop constraint if exists delta_qty_chk;
alter table public.delta_strategy_settings
  add constraint delta_qty_chk check (qty > 0);

comment on column public.delta_strategy_settings.qty is
  'XAUT per leg at the open, converted to lots by contract_value and multiplied by pairs. Lots scale Δp one-for-one, so raising this means scaling band_low/band_high too.';

alter table public.strategy_settings
  add column if not exists take_profit_pct numeric(20, 8) not null default 0;

alter table public.strategy_settings drop constraint if exists strategy_take_profit_pct_chk;
alter table public.strategy_settings
  add constraint strategy_take_profit_pct_chk check (take_profit_pct >= 0 and take_profit_pct < 100);

comment on column public.strategy_settings.take_profit_pct is
  'Take-profit as a percent of the premium captured, on the mark: take_profit = avg_entry_price * (1 - pct/100). 70 buys a $4 short back at $1.20. 0 arms no take-profit.';

-- ---------------------------------------------------------------------------
-- delta_sell_entry takes the XAUT size. Signature changes, so it is dropped.
-- Body is 0019's — the all-or-nothing savepoint is unchanged — with the lot
-- arithmetic added.
-- ---------------------------------------------------------------------------
drop function if exists public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric);

create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_pairs int, p_qty numeric,
                                                   p_spot numeric)
returns int
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
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie, null);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie, null);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor', p_floor;
    return 0;
  end if;

  -- XAUT to lots, per leg, off that contract's own value. A missing or zero
  -- contract_value falls back to one lot rather than sizing off a guess.
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1)) * p_pairs
    into v_lots_c from public.delta_chain where symbol = c.symbol;
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1)) * p_pairs
    into v_lots_p from public.delta_chain where symbol = p.symbol;

  if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
    raise log 'delta_sell_entry: qty % sized to no lots', p_qty;
    return 0;
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
    return 0;
  end;

  return 2;
end;
$$;

revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_delta_strategy, recreated to pass the XAUT size. Body is 0019's; only the
-- delta_sell_entry call changes.
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

  -- Rebuild the snapshot. The lock is held for the transaction, so a cycle that
  -- overruns its minute cannot have the next one refill the chain underneath it.
  if not pg_try_advisory_xact_lock(hashtext('delta_strategy_engine')) then
    return 0;
  end if;

  delete from public.delta_chain;
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, spot_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
         nullif(t ->> 'spot_price', '')::numeric
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

    -- cycle_seconds spacing. Clearing last_cycle (the tab's manual refresh) makes
    -- the next tick act regardless of how long the interval is.
    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    -- A session day outside trade_days comes back 'closed', so the flatten below
    -- covers an off-day and nothing further in this loop can open a position.
    select phase, sday into v_phase, v_day
    from public.delta_session(s.session_open, s.session_close, s.trade_days);

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
    if v_exp is null then
      raise log 'apply_delta_strategy: no unsettled expiry';
      continue;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    -- The day is stamped only once a full pair is open. A failed open leaves it
    -- unstamped so the next cycle tries again — a thin book at the open used to
    -- cost the entire session.
    if s.entered_day is distinct from v_day then
      if s.pairs <= 0 then
        -- N is zero: there is no entry to place, and nothing to retry.
        update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
        continue;
      end if;

      v_legs := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.pairs, s.qty, v_spot);
      if v_legs < 2 then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next cycle',
          r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    -- Δp = Σ (signed lots × the leg's option delta). No contract-value factor:
    -- that is the unit the worked example in 5.2 is written in, and the band is
    -- calibrated to the same one — which is why raising qty means rescaling the band.
    select count(*) filter (where c.delta is null), coalesce(sum(p.net_qty * c.delta), 0)
      into v_missing, v_dp
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
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
      join public.delta_chain c on c.symbol = p.symbol
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

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_strategy, recreated to arm the take-profit beside the stop. Body is
-- 0020's; only the account select and the bracket update change.
-- ---------------------------------------------------------------------------
create or replace function public.apply_strategy()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_candle   jsonb;
  v_tickers  jsonb;
  v_bar_time bigint;
  v_open     numeric;
  v_close    numeric;
  v_kind     text;
  v_spot     numeric;
  v_today    text;
  v_exp_near text;
  v_exp_day  text;
  v_exp      text;
  v_cnt      int;
  v_atm_rn   int;
  r          record;
  v_offset   int;
  v_dir      int;
  v_rn       int;
  v_tgt      record;
  v_lots     int;
  v_order_id uuid;
  v_avg      numeric;
  v_n        int := 0;
begin
  -- Candidate replies. Both of ours are JSON arrays; the tpsl poll's per-symbol
  -- tickers are bare objects. That distinction is a plain text test, so it
  -- narrows the set before anything is parsed as jsonb — which matters when one
  -- of these rows is close to a megabyte and this runs every minute.
  drop table if exists _replies;
  create temp table _replies on commit drop as
  select row_number() over (order by created desc) as rn,
         content::jsonb -> 'result' as result
  from net._http_response
  where status_code = 200
    and created > now() - interval '150 seconds'
    and content like '%"result":[%';

  -- Candle bars carry 'open' and no 'symbol'; tickers carry 'symbol'.
  select result into v_candle from _replies
  where (result -> 0) ? 'open' and not ((result -> 0) ? 'symbol')
  order by rn limit 1;

  select result into v_tickers from _replies
  where (result -> 0) ? 'symbol'
  order by rn limit 1;

  if v_candle is null or v_tickers is null then
    raise log 'apply_strategy: no fresh reply within 150s (candle=%, tickers=%)',
      v_candle is not null, v_tickers is not null;
    return 0;
  end if;

  -- The last fully-closed 1h bar.
  select (c ->> 'time')::bigint, (c ->> 'open')::numeric, (c ->> 'close')::numeric
    into v_bar_time, v_open, v_close
  from jsonb_array_elements(v_candle) c
  where (c ->> 'time')::bigint + 3600 <= extract(epoch from now())
  order by (c ->> 'time')::bigint desc limit 1;
  if v_bar_time is null then
    raise log 'apply_strategy: no closed 1h bar in the candle reply';
    return 0;
  end if;

  if v_close > v_open then
    v_kind := 'put_options';    -- green -> sell a put
  elsif v_close < v_open then
    v_kind := 'call_options';   -- red -> sell a call
  else
    raise log 'apply_strategy: bar % closed flat at % — no signal', v_bar_time, v_close;
    return 0;
  end if;

  -- The XAUT option chain from the reply.
  --
  -- expiry_label is the symbol's ddmmyy tail. /v2/tickers carries no
  -- settlement_time — reading one was this function's bug — and the symbol is
  -- the authority the client uses too.
  drop table if exists _chain;
  create temp table _chain on commit drop as
  select (t ->> 'symbol')                            as symbol,
         (t ->> 'contract_type')                     as contract_type,
         (t ->> 'strike_price')::numeric             as strike,
         split_part((t ->> 'symbol'), '-', 4)        as expiry_label,
         nullif(t ->> 'contract_value', '')::numeric as contract_value,
         (t ->> 'product_id')::bigint                as product_id,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric as best_bid,
         nullif(t ->> 'spot_price', '')::numeric     as spot_price
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%';

  select max(spot_price) into v_spot from _chain where spot_price is not null;
  if v_spot is null then v_spot := v_close; end if;

  -- Both expiry candidates, once for every account. The unsettled test is the
  -- same in both: an expiry settles at 16:00 UTC on its own date, and the regexp
  -- guards to_date against a symbol with no six-digit tail.
  v_today := to_char(now() at time zone 'Asia/Kolkata', 'DDMMYY');

  select expiry_label into v_exp_near
  from _chain
  where contract_type = v_kind
    and expiry_label ~ '^\d{6}$'
    and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC')
        + interval '16 hours' > now()
  group by expiry_label
  order by to_date(expiry_label, 'DDMMYY') asc
  limit 1;

  -- Same-day, and still unsettled: after 21:30 IST today's contract has settled,
  -- so this is null and an account on 'today' stands down for the rest of the day.
  select expiry_label into v_exp_day
  from _chain
  where contract_type = v_kind
    and expiry_label = v_today
    and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC')
        + interval '16 hours' > now()
  group by expiry_label
  limit 1;

  if v_exp_near is null then
    raise log 'apply_strategy: no unsettled % expiry in a chain of % rows',
      v_kind, (select count(*) from _chain);
  end if;

  v_dir := case when v_kind = 'call_options' then 1 else -1 end;

  for r in
    select s.account_id, s.moneyness, s.qty, s.window_start, s.window_end,
           s.trade_days, s.min_premium, s.expiry_rule, s.stop_loss_pct,
           s.take_profit_pct, a.user_id
    from public.strategy_settings s
    join public.accounts a on a.id = s.account_id
    where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
  loop
    -- Inside this account's window, on one of its days? apply_auto_exit reads the
    -- same test, so the minute this returns false is the minute the flatten begins.
    if not public.in_ist_window(r.window_start, r.window_end, r.trade_days) then
      raise log 'apply_strategy: account % outside its window or off-day', r.account_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    -- Expiry, this account's rule. 'today' never falls through to a later one:
    -- that fall-through is what this rule exists to stop.
    v_exp := case when r.expiry_rule = 'today' then v_exp_day else v_exp_near end;
    if v_exp is null then
      raise log 'apply_strategy: account % — no % expiry (rule %, today %), skipping bar %',
        r.account_id, v_kind, r.expiry_rule, v_today, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    -- Strikes of that expiry, ranked by strike. The expiry varies per account now,
    -- so this is a subquery over _chain rather than a temp table — creating and
    -- dropping one inside this loop is the plan-caching trap 0012 warned about.
    select count(*) into v_cnt
    from _chain where contract_type = v_kind and expiry_label = v_exp;
    if v_cnt = 0 then
      raise log 'apply_strategy: expiry % has no % strikes', v_exp, v_kind;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    -- The listed strike nearest spot is the ATM anchor.
    select rn into v_atm_rn from (
      select row_number() over (order by strike) as rn, strike
      from _chain where contract_type = v_kind and expiry_label = v_exp
    ) q
    order by abs(q.strike - v_spot) asc limit 1;

    -- Strike: step off the money in the leg's out-of-the-money direction, clamped
    -- to the listed wings rather than returning nothing.
    v_offset := case r.moneyness
      when 'ITM2' then -2 when 'ITM1' then -1 when 'ATM' then 0
      when 'OTM1' then 1  when 'OTM2' then 2  when 'OTM3' then 3
      when 'OTM4' then 4  when 'OTM5' then 5  else 0 end;
    v_rn := least(v_cnt, greatest(1, v_atm_rn + v_offset * v_dir));

    select * into v_tgt from (
      select row_number() over (order by strike) as rn,
             symbol, strike, best_bid, contract_value, product_id
      from _chain where contract_type = v_kind and expiry_label = v_exp
    ) q
    where q.rn = v_rn;

    if v_tgt.best_bid is null or v_tgt.best_bid <= 0 or v_tgt.contract_value is null then
      -- Worth a log: the far OTM strikes are frequently unquoted, and this path
      -- consumes the bar, so a run of these looks identical to doing nothing.
      raise log 'apply_strategy: account % — % has no bid, skipping bar %',
        r.account_id, v_tgt.symbol, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;  -- nothing to sell into
    end if;

    -- Premium floor. The strike is the moneyness setting's to choose, so a bid
    -- under the floor skips the bar rather than shopping for a richer strike.
    if r.min_premium > 0 and v_tgt.best_bid < r.min_premium then
      raise log 'apply_strategy: account % — % bid % under the % floor, skipping bar %',
        r.account_id, v_tgt.symbol, v_tgt.best_bid, r.min_premium, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    v_lots := greatest(1, round(r.qty / v_tgt.contract_value)::int);

    insert into public.orders (
      account_id, user_id, symbol, product_id, contract_type, strike_price,
      expiry_label, contract_value, side, order_type, qty, limit_price
    )
    values (
      r.account_id, r.user_id, v_tgt.symbol, v_tgt.product_id, v_kind, v_tgt.strike,
      v_exp, v_tgt.contract_value, 'sell', 'market', v_lots, null
    )
    returning id into v_order_id;

    begin
      -- Sell into the bid. No fee modelled on an auto fill.
      perform public.execute_fill(v_order_id, v_lots, v_tgt.best_bid, 0, v_spot);
    exception when others then
      raise log 'apply_strategy: account % fill failed on % — %',
        r.account_id, v_tgt.symbol, sqlerrm;
      update public.orders set status = 'cancelled', cancel_reason = 'auto strategy fill failed'
      where id = v_order_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end;

    -- The bracket, both sides as a percent of the premium and both on the mark:
    -- the stop is what you will give back, the take-profit what you will keep. Read
    -- off avg_entry_price, so adding to a symbol re-bases both onto the blended
    -- entry rather than leaving them pinned to the first fill. Either at 0 is
    -- simply not armed.
    select avg_entry_price into v_avg
    from public.positions
    where account_id = r.account_id and symbol = v_tgt.symbol and net_qty <> 0;
    if found then
      update public.positions
      set stop_loss = case when r.stop_loss_pct > 0
                           then v_avg * (1 + r.stop_loss_pct / 100.0) end,
          take_profit = case when r.take_profit_pct > 0
                             then v_avg * (1 - r.take_profit_pct / 100.0) end,
          tpsl_trigger = 'mark'
      where account_id = r.account_id and symbol = v_tgt.symbol;
    end if;

    update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
    v_n := v_n + 1;
  end loop;

  if v_n > 0 then
    raise log 'apply_strategy: sold into % account(s) on bar %', v_n, v_bar_time;
  end if;
  return v_n;
end;
$$;

revoke all on function public.apply_strategy() from public, anon, authenticated;
