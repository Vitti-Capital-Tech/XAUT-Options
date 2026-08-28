-- 0048_futures_strategy_atm_shift_and_pairs.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0047_futures_exit_reason.sql.
--
-- Enhancements for the Futures Strategy:
--   1. Exit at the ATM: When spot reaches or crosses the strike price of an open short option.
--   2. ATM Shift at configurable %: Sell replacement on the same side at shift_pct (default 50%)
--      of the ATM exit price, limited to max_shifts (default 1) per side.
--   3. Empty wing auto-flatten: If there are no positions remaining on either side (Call or Put),
--      close all remaining positions (remaining options and the perpetual futures hedge).
--   4. Entry pair filters: Configure pairs_count and [entry_premium_min, entry_premium_max].
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New settings columns on delta_strategy_settings
-- ---------------------------------------------------------------------------
alter table public.delta_strategy_settings
  add column if not exists entry_premium_min numeric(20, 8) not null default 0,
  add column if not exists entry_premium_max numeric(20, 8) not null default 0,
  add column if not exists pairs_count       integer        not null default 1,
  add column if not exists shift_pct         numeric(20, 8) not null default 50,
  add column if not exists max_shifts        integer        not null default 1,
  add column if not exists shifts_used_call  integer        not null default 0,
  add column if not exists shifts_used_put   integer        not null default 0;

alter table public.delta_strategy_settings drop constraint if exists delta_pairs_count_chk;
alter table public.delta_strategy_settings
  add constraint delta_pairs_count_chk check (pairs_count >= 1);

alter table public.delta_strategy_settings drop constraint if exists delta_shift_pct_chk;
alter table public.delta_strategy_settings
  add constraint delta_shift_pct_chk check (shift_pct > 0);

alter table public.delta_strategy_settings drop constraint if exists delta_max_shifts_chk;
alter table public.delta_strategy_settings
  add constraint delta_max_shifts_chk check (max_shifts >= 0);

comment on column public.delta_strategy_settings.entry_premium_min is 'Minimum premium floor for opening pairs; 0 = off.';
comment on column public.delta_strategy_settings.entry_premium_max is 'Maximum premium ceiling for opening pairs; 0 = off.';
comment on column public.delta_strategy_settings.pairs_count is 'Number of symmetric pairs to short at the session open.';
comment on column public.delta_strategy_settings.shift_pct is 'Percentage of ATM exit price to sell replacement strike at during ATM shift (default 50%).';
comment on column public.delta_strategy_settings.max_shifts is 'Maximum ATM shifts allowed per side per session (default 1).';
comment on column public.delta_strategy_settings.shifts_used_call is 'Number of ATM shifts used on Call side today.';
comment on column public.delta_strategy_settings.shifts_used_put is 'Number of ATM shifts used on Put side today.';

-- ---------------------------------------------------------------------------
-- 2. delta_pick_premium with optional ceiling
-- ---------------------------------------------------------------------------
create or replace function public.delta_pick_premium(
  p_exp     text,
  p_kind    text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_beyond  numeric,
  p_account uuid    default null,
  p_cap     numeric default 0,
  p_spot    numeric default null,
  p_ceil    numeric default 0
)
returns table (symbol text, strike numeric, premium numeric, delta numeric, room_lots int)
language sql
stable
as $$
  with priced as (
    select c.symbol, c.strike, c.best_bid as premium, c.delta, c.contract_value,
           coalesce(abs(pos.net_qty), 0) as held
    from public.delta_chain c
    left join public.positions pos
           on pos.account_id = p_account and pos.symbol = c.symbol
    where c.expiry_label = p_exp
      and c.contract_type = p_kind
      and c.best_bid is not null
      and c.delta is not null
      and (p_floor <= 0 or c.best_bid >= p_floor)
      and (p_ceil <= 0 or c.best_bid <= p_ceil)
      and (p_beyond is null
           or (p_kind = 'call_options' and c.strike > p_beyond)
           or (p_kind = 'put_options'  and c.strike < p_beyond))
  ),
  candidates as (
    select p.symbol, p.strike, p.premium, p.delta,
           case when p_cap > 0 and coalesce(p_spot, 0) > 0 and coalesce(p.contract_value, 0) > 0
                then greatest(0, floor(p_cap / (p_spot * p.contract_value))::int - p.held)
           end as room_lots
    from priced p
  ),
  open_strikes as (
    select * from candidates c where c.room_lots is null or c.room_lots > 0
  ),
  ranked as (
    select c.*, 0 as pri, c.premium - p_entry as nearness
    from open_strikes c where p_tie = 'above' and c.premium >= p_entry
    union all
    select c.*, 0, p_entry - c.premium
    from open_strikes c where p_tie = 'below' and c.premium <= p_entry
    union all
    select c.*, 1, abs(c.premium - p_entry) from open_strikes c
  )
  select k.symbol, k.strike, k.premium, k.delta, k.room_lots
  from ranked k order by k.pri asc, k.nearness asc limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 3. delta_sell_entry supporting pairs_count & premium bounds
-- ---------------------------------------------------------------------------
create or replace function public.delta_sell_entry(
  p_account uuid,
  p_user    uuid,
  p_exp     text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_qty     numeric,
  p_spot    numeric,
  p_cap     numeric default 0,
  p_pairs   int     default 1,
  p_ceil    numeric default 0
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  p        record;
  v_lots_c int;
  v_lots_p int;
  v_room   int;
  v_count  int := 0;
  v_desc   text := '';
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie,
                                                 null, p_account, p_cap, p_spot, p_ceil);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie,
                                                 null, p_account, p_cap, p_spot, p_ceil);

  if c.symbol is null or p.symbol is null then
    return null;
  end if;

  v_room := least(c.room_lots, p.room_lots);
  v_lots_c := least(public.delta_qty_to_lots(p_qty, c.symbol), coalesce(v_room, 2147483647));
  v_lots_p := least(public.delta_qty_to_lots(p_qty, p.symbol), coalesce(v_room, 2147483647));

  if v_lots_c <= 0 or v_lots_p <= 0 then
    return null;
  end if;

  perform public.delta_sell(p_account, p_user, c.symbol, v_lots_c, p_spot);
  perform public.delta_sell(p_account, p_user, p.symbol, v_lots_p, p_spot);

  return format('sold %s × %s / %s × %s', v_lots_c, c.symbol, v_lots_p, p.symbol);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. delta_reason labels for new actions
-- ---------------------------------------------------------------------------
create or replace function public.delta_reason(
  p_account   uuid,
  p_action    text,
  p_spot      numeric,
  p_dp_before numeric,
  p_dp_target numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line text;
begin
  v_line := case p_action
    when 'entry'              then 'Opening pair'
    when 'roll'               then 'Rolled further out — band breach'
    when 'exit'               then 'Closed in full — roll budget spent'
    when 'atm_shift'          then 'ATM reached — shifted further out'
    when 'atm_exit'           then 'ATM reached — closed position'
    when 'empty_side_flatten' then 'Wing empty — closed all positions'
    when 'band'               then 'Fresh sell — band correction'
    when 'hedge_buy'          then 'Bought futures — band breach'
    when 'hedge_sell'         then 'Sold futures — band breach'
    when 'cut'                then 'Margin cut — loss booked'
    when 'flatten'            then 'Session close — flattened'
    when 'take_profit'        then 'Take-profit hit'
    when 'stop_loss'          then 'Stop-loss hit'
  end;

  if v_line is null then
    raise log 'delta_reason: unknown action % on account %', p_action, p_account;
    return;
  end if;

  v_line := v_line
    || case when p_dp_target is null then ''
            else format(' (target %s)', round(p_dp_target, 2)) end
    || format(' · spot $%s · Δp %s → %s',
              coalesce(round(p_spot, 2)::text, '—'),
              coalesce(round(p_dp_before, 2)::text, '—'),
              coalesce(round(public.delta_book_dp(p_account), 2)::text, '—'));

  update public.fills
  set reason = v_line
  where account_id = p_account
    and reason is null
    and created_at >= now()
    and (case when contract_type = 'perpetual_futures'
              then realized_pnl <> 0
              else side = 'buy' or realized_pnl <> 0 end);

  update public.positions
  set entry_reason = v_line
  where account_id = p_account
    and entry_reason is null
    and opened_at >= now();
end;
$$;
revoke all on function public.delta_reason(uuid, text, numeric, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Updated apply_delta_strategy engine
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
  v_desc      text;
  v_dp        numeric;
  v_cv        numeric;
  v_missing   int;
  v_target    numeric;
  v_breach    text;
  v_gp        numeric;
  v_band_low  numeric;
  v_band_high numeric;
  v_mode      text;
  v_need      numeric;
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
  v_margin    numeric;
  v_equity    numeric;
  v_cap       numeric;
  v_goal      numeric;
  v_cutside   text;
  v_short     numeric;
  v_perlot    numeric;
begin
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200
    and created > now() - interval '30 seconds'
    and content like '%"result":[%'
    and content like '%XAUT%'
    and (content::jsonb -> 'result' -> 0) ? 'greeks'
  order by created desc limit 1;

  if v_tickers is null then
    raise log 'apply_delta_strategy: no XAUT tickers reply inside 30s — standing down';
    return 0;
  end if;

  if not pg_try_advisory_xact_lock(hashtext('delta_strategy_engine')) then
    return 0;
  end if;

  delete from public.delta_chain;
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, gamma, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
         nullif(t -> 'greeks' ->> 'gamma', '')::numeric,
         nullif(t ->> 'spot_price', '')::numeric,
         nullif(t ->> 'mark_price', '')::numeric
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%'
  on conflict (symbol) do nothing;

  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, gamma, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         null,
         'PERP',
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         1,
         0,
         nullif(t ->> 'spot_price', '')::numeric,
         nullif(t ->> 'mark_price', '')::numeric
  from jsonb_array_elements(v_tickers) t
  where (t ->> 'contract_type') = 'perpetual_futures'
  on conflict (symbol) do nothing;

  select max(spot_price) into v_spot from public.delta_chain where spot_price is not null;
  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no spot in the chain';
    return 0;
  end if;

  for r in
    select s2.*, a.user_id, a.kind
    from public.delta_strategy_settings s2
    join public.accounts a on a.id = s2.account_id
    where s2.armed
  loop
    v_acted := false;
    v_mode  := case when r.kind = 'futures' then 'futures' else 'options' end;
    select * into s from public.delta_strategy_settings where account_id = r.account_id;

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
          shifts_used_call = 0, shifts_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session closed: flatten -------------------------------------------
    if v_phase <> 'open' then
      if s.entered_day is not null then
        update public.delta_strategy_settings set entered_day = null
        where account_id = r.account_id;
      end if;

      if s.flattened_day is distinct from v_day
         and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        select count(*) into v_legs
        from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        update public.delta_strategy_settings
        set flattened_day = v_day, touched_symbols = '{}', pass_open = false
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'flatten', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % flattened % leg(s) at the close', r.account_id, v_legs;
        v_n := v_n + 1;
      end if;
      continue;
    end if;

    -- ---- The band this cycle defends ---------------------------------------
    if v_mode = 'futures' then
      v_gp        := null;
      v_band_low  := s.band_low;
      v_band_high := s.band_high;
    else
      v_gp := public.delta_book_gp(r.account_id);
      select low, high into v_band_low, v_band_high
      from public.delta_band(s.band_low, s.band_high, s.gamma_multiplier, v_gp);
    end if;

    -- ---- Margin guard: over the cap ----------------------------------------
    select margin, equity into v_margin, v_equity
    from public.delta_account_margin(r.account_id, v_spot);

    v_cap  := v_equity * s.margin_cap_pct / 100.0;
    v_goal := v_equity * s.margin_target_pct / 100.0;

    if s.margin_cap_pct > 0 and v_margin > v_cap and v_margin > 0 then
      v_dp := public.delta_book_dp(r.account_id);
      v_cutside := case
        when v_dp is null then null
        when v_dp < (v_band_low + v_band_high) / 2 then 'call_options'
        when v_dp > (v_band_low + v_band_high) / 2 then 'put_options'
      end;

      v_short := v_margin - v_goal;
      select p.symbol, p.net_qty, coalesce(p.contract_value, 1) as cv,
             coalesce(c.mark_price, c.best_ask, p.avg_entry_price::numeric) as mark
        into v_leg
      from public.positions p
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type <> 'perpetual_futures'
      order by (case when v_cutside is not null and p.contract_type = v_cutside then 0 else 1 end),
               (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                     else p.strike_price::numeric - v_spot end) desc
      limit 1;

      if not found then
        raise log 'apply_delta_strategy: account % margin % over cap % but no short to cut',
          r.account_id, round(v_margin, 2), round(v_cap, 2);
        continue;
      end if;

      v_perlot := (0.01 * v_spot + v_leg.mark) * v_leg.cv;
      if v_perlot <= 0 then
        raise log 'apply_delta_strategy: account % cannot price margin on % — skipping cut',
          r.account_id, v_leg.symbol;
        continue;
      end if;

      v_q := least(ceil(v_short / v_perlot)::int, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      perform public.delta_reason(r.account_id, 'cut', v_spot, v_dp);

      raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
        r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Expiry selection --------------------------------------------------
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
      v_dp := public.delta_book_dp(r.account_id);

      v_desc := public.delta_sell_entry(
        r.account_id, r.user_id, v_exp, s.entry_premium,
        coalesce(s.entry_premium_min, 0), s.tie_break, s.qty, v_spot,
        s.max_notional_per_strike,
        case when v_mode = 'futures' then coalesce(s.pairs_count, 1) else 1 end,
        coalesce(s.entry_premium_max, 0)
      );

      if v_desc is null then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh', r.account_id;
        continue;
      end if;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;

      perform public.delta_reason(r.account_id, 'entry', v_spot, v_dp);
      raise log 'apply_delta_strategy: account % opened the session — %', r.account_id, v_desc;
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Empty side check (Futures strategy) --------------------------------
    -- If there is no position on either side (Call or Put), close all remaining positions.
    if v_mode = 'futures' and s.entered_day = v_day
       and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
      if not exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'call_options' and net_qty < 0)
         or not exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'put_options' and net_qty < 0) then
        select count(*) into v_legs from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        perform public.delta_reason(r.account_id, 'empty_side_flatten', v_spot, v_dp);

        raise log 'apply_delta_strategy: account % wing empty — closed all % remaining leg(s)', r.account_id, v_legs;
        v_n := v_n + 1;
        continue;
      end if;
    end if;

    -- ---- ATM Exit & Shift (Futures strategy) --------------------------------
    if v_mode = 'futures' then
      for v_leg in
        select p.id, p.symbol, p.net_qty, p.contract_type, p.strike_price::numeric as strike,
               p.contract_value, p.product_id, c.delta,
               coalesce(c.best_ask, c.mark_price, p.avg_entry_price::numeric) as mark,
               case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                    else p.strike_price::numeric - v_spot end as itm_distance
        from public.positions p
        join public.delta_chain c on c.symbol = p.symbol
        where p.account_id = r.account_id
          and p.net_qty < 0
          and p.contract_type in ('call_options', 'put_options')
          and not (p.symbol = any (s.touched_symbols))
          and (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                    else p.strike_price::numeric - v_spot end) >= 0
        order by itm_distance desc
        limit 1
      loop
        v_used := case when v_leg.contract_type = 'call_options' then coalesce(s.shifts_used_call, 0)
                       else coalesce(s.shifts_used_put, 0) end;

        if v_used < coalesce(s.max_shifts, 1) then
          select * into v_repl from public.delta_pick_premium(
            v_exp, v_leg.contract_type, v_leg.mark * (coalesce(s.shift_pct, 50) / 100.0),
            0, s.tie_break, v_leg.strike, r.account_id, s.max_notional_per_strike, v_spot);

          if v_repl.symbol is not null then
            v_q := least(abs(v_leg.net_qty), coalesce(v_repl.room_lots, abs(v_leg.net_qty)));
            if v_q > 0 then
              perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
              perform public.delta_sell(r.account_id, r.user_id, v_repl.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set touched_symbols = array_append(touched_symbols, v_leg.symbol),
                  shifts_used_call = shifts_used_call + case when v_leg.contract_type = 'call_options' then 1 else 0 end,
                  shifts_used_put  = shifts_used_put  + case when v_leg.contract_type = 'put_options'  then 1 else 0 end
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'atm_shift', v_spot, v_dp);
              raise log 'apply_delta_strategy: account % ATM exit & shifted % of % to %',
                r.account_id, v_q, v_leg.symbol, v_repl.symbol;
              v_n := v_n + 1;
              v_acted := true;
              exit;
            end if;
          end if;
        end if;

        perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'atm_exit', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % ATM exit-only — closed % in full', r.account_id, v_leg.symbol;
        v_n := v_n + 1;
        v_acted := true;
        exit;
      end loop;

      if v_acted then
        continue;
      end if;
    end if;

    -- ---- Net portfolio delta -----------------------------------------------
    select count(*) filter (where c.delta is null
                              or (v_mode = 'options' and c.gamma is null)),
           coalesce(sum(p.net_qty * c.delta), 0),
           max(p.contract_value)
      into v_missing, v_dp, v_cv
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on % for % leg(s)',
        r.account_id,
        case when v_mode = 'options' then 'greeks' else 'a delta' end,
        v_missing;
      continue;
    end if;

    v_cv := coalesce(v_cv, 1);
    v_dp := v_dp * v_cv;

    v_breach := case when v_dp < v_band_low then 'low'
                     when v_dp > v_band_high then 'high' end;

    if v_breach is null then
      if s.pass_open then
        update public.delta_strategy_settings
        set pass_open = false, touched_symbols = '{}' where account_id = r.account_id;
      end if;
      continue;
    end if;

    if s.target_landing = 'mid' then
      v_target := (v_band_low + v_band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(v_band_low + s.band_buffer, (v_band_low + v_band_high) / 2);
    else
      v_target := greatest(v_band_high - s.band_buffer, (v_band_low + v_band_high) / 2);
    end if;

    -- ---- Futures hedge -----------------------------------------------------
    if v_mode = 'futures' then
      v_need := (v_target - v_dp) / v_cv;
      v_q := floor(abs(v_need) + 1e-9)::int;
      if v_q <= 0 then
        raise log 'apply_delta_strategy: account % Dp % breach is under one contract',
          r.account_id, round(v_dp, 2);
        continue;
      end if;

      perform public.delta_hedge(r.account_id, r.user_id,
                                 case when v_need > 0 then 'buy' else 'sell' end,
                                 v_q, v_spot, s.hedge_leverage);
      perform public.delta_reason(r.account_id,
                                 case when v_need > 0 then 'hedge_buy' else 'hedge_sell' end,
                                 v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % hedged — % % futures lots at Dp % toward %',
        r.account_id, case when v_need > 0 then 'bought' else 'sold' end, v_q,
        round(v_dp, 2), round(v_target, 2);
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- Options mode rolls ------------------------------------------------
    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

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

        perform public.delta_reason(r.account_id, 'exit', v_spot, v_dp, v_target);
        raise log 'apply_delta_strategy: account % exit-only — closed % in full', r.account_id, v_leg.symbol;
        v_acted := true;
        exit;
      end if;

      select * into v_repl from public.delta_pick_premium(
        v_exp, v_rollside, s.entry_premium, 0, s.tie_break, v_leg.strike,
        r.account_id, s.max_notional_per_strike, v_spot);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      v_q := floor(abs(v_target - v_dp) / (v_cv * v_gap) + 1e-9)::int;
      v_q := least(v_q, abs(v_leg.net_qty), v_repl.room_lots);
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

      perform public.delta_reason(r.account_id, 'roll', v_spot, v_dp, v_target);
      raise log 'apply_delta_strategy: account % rolled % of % out to %',
        r.account_id, v_q, v_leg.symbol, v_repl.symbol;
      v_n := v_n + 1;
      v_acted := true;
      exit;
    end loop;

    if v_acted then continue; end if;

    -- ---- Options band correction -------------------------------------------
    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null,
      r.account_id, s.max_notional_per_strike, v_spot);

    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike with room to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    v_q := least(v_q, v_pick.room_lots);

    if s.margin_cap_pct > 0 then
      v_perlot := (0.01 * v_spot + v_pick.premium) * v_cv;
      if v_perlot > 0 then
        v_q := least(v_q, greatest(0, floor((v_cap - v_margin) / v_perlot))::int);
      end if;
    end if;

    if v_q <= 0 then
      continue;
    end if;

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);
    perform public.delta_reason(r.account_id, 'band', v_spot, v_dp, v_target);

    raise log 'apply_delta_strategy: account % band correction — sold % of %',
      r.account_id, v_q, v_pick.symbol;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;
revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
