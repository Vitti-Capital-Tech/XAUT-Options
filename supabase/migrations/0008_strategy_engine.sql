-- ============================================================================
-- XAUT Options Paper Trading — server-side auto strategy
-- Run this whole file in the Supabase SQL Editor after 0007_account_kind.sql.
--
-- The strategy's entries used to be placed by the browser, so they only happened
-- with the tab open. This moves them server-side, the way the stops already run:
-- a pg_cron loop fetches the last closed 1h candle of the spot index and the
-- option chain from Delta (pg_net), and once per bar sells one option into each
-- armed auto account — a call on a red bar, a put on a green — at the account's
-- chosen moneyness off the nearest expiry, inside its window, then arms a stop at
-- twice the entry premium on the mark. Positions accumulate. No tab required.
--
-- Settings live in the DB now (a browser cannot hold them for a server job):
-- strategy_settings carries armed, moneyness, qty and window per auto account.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Per-account settings. One row per auto account; the client reads and writes
-- its own, the cron reads every armed one.
-- ---------------------------------------------------------------------------
create table if not exists public.strategy_settings (
  account_id   uuid primary key references public.accounts (id) on delete cascade,
  armed        boolean not null default false,
  moneyness    text    not null default 'ATM',
  qty          numeric(20, 8) not null default 1,   -- underlying (XAUT) per fire
  window_start text    not null default '00:00',    -- HH:MM, IST
  window_end   text    not null default '23:59',
  last_acted   bigint,                              -- unix seconds of last acted bar
  updated_at   timestamptz not null default now()
);

alter table public.strategy_settings enable row level security;

drop policy if exists strategy_settings_owner on public.strategy_settings;
create policy strategy_settings_owner on public.strategy_settings
  using (exists (select 1 from public.accounts a where a.id = account_id and a.user_id = auth.uid()))
  with check (exists (select 1 from public.accounts a where a.id = account_id and a.user_id = auth.uid()));

grant select, insert, update, delete on public.strategy_settings to authenticated;

-- ---------------------------------------------------------------------------
-- Poll: fetch the candle and the chain, but only when something is armed and
-- only in the first minutes of a UTC hour — 1h bars close on the hour, so that
-- is the only time a fresh bar appears, and it keeps the (large) chain fetch
-- rare rather than every minute all day.
-- ---------------------------------------------------------------------------
create or replace function public.queue_strategy_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_now bigint;
begin
  if not exists (select 1 from public.strategy_settings where armed) then
    return 0;
  end if;
  if extract(minute from (now() at time zone 'UTC'))::int >= 5 then
    return 0;
  end if;

  v_now := extract(epoch from now())::bigint;
  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/history/candles?resolution=1h&symbol=.DEXAUTUSD&start='
           || (v_now - 4 * 3600) || '&end=' || v_now,
    timeout_milliseconds := 5000
  );
  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/tickers?contract_types=call_options,put_options',
    timeout_milliseconds := 8000
  );
  return 2;
end;
$$;

-- ---------------------------------------------------------------------------
-- Apply: read the fresh replies and, once per new bar, sell into each armed
-- account. The candle colour picks the leg for everyone (the underlying is
-- shared); each account's moneyness picks its own strike off the same nearest
-- expiry. The short opens through execute_fill at the bid, exactly as a manual
-- market sell would, then takes a 2x-entry stop on the mark.
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
  v_ist_min  int;
  v_ws       int;
  v_we       int;
  v_in       boolean;
  v_n        int := 0;
begin
  -- Freshest candle reply (array of bars — has 'open', no 'symbol').
  select (content::jsonb -> 'result') into v_candle
  from net._http_response
  where status_code = 200 and created > now() - interval '150 seconds'
    and (content::jsonb -> 'result' -> 0) ? 'open'
    and not ((content::jsonb -> 'result' -> 0) ? 'symbol')
  order by created desc limit 1;

  -- Freshest tickers reply (array — has 'symbol').
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200 and created > now() - interval '150 seconds'
    and (content::jsonb -> 'result' -> 0) ? 'symbol'
  order by created desc limit 1;

  if v_candle is null or v_tickers is null then return 0; end if;

  -- The last fully-closed 1h bar.
  select (c ->> 'time')::bigint, (c ->> 'open')::numeric, (c ->> 'close')::numeric
    into v_bar_time, v_open, v_close
  from jsonb_array_elements(v_candle) c
  where (c ->> 'time')::bigint + 3600 <= extract(epoch from now())
  order by (c ->> 'time')::bigint desc limit 1;
  if v_bar_time is null then return 0; end if;

  if v_close > v_open then
    v_kind := 'put_options';    -- green → sell a put
  elsif v_close < v_open then
    v_kind := 'call_options';   -- red → sell a call
  else
    return 0;                   -- flat: no signal
  end if;

  -- The XAUT option chain from the reply.
  drop table if exists _chain;
  create temp table _chain on commit drop as
  select (t ->> 'symbol')                            as symbol,
         (t ->> 'contract_type')                     as contract_type,
         (t ->> 'strike_price')::numeric             as strike,
         (t ->> 'settlement_time')                   as settlement_time,
         nullif(t ->> 'contract_value', '')::numeric as contract_value,
         (t ->> 'product_id')::bigint                as product_id,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric as best_bid,
         nullif(t ->> 'spot_price', '')::numeric     as spot_price
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%';

  select max(spot_price) into v_spot from _chain where spot_price is not null;
  if v_spot is null then v_spot := v_close; end if;

  -- Nearest expiry still in the future for this leg.
  select settlement_time into v_exp
  from _chain
  where contract_type = v_kind and settlement_time::timestamptz > now()
  order by settlement_time::timestamptz asc limit 1;
  if v_exp is null then return 0; end if;

  -- Rank that expiry's strikes; find the one nearest spot (ATM).
  drop table if exists _k;
  create temp table _k on commit drop as
  select symbol, strike, best_bid, contract_value, product_id,
         row_number() over (order by strike) as rn
  from _chain where contract_type = v_kind and settlement_time = v_exp;
  select count(*) into v_cnt from _k;
  if v_cnt = 0 then return 0; end if;
  select rn into v_atm_rn from _k order by abs(strike - v_spot) asc limit 1;

  v_dir := case when v_kind = 'call_options' then 1 else -1 end;
  v_ist_min := extract(hour from (now() at time zone 'Asia/Kolkata'))::int * 60
             + extract(minute from (now() at time zone 'Asia/Kolkata'))::int;

  for r in
    select s.account_id, s.moneyness, s.qty, s.window_start, s.window_end, a.user_id
    from public.strategy_settings s
    join public.accounts a on a.id = s.account_id
    where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
  loop
    -- Inside this account's window (IST, honouring an overnight wrap)?
    v_ws := split_part(r.window_start, ':', 1)::int * 60 + split_part(r.window_start, ':', 2)::int;
    v_we := split_part(r.window_end, ':', 1)::int * 60 + split_part(r.window_end, ':', 2)::int;
    v_in := case when v_ws <= v_we then v_ist_min >= v_ws and v_ist_min <= v_we
                 else v_ist_min >= v_ws or v_ist_min <= v_we end;
    if not v_in then
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    -- Strike: step off the money in the leg's out-of-the-money direction.
    v_offset := case r.moneyness
      when 'ITM2' then -2 when 'ITM1' then -1 when 'ATM' then 0
      when 'OTM1' then 1  when 'OTM2' then 2  when 'OTM3' then 3
      when 'OTM4' then 4  when 'OTM5' then 5  else 0 end;
    v_rn := least(v_cnt, greatest(1, v_atm_rn + v_offset * v_dir));

    select * into v_tgt from _k where rn = v_rn;
    if v_tgt.best_bid is null or v_tgt.best_bid <= 0 or v_tgt.contract_value is null then
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;  -- nothing to sell into
    end if;

    v_lots := greatest(1, round(r.qty / v_tgt.contract_value)::int);

    insert into public.orders (
      account_id, user_id, symbol, product_id, contract_type, strike_price,
      expiry_label, contract_value, side, order_type, qty, limit_price
    )
    values (
      r.account_id, r.user_id, v_tgt.symbol, v_tgt.product_id, v_kind, v_tgt.strike,
      split_part(v_tgt.symbol, '-', 4), v_tgt.contract_value, 'sell', 'market', v_lots, null
    )
    returning id into v_order_id;

    begin
      -- Sell into the bid. No fee modelled on an auto fill.
      perform public.execute_fill(v_order_id, v_lots, v_tgt.best_bid, 0, v_spot);
    exception when others then
      update public.orders set status = 'cancelled', cancel_reason = 'auto strategy fill failed'
      where id = v_order_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end;

    -- Stop at twice the entry premium, on the mark.
    select avg_entry_price into v_avg
    from public.positions
    where account_id = r.account_id and symbol = v_tgt.symbol and net_qty <> 0;
    if found then
      update public.positions
      set stop_loss = 2 * v_avg, tpsl_trigger = 'mark'
      where account_id = r.account_id and symbol = v_tgt.symbol;
    end if;

    update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.queue_strategy_checks() from public, anon, authenticated;
revoke all on function public.apply_strategy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Schedule. Poll gates itself to armed + top-of-hour, so most ticks are a cheap
-- no-op; apply is idempotent per bar via last_acted, so running it each minute
-- only ever fires once.
-- ---------------------------------------------------------------------------
select cron.schedule('strategy-poll',  '1 minute', $$select public.queue_strategy_checks()$$);
select cron.schedule('strategy-apply', '1 minute', $$select public.apply_strategy()$$);
