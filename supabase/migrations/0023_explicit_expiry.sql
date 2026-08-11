-- ============================================================================
-- XAUT Options Paper Trading — pick the expiry by date, on both strategies
-- Run this whole file in the Supabase SQL Editor after 0022_delta_session_ist.sql.
--
--     strategy_settings.expiry_label        ddmmyy, or null
--     delta_strategy_settings.expiry_label  ddmmyy, or null
--
-- Both engines chose their expiry by rule — 'today' / 'nearest' for auto,
-- 'nearest' / 'next out' for delta. The tabs now offer the live expiry dates
-- instead, the way the option chain's tabs do, and store the chosen ddmmyy.
--
-- READ THIS. A date is not a rule, so it goes stale. Once the chosen expiry
-- settles at 16:00 UTC, that account has no valid expiry and **stops trading until
-- a new date is picked** — the engine skips the bar or the cycle and logs why. It
-- deliberately does not fall through to another expiry: silently trading a
-- contract nobody selected is the fault 0018 was written to remove, and this makes
-- the same guarantee for an explicit choice.
--
-- Null keeps the old rule, which is what a freshly seeded account and an account
-- that predates this migration both use. So nothing changes until a date is
-- chosen, and clearing the column restores the rule.
--
-- expiry_rule and expiry_pick therefore stay: they are the null-label behaviour,
-- not dead weight.
-- ============================================================================

alter table public.strategy_settings
  add column if not exists expiry_label text;

alter table public.delta_strategy_settings
  add column if not exists expiry_label text;

-- Six digits or nothing. A malformed label would fall through to_date and match no
-- expiry at all, which reads identically to "the market has none".
alter table public.strategy_settings drop constraint if exists strategy_expiry_label_chk;
alter table public.strategy_settings
  add constraint strategy_expiry_label_chk check (expiry_label is null or expiry_label ~ '^\d{6}$');

alter table public.delta_strategy_settings drop constraint if exists delta_expiry_label_chk;
alter table public.delta_strategy_settings
  add constraint delta_expiry_label_chk check (expiry_label is null or expiry_label ~ '^\d{6}$');

comment on column public.strategy_settings.expiry_label is
  'The chosen expiry as ddmmyy. Trading stops once it settles — a date does not roll. Null falls back to expiry_rule.';
comment on column public.delta_strategy_settings.expiry_label is
  'The chosen expiry as ddmmyy. The cycle stands down once it settles — a date does not roll. Null falls back to expiry_pick.';

-- ---------------------------------------------------------------------------
-- apply_strategy: an explicit label wins, and never falls through. Body is
-- 0021's; only the expiry resolution changes.
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
    if not public.in_ist_window(r.window_start, r.window_end, r.trade_days) then
      raise log 'apply_strategy: account % outside its window or off-day', r.account_id;
      update public.strategy_settings set last_acted = v_bar_time where account_id = r.account_id;
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

-- ---------------------------------------------------------------------------
-- apply_delta_strategy: same rule for the chosen date. Body is 0021's; only the
-- expiry resolution changes.
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
  v_legs      int;
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

    -- Refresh spacing. Clearing last_cycle (the tab's manual refresh) makes the
    -- next tick act regardless of how long the interval is.
    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    select phase, sday into v_phase, v_day
    from public.delta_session(s.session_open, s.session_close, s.trade_days);

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session close: flatten, whatever the band says --------------------
    -- Ahead of the expiry check on purpose: a stale expiry must never strand an
    -- open book. Flattening reads the positions, not the setting.
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

    -- Expiry. A chosen date wins outright, honoured only while listed and
    -- unsettled; with none chosen, expiry_pick's nearest/next applies.
    if s.expiry_label is not null then
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label = s.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
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
    end if;

    if v_exp is null then
      raise log 'apply_delta_strategy: account % — expiry % unavailable, standing down',
        r.account_id, coalesce(s.expiry_label, '(by rule)');
      continue;
    end if;

    -- ---- S4: daily entry ---------------------------------------------------
    if s.entered_day is distinct from v_day then
      if s.pairs <= 0 then
        update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
        continue;
      end if;

      v_legs := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.pairs, s.qty, v_spot);
      if v_legs < 2 then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Net portfolio delta ----------------------------------------------
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

    if s.target_landing = 'mid' then
      v_target := (s.band_low + s.band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(s.band_low + s.band_buffer, (s.band_low + s.band_high) / 2);
    else
      v_target := greatest(s.band_high - s.band_buffer, (s.band_low + s.band_high) / 2);
    end if;

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
      if v_used >= s.max_rolls then
        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;
        v_acted := true;
        exit;
      end if;

      select * into v_repl from public.delta_pick_premium(
        v_exp, v_rollside, s.entry_premium, s.min_premium, s.tie_break, v_leg.strike);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

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

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
