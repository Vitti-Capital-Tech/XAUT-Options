-- 0057_chain_is_xaut_only.sql
--
-- Run this whole file in the Supabase SQL Editor after 0056.
--
-- ===========================================================================
-- THIS ONE LIQUIDATED A BOOK. Read before running anything else.
-- ===========================================================================
--
-- A flatten went out reading
--
--     Wing empty — closed all positions · spot $78741.10 · Δp 9.11 → 0.00
--
-- Gold was 4,430 at the time — the XAUTUSD fill on the same row proves it.
-- 78,741 is Bitcoin. The engine had been handed a spot price for the wrong
-- asset, and every rule that reads spot then did exactly what it was told:
--
--   spot 78,741 against a 4,520 call  ->  spot - strike = +74,221
--   the ATM rule fires at itm_distance >= 0, so every call is "at the money"
--   -> the whole call side is closed
--   -> the empty-wing rule sees one side gone and flattens the book
--
-- Nothing malfunctioned after the bad number. The bad number was the fault.
--
-- Three changes in 0050 combined to produce it:
--
--   1. The response picker lost its `greeks` guard. net._http_response is one
--      shared table for every pg_net caller in this database — eight of them —
--      and the picker's remaining tests are only "200, recent, body contains
--      XAUT, body has a result array". A reply fetched for some other poller
--      satisfies all four. 0049 also required greeks on the first element,
--      which is what pinned it to an options reply.
--
--   2. The options insert lost its symbol test. 0049 took only C-XAUT-%/P-XAUT-%;
--      0050 takes every call and put in the reply, whatever the underlying.
--
--   3. The chain stopped being cleared. 0049 opened with `delete from
--      delta_chain`; 0050 upserts instead. So contamination is not transient —
--      one bad ingest leaves those rows in the chain permanently.
--
-- And spot was read as `max(spot_price)` over the whole table, unscoped, so a
-- single Bitcoin row wins the max and becomes spot for every account, forever.
--
-- Fixed here: the contaminated rows are deleted, all three guards are restored,
-- spot is derived from XAUT rows only, and it is then cross-checked against the
-- XAUTUSD mark — a disagreement over 20% stands the cycle down instead of
-- trading on it. delta_hedge is also pinned to XAUTUSD; it was picking the
-- perpetual with `limit 1` and no symbol test, so a second perpetual in the
-- chain was an order in the wrong instrument waiting to happen.
--
-- BEFORE YOU RUN THIS: pause the futures strategy from the tab. The engine is
-- still flattening on every cycle it gets, and this file cannot undo a fill.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Purge everything that is not XAUT
-- ---------------------------------------------------------------------------
-- The chain is unlogged, refreshed every few seconds and holds no history, so
-- deleting from it costs nothing — the next cycle repopulates what belongs.
delete from public.delta_chain
where symbol not like 'C-XAUT-%'
  and symbol not like 'P-XAUT-%'
  and symbol <> 'XAUTUSD';

-- ---------------------------------------------------------------------------
-- 2. delta_hedge: the XAUT perpetual, by name
-- ---------------------------------------------------------------------------
create or replace function public.delta_hedge(
  p_account  uuid,
  p_user     uuid,
  p_side     text,
  p_lots     int,
  p_spot     numeric,
  p_leverage numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c       record;
  v_order uuid;
  v_px    numeric;
  v_net   int;
begin
  -- 0057: by symbol, not `contract_type = 'perpetual_futures' limit 1`. That
  -- picked whichever perpetual the planner handed back first, which is fine only
  -- for as long as XAUTUSD is the only one in the table — exactly the assumption
  -- that failed everywhere else in this file.
  select * into c from public.delta_chain where symbol = 'XAUTUSD';
  if not found then
    insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                    contract_value, delta, gamma, spot_price, mark_price)
    values ('XAUTUSD', 'perpetual_futures', null, 'PERP', 0.001, 1, 0, p_spot, p_spot)
    on conflict (symbol) do nothing;
    select * into c from public.delta_chain where symbol = 'XAUTUSD';
  end if;

  v_px := case when p_side = 'buy'
               then coalesce(c.best_ask, c.mark_price, c.spot_price, p_spot)
               else coalesce(c.best_bid, c.mark_price, c.spot_price, p_spot) end;
  if v_px is null or v_px <= 0 then
    v_px := p_spot;
  end if;

  select coalesce(net_qty, 0) into v_net
  from public.positions where account_id = p_account and symbol = 'XAUTUSD';
  v_net := coalesce(v_net, 0);

  insert into public.orders (
    account_id, user_id, symbol, product_id, contract_type,
    strike_price, expiry_label, contract_value, side, order_type,
    qty, limit_price, reduce_only, leverage
  )
  values (
    p_account, p_user, 'XAUTUSD', c.product_id, 'perpetual_futures', null,
    'PERP', coalesce(c.contract_value, 0.001), p_side, 'market', p_lots, null,
    (p_side = 'buy'  and v_net < 0 and p_lots <= abs(v_net))
      or (p_side = 'sell' and v_net > 0 and p_lots <= v_net),
    p_leverage
  )
  returning id into v_order;

  begin
    perform public.execute_fill(v_order, p_lots, v_px, 0, p_spot);
  exception when others then
    raise log 'delta_hedge: fill failed on XAUTUSD — %', sqlerrm;
    update public.orders set status = 'cancelled', cancel_reason = 'delta strategy fill failed'
    where id = v_order;
  end;
end;
$$;
revoke all on function public.delta_hedge(uuid, uuid, text, int, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The engine
-- ---------------------------------------------------------------------------
-- 0056's engine with the three guards restored and spot scoped and checked.
-- Everything else is unchanged.
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
  v_rule      text;
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
  -- 0055: what the perpetual hedge would cost in margin, and what is left to
  -- pay it with. Kept apart from v_margin/v_goal, which the margin guard owns.
  v_free      numeric;
  v_hedge_im  numeric;
  v_perp      record;
  v_q2        int;
  -- 0056: which legs the chain could not price, for the log line.
  v_unpriced  text;
  -- 0057: the perpetual's own mark, to sanity-check spot against.
  v_perp_mark numeric;
  v_perlot    numeric;
  v_im_rate   numeric;
  v_adopted   boolean;

  -- Schedule windows variables
  v_win           jsonb;
  v_win_id        text;
  v_entry_prem    numeric;
  v_prem_min      numeric;
  v_prem_max      numeric;
  v_pairs         int;
  v_qty           numeric;
  v_notional_cap  numeric;
  v_tie_break     text;
  v_landing       text;
  v_buffer        numeric;
  v_leverage      numeric;
  v_shift_pct     numeric;
  v_max_shifts    int;
begin
  -- Fetch most recent 200 OK response containing XAUT tickers
  select (content::jsonb -> 'result') into v_tickers
  from net._http_response
  where status_code = 200
    and created > now() - interval '60 seconds'
    and content like '%"result":[%'
    and content like '%XAUT%'
    -- 0057: restored from 0049, dropped by 0050. net._http_response is shared by
    -- every pg_net caller in this database — eight of them — so "a 200 whose body
    -- mentions XAUT" also matches replies meant for the auto strategy, the trail
    -- poller and the futures maintenance poller. Requiring greeks on the first
    -- element is what makes this an options reply and nobody else's.
    and (content::jsonb -> 'result' -> 0) ? 'greeks'
  order by created desc limit 1;

  if v_tickers is null or jsonb_array_length(v_tickers) = 0 then
    raise log 'apply_delta_strategy: no recent ticker response';
    return 0;
  end if;

  -- Upsert options chain
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, product_id, best_bid, best_ask,
                                  delta, gamma, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         nullif(t ->> 'strike_price', '')::numeric,
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
  -- 0057: restored from 0049. Without the symbol test this takes every option
  -- of every underlying in the reply, and delta_chain is never cleared, so one
  -- bad ingest contaminates it permanently.
  where (t ->> 'contract_type') in ('call_options', 'put_options')
    and ((t ->> 'symbol') like 'C-XAUT-%' or (t ->> 'symbol') like 'P-XAUT-%')
  on conflict (symbol) do update set
    best_bid       = excluded.best_bid,
    best_ask       = excluded.best_ask,
    delta          = excluded.delta,
    gamma          = excluded.gamma,
    spot_price     = excluded.spot_price,
    mark_price     = excluded.mark_price,
    contract_value = excluded.contract_value,
    product_id     = coalesce(excluded.product_id, delta_chain.product_id),
    updated_at     = now();

  -- Upsert perpetual future (XAUTUSD)
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
  -- 0057: XAUTUSD only. delta_hedge picks the perpetual out of this table, so a
  -- second perpetual here is an order in the wrong instrument.
  where (t ->> 'contract_type') = 'perpetual_futures'
    and (t ->> 'symbol') = 'XAUTUSD'
  on conflict (symbol) do update set
    best_bid       = coalesce(excluded.best_bid, delta_chain.best_bid),
    best_ask       = coalesce(excluded.best_ask, delta_chain.best_ask),
    spot_price     = coalesce(excluded.spot_price, delta_chain.spot_price),
    mark_price     = coalesce(excluded.mark_price, delta_chain.mark_price),
    contract_value = coalesce(excluded.contract_value, delta_chain.contract_value),
    product_id     = coalesce(excluded.product_id, delta_chain.product_id),
    delta          = 1,
    gamma          = 0,
    updated_at     = now();

  -- 0057: scoped to XAUT. This was max(spot_price) over the whole table, so any
  -- non-XAUT row that ever reached the chain won the max and became "spot" for
  -- every account. A BTC row here puts spot near 78,000 against strikes near
  -- 4,400, which makes every call read as deep ITM: the ATM rule then closes the
  -- entire call side, the empty-wing rule sees one side gone and flattens the
  -- book. That is not a hedge going wrong, it is the book being liquidated by a
  -- bad number, so this is now derived narrowly and then checked.
  select max(spot_price) into v_spot
  from public.delta_chain
  where spot_price is not null
    and (symbol like 'C-XAUT-%' or symbol like 'P-XAUT-%' or symbol = 'XAUTUSD');

  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no XAUT spot in the chain';
    return 0;
  end if;

  -- The perpetual tracks the same underlying, so the two cannot disagree by much.
  -- Anything wider means the chain is carrying something that is not gold, and
  -- standing down beats trading on it — the whole book is priced off this number.
  select coalesce(mark_price, best_ask, best_bid) into v_perp_mark
  from public.delta_chain where symbol = 'XAUTUSD';

  if v_perp_mark is not null and v_perp_mark > 0
     and abs(v_spot - v_perp_mark) / v_perp_mark > 0.20 then
    raise log 'apply_delta_strategy: spot % disagrees with the XAUTUSD mark % by more than 20%% — standing down',
      round(v_spot, 2), round(v_perp_mark, 2);
    return 0;
  end if;

  for r in
    select s2.*, a.user_id, a.kind
    from public.delta_strategy_settings s2
    join public.accounts a on a.id = s2.account_id
    where s2.armed
  loop
    v_acted   := false;
    v_adopted := false;
    v_dp      := null;
    v_mode    := case when r.kind = 'futures' then 'futures' else 'options' end;
    select * into s from public.delta_strategy_settings where account_id = r.account_id;

    if s.last_cycle is not null
       and now() - s.last_cycle < make_interval(secs => s.cycle_seconds) then
      continue;
    end if;
    update public.delta_strategy_settings set last_cycle = now() where account_id = r.account_id;

    -- ---- Session / Windows Phase Resolution --------------------------------
    if v_mode = 'futures' and s.schedule_windows is not null and jsonb_array_length(s.schedule_windows) > 0 then
      select phase, sday, active_win into v_phase, v_day, v_win
      from public.delta_session_window(s.schedule_windows, s.trade_days);

      if v_win is not null then
        v_win_id       := coalesce(v_win ->> 'id', 'win_1');
        v_entry_prem   := coalesce(nullif(v_win ->> 'entryPremium', '')::numeric, s.entry_premium);
        v_prem_min     := coalesce(nullif(v_win ->> 'entryPremiumMin', '')::numeric, s.entry_premium_min, 0);
        v_prem_max     := coalesce(nullif(v_win ->> 'entryPremiumMax', '')::numeric, s.entry_premium_max, 0);
        v_pairs        := coalesce(nullif(v_win ->> 'pairsCount', '')::int, s.pairs_count, 1);
        v_qty          := coalesce(nullif(v_win ->> 'qty', '')::numeric, s.qty, 0.001);
        v_notional_cap := coalesce(nullif(v_win ->> 'maxNotionalPerStrike', '')::numeric, s.max_notional_per_strike, 95000);
        v_tie_break    := coalesce(v_win ->> 'tieBreak', s.tie_break, 'closest');
        v_band_low     := coalesce(nullif(v_win ->> 'bandLow', '')::numeric, s.band_low);
        v_band_high    := coalesce(nullif(v_win ->> 'bandHigh', '')::numeric, s.band_high);
        v_landing      := coalesce(v_win ->> 'targetLanding', s.target_landing, 'edge');
        v_buffer       := coalesce(nullif(v_win ->> 'bandBuffer', '')::numeric, s.band_buffer, 0.2);
        v_leverage     := coalesce(nullif(v_win ->> 'hedgeLeverage', '')::numeric, s.hedge_leverage, 100);
        v_shift_pct    := coalesce(nullif(v_win ->> 'shiftPct', '')::numeric, s.shift_pct, 50);
        v_max_shifts   := coalesce(nullif(v_win ->> 'maxShifts', '')::int, s.max_shifts, 1);
      else
        v_win_id       := null;
        v_entry_prem   := s.entry_premium;
        v_prem_min     := coalesce(s.entry_premium_min, 0);
        v_prem_max     := coalesce(s.entry_premium_max, 0);
        v_pairs        := coalesce(s.pairs_count, 1);
        v_qty          := s.qty;
        v_notional_cap := s.max_notional_per_strike;
        v_tie_break    := s.tie_break;
        v_band_low     := s.band_low;
        v_band_high    := s.band_high;
        v_landing      := s.target_landing;
        v_buffer       := s.band_buffer;
        v_leverage     := s.hedge_leverage;
        v_shift_pct    := coalesce(s.shift_pct, 50);
        v_max_shifts   := coalesce(s.max_shifts, 1);
      end if;
    else
      select phase, sday into v_phase, v_day
      from public.delta_session(s.session_open, s.session_close, s.trade_days);

      v_win_id       := 'default';
      v_entry_prem   := s.entry_premium;
      v_prem_min     := coalesce(s.entry_premium_min, 0);
      v_prem_max     := coalesce(s.entry_premium_max, 0);
      v_pairs        := coalesce(s.pairs_count, 1);
      v_qty          := s.qty;
      v_notional_cap := s.max_notional_per_strike;
      v_tie_break    := s.tie_break;
      v_band_low     := s.band_low;
      v_band_high    := s.band_high;
      v_landing      := s.target_landing;
      v_buffer       := s.band_buffer;
      v_leverage     := s.hedge_leverage;
      v_shift_pct    := coalesce(s.shift_pct, 50);
      v_max_shifts   := coalesce(s.max_shifts, 1);
    end if;

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          shifts_used_call = 0, shifts_used_put = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false,
          entered_window_ids = '{}'
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
        raise log 'apply_delta_strategy: account % flattened % leg(s) at window/session close', r.account_id, v_legs;
        v_n := v_n + 1;
      end if;
      continue;
    end if;

    -- ---- The band this cycle defends ---------------------------------------
    if v_mode = 'futures' then
      v_gp        := null;
    elsif s.gamma_multiplier > 0 then
      select sum(p.net_qty * c.gamma * coalesce(p.contract_value, 1)) into v_gp
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id and p.net_qty <> 0;

      if v_gp is not null then
        v_band_low  := -abs(v_gp) * s.gamma_multiplier;
        v_band_high :=  abs(v_gp) * s.gamma_multiplier;
      else
        v_band_low  := s.band_low;
        v_band_high := s.band_high;
      end if;
    else
      v_gp        := null;
      v_band_low  := s.band_low;
      v_band_high := s.band_high;
    end if;

    -- ---- Margin guard ------------------------------------------------------
    if s.margin_cap_pct > 0 and exists (
         select 1 from public.positions
         where account_id = r.account_id and net_qty <> 0 and contract_type <> 'perpetual_futures'
       ) then
      select sum(abs(p.net_qty) * (
                   (0.01 * coalesce(c.spot_price, v_spot) + coalesce(c.best_bid, c.mark_price, p.avg_entry_price::numeric))
                   * coalesce(p.contract_value, 1)
                 )),
             max(a.cash_balance) + coalesce(sum(p.realized_pnl), 0)
               + coalesce(sum(case when p.net_qty > 0
                                   then (coalesce(c.best_bid, c.mark_price, p.avg_entry_price::numeric) - p.avg_entry_price::numeric)
                                   else (p.avg_entry_price::numeric - coalesce(c.best_ask, c.mark_price, p.avg_entry_price::numeric))
                              end * abs(p.net_qty) * coalesce(p.contract_value, 1)), 0)
        into v_margin, v_equity
      from public.positions p
      join public.accounts a on a.id = p.account_id
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id and p.net_qty <> 0 and p.contract_type <> 'perpetual_futures';

      v_margin := coalesce(v_margin, 0);
      v_equity := coalesce(v_equity, 0);
      v_cap    := (s.margin_cap_pct / 100.0) * v_equity;
      v_goal   := (s.margin_target_pct / 100.0) * v_equity;

      if v_margin > v_cap and v_margin > 0 then
        v_dp := public.delta_book_dp(r.account_id);
        v_cutside := case when v_dp is null then null
                          when v_dp > v_band_high then 'put_options'
                          when v_dp < v_band_low  then 'call_options'
                          else null end;

        for v_leg in
          select p.id, p.symbol, p.net_qty, p.contract_type, p.strike_price::numeric as strike,
                 p.contract_value, p.product_id, c.delta,
                 coalesce(c.best_ask, c.mark_price, p.avg_entry_price::numeric) as mark,
                 abs(p.strike_price::numeric - v_spot) as d_spot
          from public.positions p
          join public.delta_chain c on c.symbol = p.symbol
          where p.account_id = r.account_id
            and p.net_qty < 0
            and p.contract_type in ('call_options', 'put_options')
          order by (v_cutside is not null and p.contract_type = v_cutside) desc,
                   d_spot asc,
                   abs(p.net_qty) desc
          limit 1
        loop
          v_perlot := (0.01 * v_spot + v_leg.mark) * coalesce(v_leg.contract_value, 1);
          if v_perlot <= 0 then v_q := abs(v_leg.net_qty);
          else v_q := ceil((v_margin - v_goal) / v_perlot)::int;
               v_q := greatest(1, least(v_q, abs(v_leg.net_qty)));
          end if;

          perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
          perform public.delta_reason(r.account_id, 'cut', v_spot, v_dp);
          v_acted := true;
        end loop;

        if v_acted then
          raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
            r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
          v_n := v_n + 1;
          continue;
        end if;
      end if;
    end if;

    -- ---- Expiry selection --------------------------------------------------
    if s.expiry_label is not null and s.expiry_label not like 'rule:%' then
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label = s.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
      v_rule := coalesce(nullif(replace(s.expiry_label, 'rule:', ''), ''), s.expiry_rule, 'today');

      if v_rule = 'today' then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          and to_date(expiry_label, 'DDMMYY') = (now() at time zone 'UTC')::date
        group by expiry_label limit 1;

        if v_exp is null then
          select expiry_label into v_exp
          from public.delta_chain
          where expiry_label ~ '^\d{6}$'
            and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc limit 1;
        end if;

      elsif v_rule = 'tomorrow' then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          and to_date(expiry_label, 'DDMMYY') >= (now() at time zone 'UTC')::date + 1
        group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc limit 1;

      elsif v_rule = 'friday' then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          and to_date(expiry_label, 'DDMMYY') >= (now() at time zone 'UTC')::date
          and extract(isodow from to_date(expiry_label, 'DDMMYY')) = 5
        group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc limit 1;

        if v_exp is null then
          select expiry_label into v_exp
          from public.delta_chain
          where expiry_label ~ '^\d{6}$'
            and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc limit 1;
        end if;
      else
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
        group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc
        offset (case when s.expiry_pick = 'next' then 1 else 0 end)
        limit 1;
      end if;
    end if;

    if v_exp is null then
      raise log 'apply_delta_strategy: account % — expiry % unavailable, standing down',
        r.account_id, coalesce(s.expiry_label, s.expiry_rule, '(by rule)');
      continue;
    end if;

    -- ---- Adopt hand-opened books -------------------------------------------
    if s.entered_day is distinct from v_day
       and exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'call_options' and net_qty < 0)
       and exists (select 1 from public.positions where account_id = r.account_id and contract_type = 'put_options' and net_qty < 0) then
      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;
      s.entered_day := v_day;
      v_adopted := true;
      raise log 'apply_delta_strategy: account % adopted existing short book for session %',
        r.account_id, v_day;
    end if;

    -- ---- Window / Daily Entry -----------------------------------------------
    if (v_win_id is not null and not (v_win_id = any(s.entered_window_ids)))
       or (s.entered_day is distinct from v_day) then
      v_dp := public.delta_book_dp(r.account_id);

      v_desc := public.delta_sell_entry(
        r.account_id, r.user_id, v_exp, v_entry_prem,
        v_prem_min, v_tie_break, v_qty, v_spot,
        v_notional_cap,
        case when v_mode = 'futures' then v_pairs else 1 end,
        v_prem_max
      );

      if v_desc is not null then
        update public.delta_strategy_settings
        set entered_day = v_day,
            flattened_day = null,
            entered_window_ids = case when v_win_id is not null
                                      then array_append(entered_window_ids, v_win_id)
                                      else entered_window_ids end
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'entry', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % opened window % — %', r.account_id, coalesce(v_win_id, 'default'), v_desc;
        v_n := v_n + 1;
        continue;
      else
        raise log 'apply_delta_strategy: account % entry did not fill, continuing cycle', r.account_id;
      end if;
    end if;

    -- ---- Empty side check (Futures strategy) --------------------------------
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
        v_rollside := case when v_leg.contract_type = 'call_options' then 'call' else 'put' end;
        v_used := case when v_rollside = 'call' then coalesce(s.shifts_used_call, 0)
                       else coalesce(s.shifts_used_put, 0) end;

        v_dp := public.delta_book_dp(r.account_id);

        if v_used < v_max_shifts then
          select * into v_pick from public.delta_pick_premium(
            v_exp, v_leg.contract_type,
            v_leg.mark * (v_shift_pct / 100.0),
            0, v_tie_break, v_leg.strike, r.account_id, v_notional_cap, v_spot, 0
          );

          if v_pick.symbol is not null then
            v_q := least(abs(v_leg.net_qty), coalesce(v_pick.room_lots, abs(v_leg.net_qty)));
            if v_q > 0 then
              perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
              perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set shifts_used_call = case when v_rollside = 'call' then shifts_used_call + 1 else shifts_used_call end,
                  shifts_used_put  = case when v_rollside = 'put'  then shifts_used_put  + 1 else shifts_used_put  end,
                  touched_symbols = array_append(touched_symbols, v_leg.symbol)
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'shift', v_spot, v_dp, v_pick.strike);
              raise log 'apply_delta_strategy: account % ATM exit on % shifted to %',
                r.account_id, v_leg.symbol, v_pick.symbol;
              v_acted := true;
              v_n := v_n + 1;
            end if;
          end if;
        end if;

        if not v_acted then
          perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, abs(v_leg.net_qty), v_spot);
          update public.delta_strategy_settings
          set touched_symbols = array_append(touched_symbols, v_leg.symbol)
          where account_id = r.account_id;

          perform public.delta_reason(r.account_id, 'atm_exit', v_spot, v_dp);
          raise log 'apply_delta_strategy: account % ATM exit on % closed in full',
            r.account_id, v_leg.symbol;
          v_acted := true;
          v_n := v_n + 1;
        end if;
      end loop;

      if v_acted then
        continue;
      end if;
    end if;

    -- ---- Net portfolio delta -----------------------------------------------
    -- 0056: the perpetual is never "missing a delta". It is 1 by definition, and
    -- the sum below has said so since 0050 — but the count did not, so a leg the
    -- chain could not price made the hedge itself look unpriceable. v_missing went
    -- to 1 and the cycle `continue`d here, before the breach check and before the
    -- hedge, every cycle, for as long as the book held that leg. Delta management
    -- switching itself off silently while every other part of the strategy — the
    -- entry, the ATM shift, the close-flatten — carried on working normally.
    --
    -- An option leg with no delta still stops the cycle, and should: Δp would be
    -- wrong, and a hedge sized off a wrong Δp is worse than no hedge at all. But
    -- it now names the symbols. "waiting on a delta for 1 leg(s)" is not enough to
    -- find an expired strike the chain has stopped quoting, which is the usual
    -- reason this fires.
    select count(*) filter (where p.contract_type <> 'perpetual_futures'
                              and (c.delta is null
                                   or (v_mode = 'options' and c.gamma is null))),
           string_agg(p.symbol, ', ') filter (
             where p.contract_type <> 'perpetual_futures'
               and (c.delta is null
                    or (v_mode = 'options' and c.gamma is null))),
           coalesce(sum(p.net_qty * coalesce(c.delta, case when p.contract_type = 'perpetual_futures' then 1 else null end)), 0),
           max(p.contract_value)
      into v_missing, v_unpriced, v_dp, v_cv
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on % for % leg(s): %',
        r.account_id,
        case when v_mode = 'options' then 'greeks' else 'a delta' end,
        v_missing, coalesce(v_unpriced, '?');
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

    if v_landing = 'mid' then
      v_target := (v_band_low + v_band_high) / 2;
    elsif v_breach = 'low' then
      v_target := least(v_band_low + v_buffer, (v_band_low + v_band_high) / 2);
    else
      v_target := greatest(v_band_high - v_buffer, (v_band_low + v_band_high) / 2);
    end if;

    -- ---- Futures delta management ------------------------------------------
    -- Two tiers, in this order:
    --
    --   1. Hedge in the perpetual, while there is margin to carry it. This is
    --      the cheap correction: it moves Δp without touching the option book
    --      and books no loss.
    --   2. Out of margin, exit the leg that is pushing Δp out of the band, in
    --      full, and book the loss. There is nothing else left to do — the band
    --      is what the book is for, and a breach we cannot hedge is a breach we
    --      have to close our way out of.
    if v_mode = 'futures' then
      v_need := (v_target - v_dp) / v_cv;
      v_q := floor(abs(v_need) + 1e-9)::int;
      if v_q <= 0 then
        raise log 'apply_delta_strategy: account % Dp % breach is under one contract',
          r.account_id, round(v_dp, 2);
        continue;
      end if;

      -- What the hedge would block, and what is free to block. delta_account_margin
      -- prices the perpetual at mark × cv × lots / leverage and the option shorts at
      -- the venue's own rule, so this is the same number the margin guard measures.
      select margin, equity into v_margin, v_equity
      from public.delta_account_margin(r.account_id, v_spot);
      v_margin := coalesce(v_margin, 0);
      v_equity := coalesce(v_equity, 0);

      select coalesce(c.mark_price, c.best_ask, c.best_bid, c.spot_price, v_spot) as mark,
             coalesce(c.contract_value, 0.001) as cv
        into v_perp
      from public.delta_chain c
      where c.contract_type = 'perpetual_futures'
      limit 1;

      v_hedge_im := v_q * coalesce(v_perp.mark, v_spot) * coalesce(v_perp.cv, 0.001)
                    / greatest(coalesce(v_leverage, 100), 1);

      -- Free margin, and never past the cap when one is set — otherwise the hedge
      -- would open a position the margin guard turns round and cuts next cycle.
      v_free := v_equity - v_margin;
      if s.margin_cap_pct > 0 then
        v_free := least(v_free, (s.margin_cap_pct / 100.0) * v_equity - v_margin);
      end if;

      -- Reducing an existing perpetual gives margin back rather than taking it, so
      -- it is always affordable. Only a hedge that grows the position has to pay.
      select coalesce(net_qty, 0) into v_q2
      from public.positions
      where account_id = r.account_id and contract_type = 'perpetual_futures' and net_qty <> 0
      limit 1;
      v_q2 := coalesce(v_q2, 0);

      if (v_need > 0 and v_q2 < 0) or (v_need < 0 and v_q2 > 0)
         or v_free >= v_hedge_im then
        perform public.delta_hedge(
          r.account_id,
          r.user_id,
          case when v_need > 0 then 'buy' else 'sell' end,
          v_q,
          v_spot,
          v_leverage
        );

        perform public.delta_reason(r.account_id, 'futures_hedge', v_spot, v_dp, v_target);

        raise log 'apply_delta_strategy: account % hedged — % % futures lot(s) (target %)',
          r.account_id,
          case when v_need > 0 then 'bought' else 'sold' end,
          v_q, round(v_target, 2);
        v_n := v_n + 1;
        continue;
      end if;

      -- ---- Out of margin: close the leg that is causing the breach ----------
      -- "Causing" is measured, not guessed: each leg's signed delta contribution
      -- is net_qty × delta, and the one to close is the largest contribution
      -- pointing the same way as the breach. On a Δp above the band that is the
      -- short put (net_qty < 0, delta < 0, so the product is positive); below the
      -- band it is the short call. Ordering by the contribution rather than by
      -- moneyness gets that right without special-casing either side.
      select p.symbol, p.net_qty, p.contract_type,
             p.net_qty * c.delta as contribution
        into v_leg
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type in ('call_options', 'put_options')
        and c.delta is not null
      order by case when v_breach = 'high' then p.net_qty * c.delta
                    else -(p.net_qty * c.delta) end desc
      limit 1;

      if not found then
        raise log 'apply_delta_strategy: account % cannot afford a % lot hedge (needs %, free %) and has no option leg to close',
          r.account_id, v_q, round(v_hedge_im, 2), round(v_free, 2);
        continue;
      end if;

      -- In full, as configured: the whole leg goes, not a slice of it.
      perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol,
                                    abs(v_leg.net_qty), v_spot);
      perform public.delta_reason(r.account_id, 'delta_exit', v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % out of margin for a % lot hedge (needs %, free %) — closed % (%) in full, contribution %',
        r.account_id, v_q, round(v_hedge_im, 2), round(v_free, 2),
        v_leg.symbol, v_leg.contract_type, round(v_leg.contribution, 4);
      v_n := v_n + 1;
      continue;
    end if;
    -- ---- Options roll / band correction ------------------------------------
    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_used     := case when v_rollside = 'call_options' then s.rolls_used_call
                       else s.rolls_used_put end;

    for v_leg in
      select p.id, p.symbol, p.net_qty, p.contract_type, p.strike_price::numeric as strike,
             p.contract_value, p.product_id, c.delta,
             coalesce(c.best_ask, c.mark_price, p.avg_entry_price::numeric) as mark,
             abs(c.delta) as abs_d
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.contract_type = v_rollside
        and p.net_qty < 0
        and not (p.symbol = any (s.touched_symbols))
        and (c.delta is not null and abs(c.delta) >= (s.itm_trigger / 100.0))
      order by abs_d desc
      limit 1
    loop
      if v_used < s.max_rolls then
        select * into v_repl from public.delta_pick_premium(
          v_exp, v_rollside, s.entry_premium, coalesce(s.entry_premium_min, 0),
          s.tie_break, v_leg.strike, r.account_id, s.max_notional_per_strike, v_spot, 0
        );

        if v_repl.symbol is not null then
          v_gap := abs(v_leg.delta) - abs(v_repl.delta);
          if v_gap > 0 then
            v_q := ceil(abs(v_target - v_dp) / (v_cv * v_gap))::int;
            v_q := least(v_q, abs(v_leg.net_qty), coalesce(v_repl.room_lots, abs(v_leg.net_qty)));

            if v_q > 0 then
              perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
              perform public.delta_sell(r.account_id, r.user_id, v_repl.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set rolls_used_call = case when v_rollside = 'call_options' then rolls_used_call + 1 else rolls_used_call end,
                  rolls_used_put  = case when v_rollside = 'put_options'  then rolls_used_put  + 1 else rolls_used_put  end,
                  touched_symbols = array_append(touched_symbols, v_leg.symbol)
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'roll', v_spot, v_dp, v_target);
              raise log 'apply_delta_strategy: account % rolled % of % -> %',
                r.account_id, v_q, v_leg.symbol, v_repl.symbol;
              v_acted := true;
              v_n := v_n + 1;
            end if;
          end if;
        end if;
      end if;

      if not v_acted then
        v_gap := abs(v_leg.delta);
        if v_gap > 0 then
          v_q := ceil(abs(v_target - v_dp) / (v_cv * v_gap))::int;
          v_q := least(v_q, abs(v_leg.net_qty));

          if v_q > 0 then
            perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
            update public.delta_strategy_settings
            set touched_symbols = array_append(touched_symbols, v_leg.symbol)
            where account_id = r.account_id;

            perform public.delta_reason(r.account_id, 'exit', v_spot, v_dp, v_target);
            raise log 'apply_delta_strategy: account % exit % of % (limit reached)',
              r.account_id, v_q, v_leg.symbol;
            v_acted := true;
            v_n := v_n + 1;
          end if;
        end if;
      end if;
    end loop;

    if v_acted then
      continue;
    end if;

    -- ---- Fresh OTM sell correction -----------------------------------------
    v_sellside := case when v_breach = 'low' then 'put_options' else 'call_options' end;

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, coalesce(s.entry_premium_min, 0),
      s.tie_break, null, r.account_id, s.max_notional_per_strike, v_spot, 0
    );

    if v_pick.symbol is null or coalesce(v_pick.delta, 0) = 0 then
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

-- ---------------------------------------------------------------------------
-- 4. Sanity check
-- ---------------------------------------------------------------------------
do $$
declare
  v_dirt int;
begin
  select count(*) into v_dirt
  from public.delta_chain
  where symbol not like 'C-XAUT-%'
    and symbol not like 'P-XAUT-%'
    and symbol <> 'XAUTUSD';
  if v_dirt > 0 then
    raise exception 'delta_chain still holds % non-XAUT row(s)', v_dirt;
  end if;

  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'delta_chain'
                   and column_name = 'updated_at') then
    raise exception 'delta_chain.updated_at is missing — apply 0056 first';
  end if;

  raise log '0057: chain is XAUT-only, spot is scoped and cross-checked, hedge is pinned to XAUTUSD';
end;
$$;
