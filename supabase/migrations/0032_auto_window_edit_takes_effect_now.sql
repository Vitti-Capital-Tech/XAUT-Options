-- 0032_auto_window_edit_takes_effect_now.sql
--
-- Run this whole file in the Supabase SQL Editor after 0031_delta_margin_guard.sql.
--
-- Widening the auto strategy's window did not bring the next trade forward. Move
-- the start time back so that *now* falls inside the window, and nothing happened
-- until the following hourly bar closed — up to an hour of silence on a change the
-- trader had just made and could see had taken effect on screen.
--
-- Two lines caused it, and they have to be read together:
--
--     where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
--     ...
--     if not public.in_ist_window(r.window_start, r.window_end, r.trade_days) then
--       update public.strategy_settings set last_acted = v_bar_time ...;   -- <-- here
--       continue;
--     end if;
--
-- The skip *consumed the bar*. Every minute the account sat outside its window,
-- the engine stamped last_acted with the current bar — so by the time the window
-- was widened, the loop filter no longer selected that account at all. The bar had
-- been marked done by the branch whose whole point was that it did nothing.
--
-- Worked example, the one this was reported from. Window 08:00–15:30, clock at
-- 04:00 IST, so the last closed bar is the one that closed at 03:30:
--
--   old   04:00  outside window -> skip, stamp last_acted = that bar
--         04:00  trader sets window_start = 03:30
--         04:01  in_ist_window now true, but last_acted = v_bar_time, so the
--                loop filter drops the account. Nothing.
--         04:31  next bar closes, v_bar_time advances, and only now it trades.
--
--   new   04:01  trades.
--
-- ---------------------------------------------------------------------------
-- The fix, and why it is two changes rather than one
-- ---------------------------------------------------------------------------
--
-- 1. The window is tested at the **bar's close instant**, not at now().
--
--    "Should this bar be traded?" is a question about the bar, and a bar belongs
--    to the moment it closed. Testing at now() asked a different question — "is
--    the trader's window open at this instant?" — which is the right test for
--    flattening (apply_auto_exit still uses it, unchanged) and the wrong one for
--    deciding whether a signal counts.
--
-- 2. No last_acted stamp on the way out.
--
--    Without 1, dropping the stamp alone would mean a window opening at 08:00
--    trades immediately on the 07:30 bar — a signal that closed before the window
--    began. With 1 in place that bar is correctly rejected on its own close time,
--    so the stamp is no longer doing any work and can go. Dropping it is what
--    leaves the bar available if the window is later widened onto it.
--
-- Together they give the behaviour the trader expects, in all three cases:
--
--   * Window widened backwards onto a bar that has already closed inside the new
--     window -> traded on the next minute's tick.
--   * Ordinary day, window 08:00–15:30 -> the 07:30 bar is still rejected (it
--     closed outside), the 08:30 bar is the first taken. Unchanged from today.
--   * Start time moved *later*, past the clock -> the bar that closed under the
--     old window is now outside the new one and is rejected, and apply_auto_exit
--     flattens on its own now()-based test. Also unchanged.
--
-- ---------------------------------------------------------------------------
-- What this does not change
-- ---------------------------------------------------------------------------
--
-- last_acted is still stamped by every other skip path — no expiry, no strikes,
-- no bid, premium under the floor — because each of those really has dealt with
-- the bar: the signal was read and answered, just not with an order. Only "you
-- were not trading then" is not an answer, and that is the one being fixed.
--
-- Nothing else in the function moves. Same signature, same schedule, same fill
-- path, same min_premium floor (which is a separate reason a bar can be skipped,
-- and the more common one — see the log line it raises).
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
  drop table if exists _replies;
  create temp table _replies on commit drop as
  select row_number() over (order by created desc) as rn,
         content::jsonb -> 'result' as result
  from net._http_response
  where status_code = 200
    and created > now() - interval '150 seconds'
    and content like '%"result":[%';

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
           s.trade_days, s.min_premium, s.expiry_rule, s.expiry_label,
           s.stop_loss_pct, s.take_profit_pct, a.user_id
    from public.strategy_settings s
    join public.accounts a on a.id = s.account_id
    where s.armed and (s.last_acted is null or s.last_acted < v_bar_time)
  loop
    -- Was this *bar* inside the account's window when it closed? Tested at the
    -- bar's own close instant, not at now(), and with no last_acted stamp on the
    -- way out. Both halves matter -- see the header.
    if not public.in_ist_window(r.window_start, r.window_end, r.trade_days,
                                to_timestamp(v_bar_time) + interval '1 hour') then
      -- Only worth a line when the clock is inside the window but the bar is not:
      -- that is the surprising case, and it happens about once per window open.
      -- Being outside the window entirely is meant to be quiet -- and without the
      -- stamp this branch is now reached every minute, so logging it every time
      -- would bury the log in the ordinary overnight case.
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
             symbol, strike, best_bid, contract_value, product_id
      from _chain where contract_type = v_kind and expiry_label = v_exp
    ) q
    where q.rn = v_rn;

    if v_tgt.best_bid is null or v_tgt.best_bid <= 0 or v_tgt.contract_value is null then
      raise log 'apply_strategy: account % — % has no bid, skipping bar %',
        r.account_id, v_tgt.symbol, v_bar_time;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end if;

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
      perform public.execute_fill(v_order_id, v_lots, v_tgt.best_bid, 0, v_spot);
    exception when others then
      raise log 'apply_strategy: account % fill failed on % — %',
        r.account_id, v_tgt.symbol, sqlerrm;
      update public.orders set status = 'cancelled', cancel_reason = 'auto strategy fill failed'
      where id = v_order_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
      continue;
    end;

    -- The bracket, both sides as a percent of the premium and both on the mark.
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
