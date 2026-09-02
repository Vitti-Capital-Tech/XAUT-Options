-- 0062_windows_own_all_their_filters.sql
--
-- Run this whole file in the Supabase SQL Editor after 0061.
--
-- The last four settings a schedule window carries but the engine never read:
--
--     marginCapPct      the margin ceiling that triggers a cut
--     marginTargetPct   how far down the cut goes
--     takeProfitMark    the take-profit stamped on a leg at the sale
--     stopLossMark      the stop-loss stamped on a leg at the sale
--
-- All four were in the window's JSON, editable in the window editor, and
-- silently ignored — every one of them was read off the settings row instead.
--
-- It looked like it worked because the tab mirrors the *active* window's values
-- into those columns whenever there is only one window. That is a coincidence
-- that holds at one window and stops holding at two: edit a non-active window's
-- take-profit and nothing happened at all, in either place.
--
-- Two changes:
--
--   1. The engine reads marginCapPct / marginTargetPct off the active window,
--      into locals, exactly as it already does for the band, the premiums, the
--      pair count and the rest. Falls back to the columns when no window is open.
--
--   2. delta_sell resolves the marks through the active window itself. Resolved
--      inside the function rather than passed in, because that makes it true for
--      every sale path at once — the daily entry, the ATM shift replacement, the
--      roll replacement and the band correction all reach the venue through
--      delta_sell, and it is the moment of the sale that decides which window's
--      marks a leg should carry. No signature change, so no call site moves.
--
-- With this, every field the window editor shows is a field the engine honours.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. delta_sell: the marks come from the window that is open
-- ---------------------------------------------------------------------------
create or replace function public.delta_sell(p_account uuid, p_user uuid, p_symbol text,
                                             p_lots int, p_spot numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  v_order  uuid;
  v_tp     numeric;
  v_sl     numeric;
begin
  select * into c from public.delta_chain where symbol = p_symbol;
  if not found or c.best_bid is null or c.best_bid <= 0 then
    raise log 'delta_sell: % has no bid', p_symbol;
    return;
  end if;

  insert into public.orders (account_id, user_id, symbol, product_id, contract_type,
                             strike_price, expiry_label, contract_value, side, order_type,
                             qty, limit_price)
  values (p_account, p_user, c.symbol, c.product_id, c.contract_type, c.strike,
          c.expiry_label, c.contract_value, 'sell', 'market', p_lots, null)
  returning id into v_order;

  begin
    perform public.execute_fill(v_order, p_lots, c.best_bid, 0, p_spot);
  exception when others then
    raise log 'delta_sell: fill failed on % — %', p_symbol, sqlerrm;
    update public.orders set status = 'cancelled', cancel_reason = 'delta strategy fill failed'
    where id = v_order;
    return;
  end;

  -- 0062: the marks come from whichever schedule window is open right now, and
  -- fall back to the settings row when none is.
  --
  -- A window carries its own takeProfitMark and stopLossMark, and until now the
  -- engine read neither — every sale took the account-level pair, so a window
  -- with a different take-profit was accepting a number it never used. The tab
  -- hid it by mirroring the *active* window's marks into those columns, which
  -- works for one window and quietly stops working at two.
  --
  -- Resolved here rather than passed in, because that keeps it true for every
  -- sale path at once — the daily entry, the ATM shift replacement, the roll
  -- replacement and the band correction all reach the venue through this
  -- function. The window active at the moment of the sale is the one that
  -- should set the leg's exits, and this is the moment of the sale.
  select coalesce(nullif(w.active_win ->> 'takeProfitMark', '')::numeric, dss.take_profit_mark),
         coalesce(nullif(w.active_win ->> 'stopLossMark', '')::numeric, dss.stop_loss_mark)
    into v_tp, v_sl
  from public.delta_strategy_settings dss
  left join lateral public.delta_session_window(dss.schedule_windows, dss.trade_days) w on true
  where dss.account_id = p_account;

  -- Both levels are absolute, so adding to an existing short leaves them where they
  -- are rather than re-basing onto the new average entry.
  update public.positions
  set take_profit = case when coalesce(v_tp, 0) > 0 and avg_entry_price > v_tp then v_tp end,
      stop_loss   = case when coalesce(v_sl, 0) > 0 and avg_entry_price < v_sl then v_sl end,
      tpsl_trigger = 'mark'
  where account_id = p_account and symbol = p_symbol and net_qty < 0;
end;
$$;
revoke all on function public.delta_sell(uuid, uuid, text, int, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The engine: the margin cap comes from the window that is open
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
  v_rule      text;
  -- 0061: the active window's days-to-expiry choice, null when no window
  -- supplies one. 0 today, 1 tomorrow, 4 the coming Friday.
  v_dte       int;
  -- 0062: the margin cap and its cut-to depth, per window. Read into locals for
  -- the same reason the band and the premiums are: whichever window is open at
  -- the time is the one whose numbers apply.
  v_margin_cap numeric;
  v_margin_tgt numeric;
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
  -- 0059: the close size, kept apart from v_q so the log can still name the
  -- hedge that was refused alongside the close that replaced it.
  v_close_q   int;
  v_perp      record;
  v_q2        int;
  -- 0056: which legs the chain could not price, for the log line.
  v_unpriced  text;
  -- 0060: how old the row spot came from is. A correct-looking price that
  -- nobody has refreshed is the failure this whole migration is about.
  v_spot_age  interval;
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
  -- 0058: our own reply, matched by request id — no content sniffing at all.
  --
  -- net._http_response is one shared table for every pg_net caller in this
  -- database, and the delta engine used to find its reply by describing it:
  -- 200, recent, body contains XAUT, body has a result array, first element has
  -- greeks. queue_strategy_checks (0008) fetches
  --
  --     /v2/tickers?contract_types=call_options,put_options
  --
  -- with no underlying_asset_symbols filter — every option on the exchange, 1043
  -- of them, every minute on the minute. Its first element is an XAUT put, so it
  -- satisfies every one of those five tests. There is no content test that
  -- separates the two replies; only the request that asked for them does.
  --
  -- So queue_delta_checks now records the id net.http_get hands back, and this
  -- reads the reply to that id. A reply nobody here asked for cannot be picked,
  -- whatever is in it or who adds a poller next.
  -- 0060: aliased `resp`, not `r`. `r` is the account-loop record declared above,
  -- and plpgsql resolves a name against its own variables before the statement's
  -- table aliases — so `r.content` bound to the unassigned record and raised
  -- "record r is not assigned yet" on the engine's first statement, every cycle.
  -- apply_trail_stops has always aliased this table `resp` for the same reason.
  select (resp.content::jsonb -> 'result') into v_tickers
  from net._http_response resp
  join public.delta_ticker_requests req on req.id = resp.id
  where resp.status_code = 200
    and resp.created > now() - interval '60 seconds'
  order by resp.created desc limit 1;

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

  -- 0057: scoped to XAUT. This aggregated spot over the whole table, so any
  -- non-XAUT row that ever reached the chain won the max and became "spot" for
  -- every account. A BTC row here puts spot near 78,000 against strikes near
  -- 4,400, which makes every call read as deep ITM: the ATM rule then closes the
  -- entire call side, the empty-wing rule sees one side gone and flattens the
  -- book. That is not a hedge going wrong, it is the book being liquidated by a
  -- bad number, so this is now derived narrowly and then checked.
  -- 0060: drop anything this reply did not refresh.
  --
  -- The chain has not been pruned since 0050 swapped `delete + insert` for an
  -- upsert, so a strike the venue stops quoting keeps its last row for ever —
  -- with the bid, the delta and the spot_price it carried at that moment. Those
  -- rows then compete on equal terms with live ones.
  delete from public.delta_chain
  where updated_at < now() - interval '2 minutes';

  -- 0060: spot from the perpetual's own row, not max() over the table.
  --
  -- Taking the highest spot_price any row happens to hold means that, with no
  -- pruning that is the highest spot the chain has *ever* seen, not the current
  -- one. On 02 Sep it returned 4423.29 while XAUTUSD itself said 4295.55, and
  -- every rule downstream believed 4423: the entry sold 4320/4330/4340 calls at
  -- premiums quoted when they were out of the money, the ATM rule then measured
  -- them against 4423, found all three "in the money", and closed the whole call
  -- side within eighteen seconds of opening it.
  --
  -- The 20% guard added in 0057 does not see this — 4423 against 4295 is 3%.
  -- Scoping to XAUT was not enough either; a stale *XAUT* row is just as wrong as
  -- a foreign one. The fix is to stop aggregating: XAUTUSD is upserted from every
  -- reply, so its row is current by construction.
  select spot_price, now() - updated_at into v_spot, v_spot_age
  from public.delta_chain
  where symbol = 'XAUTUSD' and spot_price > 0;

  -- Only if the perpetual is missing from the reply: the most recently refreshed
  -- option row. Still a single row's own reading, never a max across rows.
  if v_spot is null or v_spot <= 0 then
    select spot_price, now() - updated_at into v_spot, v_spot_age
    from public.delta_chain
    where spot_price > 0
      and (symbol like 'C-XAUT-%' or symbol like 'P-XAUT-%')
    order by updated_at desc
    limit 1;
  end if;

  if v_spot is null or v_spot <= 0 then
    raise log 'apply_delta_strategy: no XAUT spot in the chain';
    return 0;
  end if;

  -- 0060: spot has to be *fresh*, not merely plausible.
  --
  -- 0057 guarded this by comparing spot against the XAUTUSD mark and standing
  -- down past 20%. That test is meaningless now: spot is read from the XAUTUSD
  -- row, so it compared a row against itself — same instrument, same reply, they
  -- cannot disagree. It read like a guard while checking nothing, which is worse
  -- than no guard at all.
  --
  -- Staleness was the actual failure both times. The number was never implausible
  -- — 4423 is a perfectly good gold price, it was just twenty minutes old. So the
  -- test is now age. The poller runs every five seconds; a spot older than a
  -- minute means the feed has stopped and there is nothing to trade on.
  if v_spot_age is null or v_spot_age > interval '60 seconds' then
    raise log 'apply_delta_strategy: spot % is % old — standing down',
      round(v_spot, 2), coalesce(v_spot_age::text, 'unknown');
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
        v_dte          := nullif(v_win ->> 'daysToExpiry', '')::int;
        v_margin_cap   := coalesce(nullif(v_win ->> 'marginCapPct', '')::numeric, s.margin_cap_pct);
        v_margin_tgt   := coalesce(nullif(v_win ->> 'marginTargetPct', '')::numeric, s.margin_target_pct);
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
        v_dte          := null;
        v_margin_cap   := s.margin_cap_pct;
        v_margin_tgt   := s.margin_target_pct;
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
      v_dte          := null;
      v_margin_cap   := s.margin_cap_pct;
      v_margin_tgt   := s.margin_target_pct;
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
    if v_margin_cap > 0 and exists (
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
      v_cap    := (v_margin_cap / 100.0) * v_equity;
      v_goal   := (v_margin_tgt / 100.0) * v_equity;

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
    -- 0061: the expiry belongs to the window, not the account.
    --
    -- A window that opens in the evening and one that opens at the session open
    -- are not usually selling the same contract, and one account-wide choice
    -- cannot express that. So an active window's `daysToExpiry` decides, and it
    -- outranks both `expiry_label` and `expiry_rule`:
    --
    --     0 → the expiry settling today
    --     1 → the nearest expiry settling tomorrow or later
    --     4 → the nearest Friday weekly, whatever day it is now
    --
    -- Four is a label with a number on it, not four days of arithmetic — on a
    -- Wednesday it still means Friday, not Sunday. Anything else falls through to
    -- the nearest live expiry rather than guessing.
    --
    -- The account columns remain the fallback, for a `delta` book and for a
    -- futures book whose schedule_windows is still empty.
    if v_dte is not null then
      v_rule := case v_dte when 0 then 'today'
                           when 1 then 'tomorrow'
                           when 4 then 'friday'
                           else 'nearest' end;
    elsif s.expiry_label is not null and s.expiry_label not like 'rule:%' then
      v_rule := 'fixed';
    else
      v_rule := coalesce(nullif(replace(s.expiry_label, 'rule:', ''), ''), s.expiry_rule, 'today');
    end if;

    if v_rule = 'fixed' then
      select expiry_label into v_exp
      from public.delta_chain
      where expiry_label = s.expiry_label
        and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
      group by expiry_label
      limit 1;
    else
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
      where c.symbol = 'XAUTUSD';

      v_hedge_im := v_q * coalesce(v_perp.mark, v_spot) * coalesce(v_perp.cv, 0.001)
                    / greatest(coalesce(v_leverage, 100), 1);

      -- Free margin, and never past the cap when one is set — otherwise the hedge
      -- would open a position the margin guard turns round and cuts next cycle.
      v_free := v_equity - v_margin;
      if v_margin_cap > 0 then
        v_free := least(v_free, (v_margin_cap / 100.0) * v_equity - v_margin);
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
      select p.symbol, p.net_qty, p.contract_type, c.delta,
             p.net_qty * c.delta as contribution
        into v_leg
      from public.positions p
      join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id
        and p.net_qty < 0
        and p.contract_type in ('call_options', 'put_options')
        and c.delta is not null
        and c.delta <> 0
      order by case when v_breach = 'high' then p.net_qty * c.delta
                    else -(p.net_qty * c.delta) end desc
      limit 1;

      if not found then
        raise log 'apply_delta_strategy: account % cannot afford a % lot hedge (needs %, free %) and has no option leg to close',
          r.account_id, v_q, round(v_hedge_im, 2), round(v_free, 2);
        continue;
      end if;

      -- 0059: only as many lots as the band actually needs, not the whole leg.
      --
      -- Buying back v_q lots of a short leg moves Δp by v_q × delta × cv, so the
      -- lots that land Δp on the target are
      --
      --     v_q = (target − Δp) ÷ (delta × cv)
      --
      -- and that is positive for the culprit leg by construction: on a breach
      -- above the band the target is below Δp and the leg driving it is the short
      -- put, whose delta is negative, so both sides of the division are negative.
      -- `ceil` rather than `floor` because this closes a breach — landing a
      -- fraction short of the target leaves the book still outside the band and
      -- pays another spread next cycle to finish the job.
      --
      -- The same arithmetic the hedge and the options band correction already use.
      -- Closing the whole leg was the earlier instruction; it overshot, booking
      -- more loss than the breach called for and often throwing Δp out the other
      -- side, which the empty-wing rule then reads as a missing side.
      v_close_q := ceil((v_target - v_dp) / (v_leg.delta * v_cv))::int;
      v_close_q := greatest(1, least(v_close_q, abs(v_leg.net_qty)));

      perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_close_q, v_spot);
      perform public.delta_reason(r.account_id, 'delta_exit', v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % out of margin for a % lot hedge (needs %, free %) — closed % of % lots on % (%), contribution %',
        r.account_id, v_q, round(v_hedge_im, 2), round(v_free, 2),
        v_close_q, abs(v_leg.net_qty), v_leg.symbol, v_leg.contract_type,
        round(v_leg.contribution, 4);
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

    if v_margin_cap > 0 then
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
-- Sanity check
-- ---------------------------------------------------------------------------
do $$
declare
  v_eng text;
  v_sell text;
  v_key  text;
begin
  select pr.prosrc into v_eng from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'apply_delta_strategy';
  select pr.prosrc into v_sell from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_sell';

  -- Every key the window editor writes must be read by one of the two. If a new
  -- control is added to a window and nothing reads it, this is where that shows.
  foreach v_key in array array[
    'entryPremium', 'entryPremiumMin', 'entryPremiumMax', 'pairsCount', 'qty',
    'maxNotionalPerStrike', 'tieBreak', 'bandLow', 'bandHigh', 'targetLanding',
    'bandBuffer', 'hedgeLeverage', 'shiftPct', 'maxShifts', 'daysToExpiry',
    'marginCapPct', 'marginTargetPct'
  ] loop
    if v_eng not like '%' || v_key || '%' then
      raise exception 'apply_delta_strategy does not read the window key %', v_key;
    end if;
  end loop;

  foreach v_key in array array['takeProfitMark', 'stopLossMark'] loop
    if v_sell not like '%' || v_key || '%' then
      raise exception 'delta_sell does not read the window key %', v_key;
    end if;
  end loop;

  -- The engine must no longer reach past the window for the margin cap.
  if v_eng ~ 'v_cap\s*:=\s*\(s\.margin_cap_pct' then
    raise exception 'apply_delta_strategy still takes the margin cap off the settings row';
  end if;

  -- Guards carried forward from 0059 and 0060.
  if v_eng ~* 'max\s*\(\s*spot_price\s*\)' then
    raise exception 'apply_delta_strategy still derives spot from max(spot_price)';
  end if;
  if v_eng ~* '(from|join)[[:space:]]+[a-z_."]+[[:space:]]+(as[[:space:]]+)?(r|s)\M' then
    raise exception 'apply_delta_strategy aliases a table "r" or "s"';
  end if;

  raise log '0062: every window key the editor writes is read by the engine or delta_sell';
end;
$$;
