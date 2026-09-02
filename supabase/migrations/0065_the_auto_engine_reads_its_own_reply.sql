-- 0065_the_auto_engine_reads_its_own_reply.sql
--
-- Run this whole file in the Supabase SQL Editor after 0064.
--
-- The second half of the treatment 0058 prescribed and 0064 began. 0058's own
-- header:
--
--     Note, not fixed here: queue_strategy_checks still pulls the whole exchange
--     once a minute. That is the auto strategy's own poller and its engine reads
--     replies the same loose way, so it deserves the same treatment.
--
-- 0064 narrowed the request. This narrows the read.
--
-- net._http_response is one shared table for every pg_net caller in this
-- database, and apply_strategy has always found its two replies by describing
-- them rather than by knowing which they are:
--
--     status 200, created within 150 seconds, body contains "result":[,
--     not registered in trail_candle_requests, and then
--       the candle  = first result element has `open` and no `symbol`
--       the tickers = first result element has `symbol`
--
-- "First element has a symbol" is true of every ticker reply in the database.
-- queue_delta_checks fires one every five seconds, so on an armed delta account
-- there are dozens of candidates in any 150-second window and the auto engine
-- takes whichever landed last. It has been reading the delta poller's reply
-- most of the time, not its own.
--
-- That this has not caused an incident is luck about content, not correctness:
-- after 0064 both pollers ask the same question, so the wrong body holds the
-- right data. The delta engine's version of this exact bug was not so lucky --
-- it picked up queue_strategy_checks's 1043-row reply, took BTC at 78,741 as
-- XAUT's spot, and because 0050 had dropped both the symbol filter and the
-- per-cycle delete, it stayed spot for every account until someone noticed.
--
-- So: the same fix, for the same reason, before rather than after.
--
-- Both requests are registered, not just the tickers one. The candle picker has
-- the same weakness -- it excludes the trailing-stop candle fetches by looking
-- them up in trail_candle_requests, which is an exclusion list that has to be
-- extended by hand every time somebody adds a poller that fetches bars. An id
-- match needs no such list.
--
-- 0037's trail_candle_requests is left exactly as it is: it correlates symbol to
-- request across many requests, which is a different job from this one, and
-- apply_trail_stops already joins on it by id.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. The request log
-- ---------------------------------------------------------------------------
-- One row per request the auto poller makes, tagged with which of the two it
-- is. Unlogged and pruned: a correlation key with a lifetime of seconds, not a
-- record of anything.
create unlogged table if not exists public.strategy_requests (
  id           bigint primary key,
  kind         text not null check (kind in ('candle', 'tickers')),
  requested_at timestamptz not null default now()
);

alter table public.strategy_requests enable row level security;
revoke all on public.strategy_requests from anon, authenticated;

create index if not exists strategy_requests_requested_at_idx
  on public.strategy_requests (requested_at desc);

comment on table public.strategy_requests is
  'Request ids from queue_strategy_checks, tagged candle or tickers, so apply_strategy can read its own replies out of the shared net._http_response instead of guessing which are his. The auto strategy''s counterpart to delta_ticker_requests (0058).';

-- ---------------------------------------------------------------------------
-- 2. queue_strategy_checks: keep the ids
-- ---------------------------------------------------------------------------
-- 0064's function with the two `perform`s turned into `select ... into`. The
-- XAUT filter 0064 added is carried forward unchanged; the gates, the timeouts
-- and the return of 2 are all as they were.
create or replace function public.queue_strategy_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  v_now    bigint;
  v_candle bigint;
  v_tick   bigint;
begin
  if not exists (select 1 from public.strategy_settings where armed) then
    return 0;
  end if;
  if extract(minute from (now() at time zone 'UTC'))::int >= 5 then
    return 0;
  end if;

  v_now := extract(epoch from now())::bigint;

  -- net.http_get returns the request id; _http_response.id is the same value.
  -- `perform` discarded it, which is what left the engine guessing.
  select net.http_get(
    url := 'https://api.india.delta.exchange/v2/history/candles?resolution=1h&symbol=.DEXAUTUSD&start='
           || (v_now - 4 * 3600) || '&end=' || v_now,
    timeout_milliseconds := 5000
  ) into v_candle;

  select net.http_get(
    url := 'https://api.india.delta.exchange/v2/tickers'
           || '?contract_types=call_options,put_options'
           || '&underlying_asset_symbols=XAUT',
    timeout_milliseconds := 8000
  ) into v_tick;

  insert into public.strategy_requests (id, kind)
  values (v_candle, 'candle'), (v_tick, 'tickers')
  on conflict (id) do nothing;

  -- The engine only ever looks 150 seconds back and the poller runs five times
  -- an hour, so anything older than a few minutes is dead weight.
  delete from public.strategy_requests
  where requested_at < now() - interval '10 minutes';

  return 2;
end;
$$;
revoke all on function public.queue_strategy_checks() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The engine
-- ---------------------------------------------------------------------------
-- 0046's engine with the response picker replaced. Everything else -- the bar
-- test, the expiry rules, the moneyness walk, the buy -- is unchanged.
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
  -- Each reply read by the id of the request that asked for it. No temp table,
  -- no shape tests, no exclusion list -- a reply nobody here asked for cannot be
  -- picked, whatever is in it and whoever adds the next poller.
  --
  -- Aliased `resp`, not `r`: `r` is the account-loop record declared above, and
  -- plpgsql resolves a name against its own variables before a statement's table
  -- aliases, so `r.content` would bind to the unassigned record and raise
  -- "record r is not assigned yet" on the engine's first statement. 0060 learned
  -- this on the delta engine; apply_trail_stops has always aliased it this way.
  select (resp.content::jsonb -> 'result') into v_candle
  from net._http_response resp
  join public.strategy_requests req on req.id = resp.id and req.kind = 'candle'
  where resp.status_code = 200
    and resp.created > now() - interval '150 seconds'
  order by resp.created desc limit 1;

  select (resp.content::jsonb -> 'result') into v_tickers
  from net._http_response resp
  join public.strategy_requests req on req.id = resp.id and req.kind = 'tickers'
  where resp.status_code = 200
    and resp.created > now() - interval '150 seconds'
  order by resp.created desc limit 1;

  if v_candle is null or v_tickers is null then
    raise log 'apply_strategy: no fresh reply within 150s (candle=%, tickers=%)',
      v_candle is not null, v_tickers is not null;
    return 0;
  end if;

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
    v_kind := 'put_options';    -- green -> buy a put
  elsif v_close < v_open then
    v_kind := 'call_options';   -- red -> buy a call
  else
    raise log 'apply_strategy: bar % closed flat at % — no signal', v_bar_time, v_close;
    return 0;
  end if;

  drop table if exists _chain;
  create temp table _chain on commit drop as
  select (t ->> 'symbol')                            as symbol,
         (t ->> 'contract_type')                     as contract_type,
         (t ->> 'strike_price')::numeric             as strike,
         split_part((t ->> 'symbol'), '-', 4)        as expiry_label,
         nullif(t ->> 'contract_value', '')::numeric as contract_value,
         (t ->> 'product_id')::bigint                as product_id,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric as best_bid,
         -- The side a buy actually fills at. best_bid stays in the table because
         -- it costs nothing and reads as the other half of the quote.
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric as best_ask,
         nullif(t ->> 'spot_price', '')::numeric     as spot_price
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%';

  select max(spot_price) into v_spot from _chain where spot_price is not null;
  if v_spot is null then v_spot := v_close; end if;

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
           s.trade_days, s.max_premium, s.expiry_rule, s.expiry_label,
           s.stop_loss_pct, s.take_profit_pct, a.user_id
    from public.strategy_settings s
    join public.accounts a on a.id = s.account_id
    where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
  loop
    -- Was this *bar* inside the account's window when it closed? Tested at the
    -- bar's own close instant, not at now(), and with no last_acted stamp on the
    -- way out. Both halves matter -- see 0032's header.
    if not public.in_ist_window(r.window_start, r.window_end, r.trade_days,
                                to_timestamp(v_bar_time) + interval '1 hour') then
      if public.in_ist_window(r.window_start, r.window_end, r.trade_days) then
        raise log 'apply_strategy: account % is in its window but bar % closed outside it',
          r.account_id, v_bar_time;
      end if;
      continue;
    end if;

    -- Expiry. A chosen date wins outright and is honoured only while it is still
    -- listed and unsettled: no falling through to another contract, ever. With no
    -- date chosen the rule from 0018 applies.
    if r.expiry_label is not null then
      select expiry_label into v_exp
      from _chain
      where contract_type = v_kind
        and expiry_label = r.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC')
            + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
      v_exp := case when r.expiry_rule = 'today' then v_exp_day else v_exp_near end;
    end if;

    if v_exp is null then
      raise log 'apply_strategy: account % — % expiry % unavailable (rule %), skipping bar %',
        r.account_id, v_kind, coalesce(r.expiry_label, '(by rule)'), r.expiry_rule, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    select count(*) into v_cnt
    from _chain where contract_type = v_kind and expiry_label = v_exp;
    if v_cnt = 0 then
      raise log 'apply_strategy: expiry % has no % strikes', v_exp, v_kind;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    select rn into v_atm_rn from (
      select row_number() over (order by strike) as rn, strike
      from _chain where contract_type = v_kind and expiry_label = v_exp
    ) q
    order by abs(q.strike - v_spot) asc limit 1;

    v_offset := case r.moneyness
      when 'ITM2' then -2 when 'ITM1' then -1 when 'ATM' then 0
      when 'OTM1' then 1  when 'OTM2' then 2  when 'OTM3' then 3
      when 'OTM4' then 4  when 'OTM5' then 5  else 0 end;
    v_rn := least(v_cnt, greatest(1, v_atm_rn + v_offset * v_dir));

    select * into v_tgt from (
      select row_number() over (order by strike) as rn,
             symbol, strike, best_ask, contract_value, product_id
      from _chain where contract_type = v_kind and expiry_label = v_exp
    ) q
    where q.rn = v_rn;

    -- No ask is the same dead end no bid used to be: nothing is offered, so there
    -- is nothing to lift, and the bar is consumed rather than retried.
    if v_tgt.best_ask is null or v_tgt.best_ask <= 0 or v_tgt.contract_value is null then
      raise log 'apply_strategy: account % — % has no ask, skipping bar %',
        r.account_id, v_tgt.symbol, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

    -- The budget, and the direction it now points: a buyer's veto is on paying too
    -- much, where the seller's was on collecting too little.
    if r.max_premium > 0 and v_tgt.best_ask > r.max_premium then
      raise log 'apply_strategy: account % — % ask % over the % cap, skipping bar %',
        r.account_id, v_tgt.symbol, v_tgt.best_ask, r.max_premium, v_bar_time;
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
      v_exp, v_tgt.contract_value, 'buy', 'market', v_lots, null
    )
    returning id into v_order_id;

    begin
      perform public.execute_fill(v_order_id, v_lots, v_tgt.best_ask, 0, v_spot);
    exception when others then
      raise log 'apply_strategy: account % fill failed on % — %',
        r.account_id, v_tgt.symbol, sqlerrm;
      update public.orders set status = 'cancelled', cancel_reason = 'auto strategy fill failed'
      where id = v_order_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end;

    -- The bracket, both sides as a percent of the premium and both on the mark,
    -- pointing the way a long reads them: the stop below the entry, the target
    -- above it. apply_tpsl_triggers fires them on that reading already — on a mark
    -- trigger it takes its direction from the position's own sign.
    --
    -- The entry stop only: the trailing half is set by apply_trail_stops off the
    -- next closed minute, within about a minute of this fill. An account running
    -- trailing alone (stop_loss_pct = 0) therefore opens with no stop for that
    -- minute — worth knowing, and the reason to keep an entry stop set as the
    -- outer bound even when the trail is doing the work.
    --
    -- The `< 100` is not a validation, it is the arithmetic: at 100 the level
    -- lands on zero and above it below zero, and neither is a price an option
    -- marks at. A long's loss is bounded by the premium it paid, so that reads as
    -- no stop rather than as an unbounded one.
    select avg_entry_price into v_avg
    from public.positions
    where account_id = r.account_id and symbol = v_tgt.symbol and net_qty <> 0;
    if found then
      update public.positions
      set stop_loss = case when r.stop_loss_pct > 0 and r.stop_loss_pct < 100
                           then v_avg * (1 - r.stop_loss_pct / 100.0) end,
          take_profit = case when r.take_profit_pct > 0
                             then v_avg * (1 + r.take_profit_pct / 100.0) end,
          tpsl_trigger = 'mark'
      where account_id = r.account_id and symbol = v_tgt.symbol;
    end if;

    update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
    v_n := v_n + 1;
  end loop;

  if v_n > 0 then
    raise log 'apply_strategy: bought into % account(s) on bar %', v_n, v_bar_time;
  end if;
  return v_n;
end;
$$;

revoke all on function public.apply_strategy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Resolve every name at apply time
-- ---------------------------------------------------------------------------
-- The convention since 0056, for the reason 0056 through 0062 each learned the
-- hard way: plpgsql resolves function and column names when a statement first
-- *executes*, not when the function is created. `check_function_bodies` will not
-- catch a missing column, a missing function or an ambiguous overload, so every
-- one of those migrations applied cleanly and failed hours later. This is the
-- only cheap place to find out.
do $$
declare
  v_queue text;
  v_eng   text;
begin
  select pr.prosrc into v_queue from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'queue_strategy_checks';
  select pr.prosrc into v_eng from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'apply_strategy';

  -- The correlation table and its columns must exist and be shaped as the two
  -- functions assume. A missing column here is exactly the failure mode above.
  perform id, kind, requested_at from public.strategy_requests where false;

  -- The poller must keep both ids. `perform net.http_get` is the bug this fixes.
  if v_queue ~ 'perform\s+net\.http_get' then
    raise exception 'queue_strategy_checks still discards a request id with perform';
  end if;
  if v_queue not like '%strategy_requests%' then
    raise exception 'queue_strategy_checks does not record its request ids';
  end if;

  -- Both requests must still be scoped to XAUT (0064).
  if v_queue not like '%underlying_asset_symbols=XAUT%' then
    raise exception 'queue_strategy_checks no longer filters tickers to XAUT';
  end if;

  -- The engine must correlate, not describe.
  if v_eng not like '%strategy_requests%' then
    raise exception 'apply_strategy does not read its replies by request id';
  end if;
  if v_eng like '%_replies%' then
    raise exception 'apply_strategy still builds the _replies temp table';
  end if;
  if v_eng ~ '\?\s*''symbol''' then
    raise exception 'apply_strategy still picks its ticker reply by body shape';
  end if;

  -- Carried forward from 0060, but narrowed to `r` alone, and the narrowing is
  -- the point: plpgsql binds a name to its own variables before a statement's
  -- table alias, so the alias to forbid is whichever name the function declares.
  -- apply_delta_strategy declares both `r` and `s` and 0062 forbids both. This
  -- function declares only `r` — `s` is free, and in fact taken: 0046's account
  -- loop reads `from public.strategy_settings s`, and has run that way in
  -- production since. Forbidding `s` here would fail this migration over
  -- working code.
  if v_eng ~* '(from|join)[[:space:]]+[a-z_."]+[[:space:]]+(as[[:space:]]+)?r\M' then
    raise exception 'apply_strategy aliases a table "r", which is its own record variable';
  end if;

  raise log '0065: the auto engine reads its own replies by request id';
end;
$$;
