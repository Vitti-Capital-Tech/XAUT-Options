-- 0046_auto_strategy_buys.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0045_futures_band_without_gamma.sql.
--
-- The auto strategy stops selling and starts buying. The signal is unchanged --
-- last closed 1h bar of the index, red buys a call, green buys a put, at the
-- chosen moneyness off the chosen expiry, inside the window -- and so is every
-- control on the bar. What changes is the side of every trade, and the four
-- things that follow from it.
--
-- Read as a strategy it is now the mirror of what it was: selling a call into a
-- red bar is a bet that the fall continues (or at least does not reverse past the
-- strike); buying one is a bet on the bounce. Same bars, opposite view. That is
-- what was asked for, and it is stated here because nothing else in the file will
-- say it.
--
-- ---------------------------------------------------------------------------
-- 1. The trade
-- ---------------------------------------------------------------------------
-- A buy lifts the ask; a sell hit the bid. So the strike is now priced, filled
-- and vetoed off `best_ask`, and the order goes in with `side = 'buy'`. Nothing
-- else about the selection moves: the same ATM row, the same moneyness offset in
-- the same direction, the same expiry rule.
--
-- ---------------------------------------------------------------------------
-- 2. The brackets invert
-- ---------------------------------------------------------------------------
-- Both levels are still a percent of the premium and still watched on the
-- option's own mark. What flips is which way each one points, because a long
-- gains as its mark rises and a short gained as it fell:
--
--     short (before)                          long (now)
--     stop = entry x (1 + stop_pct/100)       stop = entry x (1 - stop_pct/100)
--     take = entry x (1 - take_pct/100)       take = entry x (1 + take_pct/100)
--
-- So `stop_loss_pct = 50` now means "get out having lost half the premium", and
-- `take_profit_pct = 70` means "get out having made 70% of it" -- a $4 long stops
-- at $2 and takes profit at $6.80. Both read as the share of the premium at risk
-- or in hand, which is the same sentence they read as before.
--
-- `apply_tpsl_triggers` needs no change at all: on a mark trigger it already sets
-- `v_up := v_long`, so a long's take-profit fires as the mark *rises* and its stop
-- as the mark falls. It has been direction-aware since it was written; nothing
-- had ever handed it a long option before.
--
-- ---------------------------------------------------------------------------
-- 3. The percentage bounds swap, and 100 changes meaning
-- ---------------------------------------------------------------------------
-- `take_profit_pct` was capped below 100 because a short cannot make more than
-- the premium it collected. A long can: 150 is a perfectly good target, 2.5x the
-- premium paid. The cap is dropped.
--
-- `stop_loss_pct` had no ceiling because a short can give back any multiple. A
-- long cannot lose more than it paid, so 100 puts the stop at exactly zero and
-- anything above it below zero -- prices no option ever marks at. Rather than add
-- a constraint that every existing row would violate, the engine treats
-- `>= 100` as **no fixed stop**, and the control bar caps its input at 99.
--
-- >>> Worth knowing before running this. The column's default is 100, so an auto
-- >>> account that has never touched the field is on 100 -- which meant "stop at
-- >>> twice the premium" and now means "no fixed stop". Set the field to what you
-- >>> actually want. The loss is bounded either way now: the most a long option
-- >>> can lose is the premium it paid, which is what makes running without a stop
-- >>> survivable here in a way it never was on a short.
--
-- ---------------------------------------------------------------------------
-- 4. The trail ratchets the other way
-- ---------------------------------------------------------------------------
-- The trailing half measured the same share against what the option trades at
-- now, and `least` kept whichever of the two levels was tighter. On a long,
-- tighter means *higher*: the stop follows the premium up and locks the gain in.
--
--     trail = last 1m close x (1 - trail_stop_pct/100)
--     stop  = greatest(entry stop, trail stop)
--
-- `greatest` ignores nulls exactly as `least` did, so `stop_loss_pct = 0` still
-- means "trail alone" rather than "no stop at all". And the caveat from 0037 is
-- unchanged in shape: the pair is re-read every minute, so a trail can loosen
-- again as the premium falls back -- never past the entry stop, which is the
-- outer bound.
--
-- ---------------------------------------------------------------------------
-- 5. min_premium becomes max_premium
-- ---------------------------------------------------------------------------
-- The column is renamed, not reinterpreted, because the test genuinely reverses.
-- It existed to veto a trade that made no economic sense: a seller will not sell
-- for peanuts, so a bid under the floor skipped the bar. A buyer's version of the
-- same sentence is that they will not overpay, so an **ask above the cap** skips
-- the bar. `0` still disables it.
--
-- It still vetoes rather than hunting: the strike is `moneyness`'s to choose, and
-- searching for whatever fits the budget would quietly override that.
--
-- ---------------------------------------------------------------------------
-- What is deliberately NOT here
-- ---------------------------------------------------------------------------
-- `apply_auto_exit` -- the window-close flatten -- already exits a long on the bid
-- and a short on the ask, so it needed nothing. Margin needs nothing either: a
-- long's risk is the premium it paid, which `execute_fill` debits and
-- `valuePosition` blocks, and no rule in this book reads equity.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The rename, and the two bounds
-- ---------------------------------------------------------------------------
-- Guarded so the file is re-runnable: a second run finds max_premium already
-- there and does nothing.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'strategy_settings'
      and column_name = 'min_premium'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'strategy_settings'
      and column_name = 'max_premium'
  ) then
    alter table public.strategy_settings rename column min_premium to max_premium;
  end if;
end;
$$;

alter table public.strategy_settings
  add column if not exists max_premium numeric(20, 8) not null default 0;

alter table public.strategy_settings drop constraint if exists strategy_min_premium_chk;
alter table public.strategy_settings drop constraint if exists strategy_max_premium_chk;
alter table public.strategy_settings
  add constraint strategy_max_premium_chk check (max_premium >= 0);

comment on column public.strategy_settings.max_premium is
  'Most the strategy will pay per contract; a bar whose ask is above it is skipped, not bought. 0 disables it.';

-- A long can target more than the premium it paid, so the old ceiling goes.
alter table public.strategy_settings drop constraint if exists strategy_take_profit_pct_chk;
alter table public.strategy_settings
  add constraint strategy_take_profit_pct_chk check (take_profit_pct >= 0);

comment on column public.strategy_settings.take_profit_pct is
  'Percent of the premium made, as a level on the mark: take_profit = entry x (1 + pct/100). 0 arms none.';

comment on column public.strategy_settings.stop_loss_pct is
  'Percent of the premium at risk: stop_loss = entry x (1 - pct/100). 0 arms none, and 100 or more would put the level at or below zero, which arms none either.';

-- ---------------------------------------------------------------------------
-- The engine, buying
-- ---------------------------------------------------------------------------
-- Line for line 0037 apart from the side of the trade, the side of the book
-- it is priced and vetoed on, and the two bracket levels.
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
  drop table if exists _replies;
  create temp table _replies on commit drop as
  select row_number() over (order by created desc) as rn,
         content::jsonb -> 'result' as result
  from net._http_response resp
  where status_code = 200
    and created > now() - interval '150 seconds'
    and content like '%"result":[%'
    -- Not one of the per-symbol option candle fetches. Those are also a bare
    -- array of bars with `open` and no `symbol`, so without this the freshest of
    -- them would be picked as the hourly index bar.
    and not exists (
      select 1 from public.trail_candle_requests q where q.request_id = resp.id
    );

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

-- ---------------------------------------------------------------------------
-- The trail, ratcheting up
-- ---------------------------------------------------------------------------
create or replace function public.apply_trail_stops()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r        record;
  v_close  numeric;
  v_cutoff bigint;
  v_rows   int;
  v_n      int := 0;
begin
  -- The start of the last completed minute. A bar stamped later than this is the
  -- one still trading, and its close is just the live price.
  v_cutoff := (extract(epoch from now())::bigint / 60) * 60 - 60;

  for r in
    select distinct on (q.symbol) q.symbol, resp.content
    from public.trail_candle_requests q
    join net._http_response resp on resp.id = q.request_id
    where resp.status_code = 200
      and resp.created > now() - interval '150 seconds'
      and resp.content like '%"result":[%'
    order by q.symbol, resp.created desc
  loop
    v_close := null;

    begin
      select (b ->> 'close')::numeric into v_close
      from jsonb_array_elements(r.content::jsonb -> 'result') b
      where (b ->> 'time')::bigint <= v_cutoff
      order by (b ->> 'time')::bigint desc
      limit 1;
    exception when others then
      -- A malformed or empty reply is skipped, never fatal: the stop simply
      -- stays where it is until the next fetch lands.
      raise log 'apply_trail_stops: could not read candles for % — %', r.symbol, sqlerrm;
      continue;
    end;

    if v_close is null or v_close <= 0 then
      continue;
    end if;

    -- `greatest` on a long, where `least` was right on a short: tighter means
    -- *higher* here, so the stop follows the premium up and locks the gain in. It
    -- ignores nulls exactly as `least` did, which is what keeps stop_loss_pct = 0
    -- meaning "no entry stop, trail alone" rather than "no stop at all" — and the
    -- `< 100` keeps a level that would land at or below zero out of the pair.
    with target as (
      select p.id,
             greatest(
               case when s.stop_loss_pct > 0 and s.stop_loss_pct < 100
                    then p.avg_entry_price * (1 - s.stop_loss_pct / 100.0) end,
               v_close * (1 - s.trail_stop_pct / 100.0)
             ) as stop
      from public.positions p
      join public.strategy_settings s on s.account_id = p.account_id
      join public.accounts a on a.id = p.account_id and a.kind = 'auto'
      where p.symbol = r.symbol
        and p.net_qty > 0
        and s.trail_stop_pct > 0
    )
    update public.positions p
    set stop_loss = t.stop,
        -- Both levels are prices on the option's own premium, so the bracket has
        -- to be watching the mark and not the index.
        tpsl_trigger = 'mark'
    from target t
    where t.id = p.id
      and (p.stop_loss is distinct from t.stop or p.tpsl_trigger is distinct from 'mark');

    get diagnostics v_rows = row_count;
    v_n := v_n + v_rows;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- The poller behind it
-- ---------------------------------------------------------------------------
-- Same filter, other side. Without this one line the trail would have no
-- candles to move on, and would silently never move.
-- ---------------------------------------------------------------------------
create or replace function public.queue_trail_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r     record;
  v_now bigint;
  v_id  bigint;
  v_n   int := 0;
begin
  -- Rows outlive the 150-second window apply reads, by enough that a slow reply
  -- still finds its symbol, and not so much that this grows without bound.
  delete from public.trail_candle_requests where created_at < now() - interval '10 minutes';

  v_now := extract(epoch from now())::bigint;

  for r in
    select distinct p.symbol
    from public.positions p
    join public.strategy_settings s on s.account_id = p.account_id
    join public.accounts a on a.id = p.account_id and a.kind = 'auto'
    where p.net_qty > 0
      and s.trail_stop_pct > 0
  loop
    select net.http_get(
      url := 'https://api.india.delta.exchange/v2/history/candles?resolution=1m&symbol='
             || r.symbol || '&start=' || (v_now - 600) || '&end=' || v_now,
      timeout_milliseconds := 5000
    ) into v_id;

    insert into public.trail_candle_requests (request_id, symbol)
    values (v_id, r.symbol)
    on conflict (request_id) do nothing;

    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;
