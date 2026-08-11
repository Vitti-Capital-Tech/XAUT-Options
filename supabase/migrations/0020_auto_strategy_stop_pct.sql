-- ============================================================================
-- XAUT Options Paper Trading — the auto strategy's stop becomes a percentage
-- Run this whole file in the Supabase SQL Editor after 0019_delta_entry_all_or_nothing.sql.
--
-- The stop was hardcoded at twice the entry premium, on the mark, with no way to
-- change it:
--
--     stop_loss = 2 * avg_entry_price
--
--     strategy_settings.stop_loss_pct   percent of the premium collected; 0 = no stop
--
-- Read as "how much of the premium am I willing to give back", which is the
-- number a premium seller actually thinks in:
--
--     stop_loss = avg_entry_price x (1 + stop_loss_pct / 100)
--
--     100  ->  2.00x entry   a $4 short stops at $8    (lose the whole premium)
--      50  ->  1.50x entry   a $4 short stops at $6    (lose half of it)
--     200  ->  3.00x entry   a $4 short stops at $12   (lose twice it)
--
-- Default 100, which is exactly the old hardcoded 2x — nothing changes for an
-- existing account until the number is moved. 0 arms no stop at all; the position
-- then runs to the window flatten or to expiry settlement, so set it deliberately.
--
-- The level is re-based on avg_entry_price each time the strategy adds to a
-- symbol, so a percentage stop follows the blended entry rather than staying
-- pinned to the first fill.
-- ============================================================================

alter table public.strategy_settings
  add column if not exists stop_loss_pct numeric(20, 8) not null default 100;

alter table public.strategy_settings drop constraint if exists strategy_stop_loss_pct_chk;
alter table public.strategy_settings
  add constraint strategy_stop_loss_pct_chk check (stop_loss_pct >= 0);

comment on column public.strategy_settings.stop_loss_pct is
  'Stop as a percent of the premium collected, on the mark: stop_loss = avg_entry_price * (1 + pct/100). 100 is the old 2x entry. 0 arms no stop.';

-- ---------------------------------------------------------------------------
-- apply_strategy, recreated with the configurable stop. Body is 0018's; the only
-- changes are stop_loss_pct joining the account select and the stop arithmetic.
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
           s.trade_days, s.min_premium, s.expiry_rule, s.stop_loss_pct, a.user_id
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

    -- Stop as a percent of the premium collected, watched on the mark: at 100 the
    -- mark reaching twice the entry gives back exactly the premium. Read off
    -- avg_entry_price, so adding to a symbol re-bases the level onto the blended
    -- entry rather than leaving it pinned to the first fill. At 0, no stop is armed.
    select avg_entry_price into v_avg
    from public.positions
    where account_id = r.account_id and symbol = v_tgt.symbol and net_qty <> 0;
    if found then
      update public.positions
      set stop_loss = case when r.stop_loss_pct > 0
                           then v_avg * (1 + r.stop_loss_pct / 100.0) end,
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
