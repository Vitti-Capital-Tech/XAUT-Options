-- ============================================================================
-- XAUT Options Paper Trading — the auto strategy flattens at its window close
-- Run this whole file in the Supabase SQL Editor after 0014_delta_take_profit_mark.sql.
--
-- The window was only ever an entry gate: outside it apply_strategy consumed the
-- bar and did nothing, so whatever it had sold stayed open overnight and across
-- days, leaving only the 2x stop and expiry settlement to close it. The delta
-- strategy has always stood flat outside its session (S2). This gives the auto
-- strategy the same shape: past window_end it stops trading *and* closes what it
-- holds.
--
-- Three pieces:
--
--   * in_ist_window() — the window test, now defined once. apply_strategy is
--     recreated to call it rather than inlining the arithmetic a second time; an
--     entry gate and an exit trigger that could ever disagree about the same
--     minute is a bug waiting to happen.
--   * queue_auto_exit_checks() — prices the legs it is about to close. Every
--     position the strategy opens carries a stop, so the tpsl poll is already
--     fetching its ticker every 5s; this only covers a leg that somehow has no
--     level armed, and fetches nothing once the account is flat.
--   * apply_auto_exit() — closes every open leg on an armed auto account whose
--     IST clock is outside its window, at the exit side of the book, booking the
--     fill with close_reason = 'window_close'.
--
-- Exits route through close_position_triggered, the same path the stop already
-- uses, rather than through a market order — so the ledger labels them and no
-- order row is invented for a close the engine forced.
--
-- The window is inclusive of window_end, so a 09:15-15:30 account flattens from
-- 15:31. The default window is 00:00-23:59, which no minute of the day falls
-- outside — accounts left on the default keep their positions exactly as before.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Is `p_at` inside an account's trading window? A window whose start is after
-- its end reads as spanning midnight (22:00-06:00), matching the client's
-- inWindow in src/lib/strategy.ts. Stable, not immutable: it reads now() by
-- default and the IST conversion is timezone-table dependent.
-- ---------------------------------------------------------------------------
create or replace function public.in_ist_window(p_start text, p_end text,
                                               p_at timestamptz default now())
returns boolean
language sql
stable
set search_path = public
as $$
  select case when ws <= we then m >= ws and m <= we
              else m >= ws or m <= we end
  from (
    select extract(hour   from (p_at at time zone 'Asia/Kolkata'))::int * 60
         + extract(minute from (p_at at time zone 'Asia/Kolkata'))::int          as m,
           split_part(p_start, ':', 1)::int * 60 + split_part(p_start, ':', 2)::int as ws,
           split_part(p_end,   ':', 1)::int * 60 + split_part(p_end,   ':', 2)::int as we
  ) x;
$$;

comment on function public.in_ist_window(text, text, timestamptz) is
  'Whether an instant falls in an HH:MM-HH:MM IST window, inclusive, honouring a wrap past midnight.';

-- ---------------------------------------------------------------------------
-- Fetch a ticker for anything the exit will need to price and the tpsl poll is
-- not already fetching. Returns the number of calls made — 0 whenever every
-- armed auto account is inside its window or already flat, which is most ticks.
-- ---------------------------------------------------------------------------
create or replace function public.queue_auto_exit_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct p.symbol
    from public.positions p
    join public.strategy_settings s on s.account_id = p.account_id
    where s.armed
      and p.net_qty <> 0
      -- A position with a level armed is already in the tpsl poll's list.
      and p.take_profit is null and p.stop_loss is null
      and not public.in_ist_window(s.window_start, s.window_end)
  loop
    perform net.http_get(
      url := 'https://api.india.delta.exchange/v2/tickers/' || r.symbol,
      timeout_milliseconds := 5000
    );
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Close every open leg on an armed auto account that is past its window.
--
-- Prices come from the freshest per-symbol ticker reply of the last 90 seconds —
-- the same window and the same replies apply_tpsl_triggers reads, so no extra
-- fetch is needed for a position that carries a stop. A leg that cannot be
-- priced is left open and retried on the next tick rather than closed at a
-- guess.
-- ---------------------------------------------------------------------------
create or replace function public.apply_auto_exit()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r      record;
  pos    record;
  v_exit numeric;
  v_n    integer := 0;
begin
  -- Nothing to do on the overwhelming majority of ticks; check that before
  -- parsing a single reply.
  if not exists (
    select 1
    from public.positions p
    join public.strategy_settings s on s.account_id = p.account_id
    where s.armed and p.net_qty <> 0
      and not public.in_ist_window(s.window_start, s.window_end)
  ) then
    return 0;
  end if;

  -- Freshest reply per symbol. The per-symbol ticker replies are bare objects;
  -- prefiltering on that as text keeps the (near-megabyte) chain replies from
  -- being parsed as jsonb at all, the way apply_strategy does.
  drop table if exists _exit_marks;
  create temp table _exit_marks on commit drop as
  select distinct on (sym)
         sym                                                as symbol,
         nullif(res -> 'quotes' ->> 'best_bid', '')::numeric as bid,
         nullif(res -> 'quotes' ->> 'best_ask', '')::numeric as ask,
         nullif(res ->> 'mark_price', '')::numeric           as mark
  from (
    select content::jsonb -> 'result' ->> 'symbol' as sym,
           content::jsonb -> 'result'              as res,
           created
    from net._http_response
    where status_code = 200
      and created > now() - interval '90 seconds'
      and content like '%"result":{%'
  ) s
  where sym is not null
  order by sym, created desc;

  for r in
    select s.account_id, s.window_start, s.window_end
    from public.strategy_settings s
    where s.armed
      and not public.in_ist_window(s.window_start, s.window_end)
      and exists (
        select 1 from public.positions p
        where p.account_id = s.account_id and p.net_qty <> 0
      )
  loop
    for pos in
      select id, symbol, net_qty from public.positions
      where account_id = r.account_id and net_qty <> 0
    loop
      -- A long exits on the bid, a short on the ask; the mark stands in when
      -- that side of the book is momentarily empty.
      select case when pos.net_qty > 0 then coalesce(bid, mark) else coalesce(ask, mark) end
        into v_exit
      from _exit_marks where symbol = pos.symbol;

      if v_exit is null or v_exit <= 0 then
        raise log 'apply_auto_exit: account % — no price for % yet, leaving it open',
          r.account_id, pos.symbol;
        continue;
      end if;

      perform public.close_position_triggered(pos.id, v_exit, 'window_close');
      v_n := v_n + 1;
    end loop;
  end loop;

  if v_n > 0 then
    raise log 'apply_auto_exit: closed % leg(s) past the window', v_n;
  end if;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- apply_strategy, recreated on the shared window test. The body is 0011's, with
-- the inlined minutes arithmetic (v_ws / v_we / v_in) replaced by the call —
-- nothing else changes: same signature, same schedule, same fill path.
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
    select s.account_id, s.moneyness, s.qty, s.window_start, s.window_end, a.user_id
    from public.strategy_settings s
    join public.accounts a on a.id = s.account_id
    where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
  loop
    -- Inside this account's window? apply_auto_exit reads the same test, so the
    -- minute this returns false is exactly the minute the flatten begins.
    if not public.in_ist_window(r.window_start, r.window_end) then
      raise log 'apply_strategy: account % outside its window', r.account_id;
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

-- Engine-only, like the rest of them. The client has its own copy of this rule
-- in src/lib/strategy.ts (inWindow) and never calls across for it.
revoke all on function public.in_ist_window(text, text, timestamptz) from public, anon, authenticated;
revoke all on function public.queue_auto_exit_checks() from public, anon, authenticated;
revoke all on function public.apply_auto_exit() from public, anon, authenticated;
revoke all on function public.apply_strategy() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Schedule. Both halves gate themselves on "an armed account is past its window
-- and still holds something", which is false on nearly every tick, so a 15s
-- cadence costs a single cheap existence check the rest of the day and closes
-- within ~15-30s of the window ending.
-- ---------------------------------------------------------------------------
select cron.schedule('auto-exit-poll',  '15 seconds', $$select public.queue_auto_exit_checks()$$);
select cron.schedule('auto-exit-apply', '15 seconds', $$select public.apply_auto_exit()$$);
