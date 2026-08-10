-- ============================================================================
-- XAUT Options Paper Trading — the delta entry must actually fill to count
-- Run this whole file in the Supabase SQL Editor after 0018_auto_strategy_expiry_rule.sql.
--
-- Two faults in the S4 daily entry, both silent, and each making the other worse.
--
-- 1. The day was stamped whether or not anything was sold. delta_sell_entry
--    returns void and gives up quietly when no strike clears min_premium, when no
--    symmetric pair is listed, or when execute_fill throws on margin — and the
--    caller stamped entered_day regardless:
--
--        perform public.delta_sell_entry(...);
--        update ... set entered_day = v_day;     -- unconditional
--
--    So a thin book at the open cost the whole session: no entry, no retry, and an
--    empty book reports Δp = 0, which reads as "inside the band". The TypeScript
--    reference does the opposite — planCycle returns "No call strike at or above
--    the floor yet" and leaves the day unstamped so the next cycle tries again.
--
-- 2. The pair could half-fill. Symmetry was checked when *picking* the strikes,
--    but the two delta_sell calls were independent. Call fills, put throws, and the
--    account is left one-legged — a naked directional short, which is the one thing
--    a symmetric pair exists to avoid. Then fault 1 held it there all day.
--
-- The fix for both: delta_sell_entry returns the number of legs filled, and the two
-- sells sit inside a block whose implicit savepoint unwinds *both* if either fails
-- to fill. Rolling back beats selling the stray leg back out — a retry then starts
-- from flat, having paid no spread, and the cancelled orders leave no trace in the
-- ledger. The caller stamps entered_day only on a full pair, so a failed open is
-- retried on the next cycle rather than written off.
--
-- A book that is genuinely unsellable all session now retries every cycle. That
-- costs log lines and nothing else: nothing reaches a fill, so there is no churn.
--
-- Return type changes, so the function is dropped rather than replaced.
-- ============================================================================

drop function if exists public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric);

/**
 * S4: sell one symmetric call/put pair, N lots each, at the strikes nearest the
 * entry premium. Returns the legs filled — 2 on success, 0 if nothing was left
 * open, and never 1.
 */
create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_pairs int, p_spot numeric)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  p        record;
  v_before numeric;
  v_after  numeric;
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie, null);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie, null);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor', p_floor;
    return 0;
  end if;

  -- One block, one implicit savepoint. delta_sell swallows a failed fill and
  -- returns normally, so a leg that did not open is detected by the position not
  -- moving and turned into an exception here — which unwinds everything this block
  -- did, including the other leg's fill.
  begin
    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    perform public.delta_sell(p_account, p_user, c.symbol, p_pairs, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    -- Selling makes net_qty more negative, so a fill moves this the other way.
    if v_before - v_after <= 0 then
      raise exception 'call leg % did not fill', c.symbol;
    end if;

    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    perform public.delta_sell(p_account, p_user, p.symbol, p_pairs, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    if v_before - v_after <= 0 then
      raise exception 'put leg % did not fill', p.symbol;
    end if;
  exception when others then
    raise log 'delta_sell_entry: % — entry rolled back, nothing left open', sqlerrm;
    return 0;
  end;

  return 2;
end;
$$;

revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, int, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- apply_delta_strategy, recreated so the entry stamp waits on a filled pair.
-- Body is 0016's; only the S4 branch changes.
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
    -- The day is stamped only once a full pair is open. A failed open leaves it
    -- unstamped so the next cycle tries again — a thin book at the open used to
    -- cost the entire session.
    if s.entered_day is distinct from v_day then
      if s.pairs <= 0 then
        -- N is zero: there is no entry to place, and nothing to retry.
        update public.delta_strategy_settings set entered_day = v_day where account_id = r.account_id;
        continue;
      end if;

      v_legs := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        s.min_premium, s.tie_break, s.pairs, v_spot);
      if v_legs < 2 then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next cycle',
          r.account_id;
        continue;
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

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
