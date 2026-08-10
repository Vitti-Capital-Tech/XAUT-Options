-- ============================================================================
-- XAUT Options Paper Trading — a premium floor on the auto strategy's entries
-- Run this whole file in the Supabase SQL Editor after 0016_strategy_trade_days.sql.
--
-- The auto strategy sold whatever its moneyness resolved to, at whatever the bid
-- happened to be. `min_premium` puts a floor under that: a bar whose strike is
-- bid below the floor is skipped rather than sold.
--
--     strategy_settings.min_premium   dollars on the bid; 0 disables the filter
--
-- It vetoes the bar rather than hunting for a richer strike, and that is
-- deliberate — the strike is fixed by `moneyness`, which is the strategy's one
-- rule about *what* to sell. Searching for whatever strike clears the floor would
-- quietly override it, and could walk the position deep into the money on a thin
-- day. The delta strategy's `min_premium` reads the same way (Section 6: nothing
-- is ever sold below the floor), the difference being that it is already choosing
-- a strike by premium, so a floor there narrows a search rather than blocking one.
--
-- Default 0, so nothing changes for an existing account until a floor is set.
--
-- A skipped bar consumes `last_acted`, like every other skip path in this
-- function: the poll only fetches in the first minutes of an hour, so a bar
-- cannot be retried later anyway, and leaving it unconsumed would re-log the same
-- decision every minute for the rest of the hour.
-- ============================================================================

alter table public.strategy_settings
  add column if not exists min_premium numeric(20, 8) not null default 0;

comment on column public.strategy_settings.min_premium is
  'Premium floor in dollars on the bid. A bar whose moneyness strike is bid below this is skipped, not sold. 0 disables it.';

-- ---------------------------------------------------------------------------
-- apply_strategy, recreated with the floor. Body is 0016's; the only change is
-- the check after the strike is resolved.
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

  -- Nearest expiry still to settle, for this leg. The regexp guards to_date
  -- against a symbol that does not carry a six-digit tail.
  select expiry_label into v_exp
  from _chain
  where contract_type = v_kind
    and expiry_label ~ '^\d{6}$'
    and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC')
        + interval '16 hours' > now()
  order by to_date(expiry_label, 'DDMMYY') asc
  limit 1;
  if v_exp is null then
    raise log 'apply_strategy: no unsettled % expiry in a chain of % rows',
      v_kind, (select count(*) from _chain);
    return 0;
  end if;

  -- Rank that expiry's strikes; find the one nearest spot (ATM).
  drop table if exists _k;
  create temp table _k on commit drop as
  select symbol, strike, best_bid, contract_value, product_id,
         row_number() over (order by strike) as rn
  from _chain where contract_type = v_kind and expiry_label = v_exp;
  select count(*) into v_cnt from _k;
  if v_cnt = 0 then
    raise log 'apply_strategy: expiry % has no % strikes', v_exp, v_kind;
    return 0;
  end if;
  select rn into v_atm_rn from _k order by abs(strike - v_spot) asc limit 1;

  v_dir := case when v_kind = 'call_options' then 1 else -1 end;

  for r in
    select s.account_id, s.moneyness, s.qty, s.window_start, s.window_end,
           s.trade_days, s.min_premium, a.user_id
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

    -- Strike: step off the money in the leg's out-of-the-money direction.
    v_offset := case r.moneyness
      when 'ITM2' then -2 when 'ITM1' then -1 when 'ATM' then 0
      when 'OTM1' then 1  when 'OTM2' then 2  when 'OTM3' then 3
      when 'OTM4' then 4  when 'OTM5' then 5  else 0 end;
    v_rn := least(v_cnt, greatest(1, v_atm_rn + v_offset * v_dir));

    select * into v_tgt from _k where rn = v_rn;
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

  if v_n > 0 then
    raise log 'apply_strategy: sold into % account(s) on bar %', v_n, v_bar_time;
  end if;
  return v_n;
end;
$$;

revoke all on function public.apply_strategy() from public, anon, authenticated;
