-- 0037_auto_trailing_stop.sql
--
-- Run this whole file in the Supabase SQL Editor after 0036_drop_delta_remarks.sql.
--
-- The auto strategy's stop becomes two stops, and the tighter one wins.
--
--     entry stop   avg_entry_price      x (1 + stop_loss_pct  / 100)   fixed
--     trail stop   last 1m candle close x (1 + trail_stop_pct / 100)   re-read every minute
--
--     stop_loss = least(entry stop, trail stop)
--
-- The entry stop is what the strategy has always had: a share of the premium
-- collected, and it never moves. The trailing stop measures the same share
-- against what the option is *trading at now*, so as a short goes your way the
-- stop follows the premium down and locks the gain in.
--
-- Worked, on a $4 short with both set to 100:
--
--     premium  entry stop   trail stop   stop_loss
--     4.00     8.00         8.00         8.00
--     2.00     8.00         4.00         4.00      <- trail is tighter, it wins
--     1.00     8.00         2.00         2.00
--     3.00     8.00         6.00         6.00      <- premium rose; so did the stop
--
-- Read that last row before switching this on. `least` is taken of the two
-- levels *as they stand this minute*, which is what was asked for — so the trail
-- follows the premium back up as well as down, and the stop can loosen again. It
-- can never loosen past the entry stop, so the worst case is bounded by the
-- number that was already there. Making it ratchet — never rising once it has
-- fallen — is a one-line change to `apply_trail_stops` (take `least` against the
-- position's current `stop_loss` as well), and it is deliberately not the rule
-- here.
--
-- Both percentages mean the same thing, which is the reason the trail is not
-- written as a bare multiplier: "how much of the premium am I willing to give
-- back", measured from the entry in one case and from the last minute's close in
-- the other. 100 means give it all back, 50 means half. `trail_stop_pct = 0`
-- switches the trailing half off, which is the default, so nothing changes for an
-- existing account until the number is moved.
--
-- ---------------------------------------------------------------------------
-- Where the minute close comes from
-- ---------------------------------------------------------------------------
-- Delta's own 1-minute candles for that option symbol, not the mark:
--
--     /v2/history/candles?resolution=1m&symbol=C-XAUT-4350-140826
--
-- They are dense — the venue carries the last traded price forward through
-- minutes with no volume, so a bar is published every minute whether or not the
-- strike traded. The most recently *closed* bar is used, never the one still
-- being traded, whose close is only the live price wearing a candle's name.
--
-- One fetch per held symbol every 30 seconds, and only for symbols that need it:
-- an open short, on an auto account, with the trailing half switched on. It stays
-- running while the account is disarmed — arming gates entries, and a stop on a
-- position that is already open is not an entry.
--
-- ---------------------------------------------------------------------------
-- The reply-matching problem, and why apply_strategy is recreated below
-- ---------------------------------------------------------------------------
-- A candle reply has no symbol in it. `/v2/tickers/<symbol>` answers with an
-- object carrying its own `symbol`, but `/v2/history/candles` answers with a bare
-- array of bars — nothing says which instrument they belong to. The only link is
-- pg_net's request id, so the queue records it, and that is what
-- `trail_candle_requests` is for.
--
-- It also fixes a collision this feature would otherwise have caused.
-- `apply_strategy` finds its hourly index bar by looking for the freshest reply
-- whose first element has `open` and no `symbol` — which is exactly the shape of
-- these option candles. Left alone, the auto strategy would have read a
-- 1-minute option bar as its hourly index bar: wrong colour, wrong bar time, a
-- sale on noise and `last_acted` stamped with a minute that is not an hour. So
-- its reply filter now excludes anything this queue asked for. Any future
-- per-symbol candle fetch has to register in the same table for the same reason.

-- ---------------------------------------------------------------------------
-- 1. The setting
-- ---------------------------------------------------------------------------
alter table public.strategy_settings
  add column if not exists trail_stop_pct numeric(20, 8) not null default 0;

alter table public.strategy_settings drop constraint if exists strategy_trail_stop_pct_chk;
alter table public.strategy_settings
  add constraint strategy_trail_stop_pct_chk check (trail_stop_pct >= 0);

comment on column public.strategy_settings.trail_stop_pct is
  'Trailing stop as a percent of the premium, measured from the last closed 1m candle close: trail = close * (1 + pct/100). The armed stop is the lesser of this and the entry stop. 0 switches trailing off.';

comment on column public.strategy_settings.stop_loss_pct is
  'Entry stop as a percent of the premium collected, on the mark: stop = avg_entry_price * (1 + pct/100). 100 is 2x entry. 0 arms no entry stop, leaving the trailing stop alone to govern.';

-- ---------------------------------------------------------------------------
-- 2. Which symbol each candle fetch was for
-- ---------------------------------------------------------------------------
-- pg_net hands back a request id and drops the reply into net._http_response
-- under the same id. For a candle reply that id is the only thing tying the bars
-- to an instrument, so it is stored rather than guessed at.
create table if not exists public.trail_candle_requests (
  request_id bigint primary key,
  symbol     text not null,
  created_at timestamptz not null default now()
);

create index if not exists trail_candle_requests_created_idx
  on public.trail_candle_requests (created_at);

-- No RLS and no grants: nothing outside the two cron functions ever reads this,
-- and it holds no account data — just a request id and a public symbol.
revoke all on table public.trail_candle_requests from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Poll — one candle fetch per symbol that needs one
-- ---------------------------------------------------------------------------
-- A ten-minute window of bars rather than one: a request that times out or comes
-- back late leaves the next one still holding enough history to find a closed
-- bar, so a single missed fetch does not freeze the stop.
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
    where p.net_qty < 0
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

revoke all on function public.queue_trail_checks() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Apply — move each stop to the lesser of the two levels
-- ---------------------------------------------------------------------------
-- One pass per symbol, off the freshest reply for it. The write is guarded on the
-- level actually changing: this runs every 30 seconds against a number that moves
-- once a minute, and an unguarded update would touch every position row on every
-- pass — waking the realtime feed, and with it every open tab, for nothing.
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

    -- `least` ignores nulls, which is what makes stop_loss_pct = 0 mean "no entry
    -- stop, trail alone" rather than "no stop at all".
    with target as (
      select p.id,
             least(
               case when s.stop_loss_pct > 0
                    then p.avg_entry_price * (1 + s.stop_loss_pct / 100.0) end,
               v_close * (1 + s.trail_stop_pct / 100.0)
             ) as stop
      from public.positions p
      join public.strategy_settings s on s.account_id = p.account_id
      join public.accounts a on a.id = p.account_id and a.kind = 'auto'
      where p.symbol = r.symbol
        and p.net_qty < 0
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

revoke all on function public.apply_trail_stops() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. apply_strategy, which must not read an option's minute bar as its own
-- ---------------------------------------------------------------------------
-- Body is 0032's, unchanged but for one line in the reply filter: replies this
-- feature asked for are excluded by request id. See the header for why that
-- matters — a 1-minute option bar has exactly the shape the index-candle filter
-- was looking for.
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
    -- The entry stop only: the trailing half is set by apply_trail_stops off the
    -- next closed minute, within about a minute of this fill. An account running
    -- trailing alone (stop_loss_pct = 0) therefore opens with no stop for that
    -- minute — worth knowing, and the reason to keep an entry stop set as the
    -- outer bound even when the trail is doing the work.
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

-- ---------------------------------------------------------------------------
-- 6. Schedule
-- ---------------------------------------------------------------------------
-- Twice a minute, so a stop follows a candle close within about a minute rather
-- than two: poll fetches, apply reads whatever the previous poll landed. Both
-- gate themselves on there being a trailing position at all — with none, the poll
-- makes no request and the apply loop finds no reply to read, so an install that
-- does not use this costs one index scan every 30 seconds.
select cron.unschedule('trail-poll')  where exists (select 1 from cron.job where jobname = 'trail-poll');
select cron.unschedule('trail-apply') where exists (select 1 from cron.job where jobname = 'trail-apply');
select cron.schedule('trail-poll',  '30 seconds', $$select public.queue_trail_checks()$$);
select cron.schedule('trail-apply', '30 seconds', $$select public.apply_trail_stops()$$);
