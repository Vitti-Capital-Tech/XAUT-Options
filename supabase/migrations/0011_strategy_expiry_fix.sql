-- ============================================================================
-- XAUT Options Paper Trading — fix the auto strategy's expiry lookup
-- Run this whole file in the Supabase SQL Editor after 0010_delta_strategy.sql.
--
-- apply_strategy() has never placed a single entry since 0008 went in.
--
-- It built its chain from the /v2/tickers reply and read `settlement_time` off
-- each ticker — but that field is not in that payload. It lives on /v2/products,
-- which is why the client fetches the two separately (compare the Ticker and
-- Product types in src/lib/delta.ts: only Product carries settlement_time). So
-- _chain.settlement_time was NULL on every row, `settlement_time::timestamptz >
-- now()` was NULL rather than true, the nearest-expiry lookup matched nothing,
-- and the function returned 0 one line before it would have traded. Every
-- minute, silently, for as long as it has been scheduled.
--
-- The expiry was there all along: it is the ddmmyy tail of the symbol
-- (C-XAUT-4380-070826), which the order insert further down was already reading
-- with split_part for expiry_label. This takes it from there — the same way the
-- client's parseSymbol does — and drops the dependency on a field that endpoint
-- has never returned. Delta settles at 16:00 UTC on the expiry date.
--
-- Two further changes to the same function:
--
--   * The reply lookup cast content::jsonb over every row of
--     net._http_response, including the ~1MB tickers blob, twice a minute. Both
--     of our replies are JSON arrays and every other job's is a bare object, so
--     it now prefilters on that as plain text before parsing anything.
--
--   * Every early return raises a log line. This bug survived this long because
--     all of them returned a bare 0, which pg_cron faithfully records as
--     "succeeded, 1 row".
--
-- Nothing else changes: same signature, same schedule, same fill path. The
-- cron jobs from 0008 pick this up on their next tick, no re-scheduling needed.
-- ============================================================================

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
      raise log 'apply_strategy: account % outside its window (% IST)', r.account_id, v_ist_min;
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
