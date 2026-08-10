-- ============================================================================
-- XAUT Options Paper Trading — which days of the week each strategy trades
-- Run this whole file in the Supabase SQL Editor after 0015_auto_strategy_exit.sql.
--
-- Both engines gated on a time of day and nothing else, so a window or a session
-- ran all seven days. Each now carries a days filter alongside it:
--
--     strategy_settings.trade_days        days the auto strategy trades, IST
--     delta_strategy_settings.trade_days  days the delta session runs, Sydney
--
-- ISO weekday numbers — Monday 1 to Sunday 7, extract(isodow)'s own numbering, so
-- the column, the SQL and the client all count the same way. Default is the full
-- week, so nothing changes for an existing account until a day is unselected.
--
-- The day tested is the one the *session opened on*, not the current date. A
-- window or session that wraps past midnight (22:00-06:00) therefore belongs to
-- the day it started: unselect Saturday and a Friday-night session still runs to
-- its close on Saturday morning, which is the reading that matches how the delta
-- engine already keys its counters.
--
-- A day left out is not merely "no entries" — it reads as out of session, so the
-- flatten covers it and neither engine can be left holding a book through a day
-- it does not trade. An empty array is a valid off state: no day is a trading
-- day, so nothing is ever opened.
-- ============================================================================

alter table public.strategy_settings
  add column if not exists trade_days smallint[] not null default '{1,2,3,4,5,6,7}';

alter table public.delta_strategy_settings
  add column if not exists trade_days smallint[] not null default '{1,2,3,4,5,6,7}';

comment on column public.strategy_settings.trade_days is
  'ISO weekdays (Mon 1 - Sun 7, IST) the auto strategy trades. Outside them it is flat. Empty trades never.';
comment on column public.delta_strategy_settings.trade_days is
  'ISO weekdays (Mon 1 - Sun 7, Sydney) the delta session runs. Outside them the session reads closed. Empty trades never.';

-- ---------------------------------------------------------------------------
-- The auto strategy's window test, now taking the days.
--
-- 0015's three-argument form is dropped rather than kept alongside: two
-- overloads that both default their tail would make a two-argument call
-- ambiguous, and every caller is recreated below anyway.
--
-- The window's own day falls out of the same case analysis that decides whether
-- we are inside it — non-null exactly when we are, and equal to the date the
-- window opened on — so one expression answers both halves of the filter.
-- ---------------------------------------------------------------------------
drop function if exists public.in_ist_window(text, text, timestamptz);

create or replace function public.in_ist_window(p_start text, p_end text,
                                               p_days smallint[] default null,
                                               p_at timestamptz default now())
returns boolean
language sql
stable
set search_path = public
as $$
  select wday is not null
     and (p_days is null or extract(isodow from wday)::smallint = any (p_days))
  from (
    select case
             when ws <= we then case when m between ws and we then loc::date end
             when m >= ws  then loc::date
             when m <= we  then loc::date - 1
           end as wday
    from (
      select loc,
             extract(hour from loc)::int * 60 + extract(minute from loc)::int as m,
             split_part(p_start, ':', 1)::int * 60 + split_part(p_start, ':', 2)::int as ws,
             split_part(p_end,   ':', 1)::int * 60 + split_part(p_end,   ':', 2)::int as we
      from (select p_at at time zone 'Asia/Kolkata' as loc) z
    ) x
  ) w;
$$;

comment on function public.in_ist_window(text, text, smallint[], timestamptz) is
  'Whether an instant falls in an HH:MM-HH:MM IST window on one of the given ISO weekdays. Null days means every day; a wrapped window belongs to the day it opened on.';

revoke all on function public.in_ist_window(text, text, smallint[], timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The delta session, now taking the days. Same drop-and-replace reasoning: the
-- two-argument form from 0012 would make the call ambiguous.
--
-- The filter is applied to sday, the session's own day, after the phase is
-- worked out — so a session that opened on a selected day stays open across
-- midnight, and a day left out reports 'closed', which is what routes it into
-- the flatten branch without a rule of its own.
-- ---------------------------------------------------------------------------
drop function if exists public.delta_session(text, text);

create or replace function public.delta_session(p_open text, p_close text,
                                                p_days smallint[] default null,
                                                out phase text, out sday text)
language plpgsql
stable
as $$
declare
  v_local timestamp := now() at time zone 'Australia/Sydney';
  v_min   int;
  v_day   date;
  v_o     int;
  v_c     int;
begin
  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_day := v_local::date;
  v_o   := split_part(p_open,  ':', 1)::int * 60 + split_part(p_open,  ':', 2)::int;
  v_c   := split_part(p_close, ':', 1)::int * 60 + split_part(p_close, ':', 2)::int;

  if v_o <= v_c then
    sday  := v_day::text;
    phase := case when v_min < v_o then 'before'
                  when v_min <= v_c then 'open'
                  else 'closed' end;
  elsif v_min >= v_o then
    phase := 'open';  sday := v_day::text;
  elsif v_min <= v_c then
    phase := 'open';  sday := (v_day - 1)::text;
  else
    phase := 'closed'; sday := (v_day - 1)::text;
  end if;

  -- Not a trading day: closed, whatever the clock says.
  if p_days is not null
     and not (extract(isodow from sday::date)::smallint = any (p_days)) then
    phase := 'closed';
  end if;
end;
$$;

comment on function public.delta_session(text, text, smallint[]) is
  'Session phase and session day on the Sydney clock. A session day outside the given ISO weekdays reports closed. Null days means every day.';

-- ---------------------------------------------------------------------------
-- The auto strategy's three functions, recreated to pass trade_days. Bodies are
-- 0015's; only the in_ist_window calls change.
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
      and not public.in_ist_window(s.window_start, s.window_end, s.trade_days)
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
      and not public.in_ist_window(s.window_start, s.window_end, s.trade_days)
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
    select s.account_id
    from public.strategy_settings s
    where s.armed
      and not public.in_ist_window(s.window_start, s.window_end, s.trade_days)
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
           s.trade_days, a.user_id
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

-- ---------------------------------------------------------------------------
-- apply_delta_strategy, recreated to pass trade_days into delta_session. Body is
-- 0012's; only that one call changes. Everything downstream already keys off the
-- phase it returns, so an off-day flattens through the existing S2 branch.
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

    -- cycle_seconds spacing.
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
    if s.entered_day is distinct from v_day then
      if s.pairs > 0 then
        perform public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.pairs, v_spot);
      end if;
      update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
    -- Δp = Σ (signed lots × the leg's option delta). No contract-value factor:
    -- that is the unit the worked example in 5.2 is written in, and the band is
    -- calibrated to the same one.
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

revoke all on function public.delta_session(text, text, smallint[]) from public, anon, authenticated;
revoke all on function public.queue_auto_exit_checks() from public, anon, authenticated;
revoke all on function public.apply_auto_exit() from public, anon, authenticated;
revoke all on function public.apply_strategy() from public, anon, authenticated;
revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
