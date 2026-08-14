-- 0036_drop_delta_remarks.sql
--
-- Run this whole file in the Supabase SQL Editor after 0035_reason_on_the_row.sql.
--
-- `delta_remarks` goes. Once the reason is stamped on the fill and on the
-- position, the table is a second copy of the same answer kept in a place nobody
-- looks — a whole table, an RLS policy, a realtime publication, a client hook, a
-- retention sweep and a dedupe rule, to say what two text columns now say beside
-- the trade itself.
--
-- What it held that the columns do not is the decisions that traded nothing: an
-- entry held back by margin, a Δp that could not be trusted, an unlisted expiry.
-- Those are not lost either, and never needed a table:
--
--   * the strategy bar's `Next` line already says the live one, computed from the
--     same rules by `planCycle` in src/lib/deltaStrategy.ts — and says it for a
--     paused strategy too, which the log could not,
--   * every one of those branches still writes its `raise log`, which is what an
--     operator greps when the engine itself is the suspect.
--
-- The only thing genuinely dropped is the *history* of states that produced no
-- trade. That is a fair trade for the machinery it cost.
--
-- ---------------------------------------------------------------------------
-- What replaces it
-- ---------------------------------------------------------------------------
-- `delta_reason`, which does the one job that survived: compose the line and
-- stamp it onto the rows this action just wrote. Same line as 0035 —
--
--     Rolled further out — band breach (target -0.60) · spot $4243.10 · Δp -1.35 → -0.62
--
-- — and the same matching rule: `now()` does not advance inside a transaction, so
-- rows carrying it as their default timestamp are exactly the ones this cycle
-- wrote, and `reason is null` keeps a stamp from ever being rewritten.
--
-- It takes five arguments where `delta_remark` took ten. The long-form sentence,
-- the leg, the lot count, the band and the dedupe flag all existed for the log:
-- the leg and the lots are columns on the row being stamped, the band is on the
-- settings row, and nothing is deduplicated because nothing repeats — only
-- branches that trade write anything now.

-- ---------------------------------------------------------------------------
-- 1. The writer
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
    when 'entry'       then 'Opening pair'
    when 'roll'        then 'Rolled further out — band breach'
    when 'exit'        then 'Closed in full — roll budget spent'
    when 'band'        then 'Fresh sell — band correction'
    when 'cut'         then 'Margin cut — loss booked'
    when 'flatten'     then 'Session close — flattened'
    when 'take_profit' then 'Take-profit hit'
    when 'stop_loss'   then 'Stop-loss hit'
  end;

  -- An action nobody named cannot be described, and guessing at one would put a
  -- misleading sentence on a real trade.
  if v_line is null then
    raise log 'delta_reason: unknown action % on account %', p_action, p_account;
    return;
  end if;

  v_line := v_line
    -- Only where there is one: a cut, a flatten and a bracket answer to margin or
    -- to the option's own price, and have no delta they are aiming for.
    || case when p_dp_target is null then ''
            else format(' (target %s)', round(p_dp_target, 2)) end
    || format(' · spot $%s · Δp %s → %s',
              coalesce(round(p_spot, 2)::text, '—'),
              coalesce(round(p_dp_before, 2)::text, '—'),
              -- Read here, after the action: this is what it actually made.
              coalesce(round(public.delta_book_dp(p_account), 2)::text, '—'));

  -- The exits. `side = 'buy'` is the sell-only book's own definition of a close;
  -- the realized test picks up the one case it misses, a hand-opened long that
  -- the flatten exits by selling.
  update public.fills
  set reason = v_line
  where account_id = p_account
    and reason is null
    and created_at >= now()
    and (side = 'buy' or realized_pnl <> 0);

  -- The entries. Only rows this action created — `opened_at` does not move when
  -- an existing leg is added to, so a leg that was added to keeps the reason it
  -- was opened for, which is still why it is on the book.
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
-- 2. The engine, calling it
-- ---------------------------------------------------------------------------
-- Same decisions as 0031 through 0035. The difference is where the reasoning
-- goes: the six branches that trade call `delta_reason` after the trade, and the
-- branches that decline to act are back to a `raise log` alone — they write no
-- row, so there is nothing to stamp and nothing to say it on.
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
  -- Margin guard, per account.
  v_margin    numeric;
  v_equity    numeric;
  v_cap       numeric;
  v_goal      numeric;
  v_hold      boolean;
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
                                  delta, spot_price, mark_price)
  select (t ->> 'symbol'),
         (t ->> 'contract_type'),
         (t ->> 'strike_price')::numeric,
         split_part((t ->> 'symbol'), '-', 4),
         nullif(t ->> 'contract_value', '')::numeric,
         (t ->> 'product_id')::bigint,
         nullif(t -> 'quotes' ->> 'best_bid', '')::numeric,
         nullif(t -> 'quotes' ->> 'best_ask', '')::numeric,
         nullif(t -> 'greeks' ->> 'delta', '')::numeric,
         nullif(t ->> 'spot_price', '')::numeric,
         nullif(t ->> 'mark_price', '')::numeric
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

    -- ---- Session closed: no entry stands for today, and flatten if anything is open
    --
    -- entered_day is cleared unconditionally, not just when a flatten fires. While
    -- the session is shut there is no entry for today by definition, and tying the
    -- clearing to "had a book to flatten" is what left an already-flat account
    -- refusing to enter when its session reopened.
    --
    -- The flatten sits ahead of the expiry check on purpose: a stale expiry must
    -- never strand an open book. Flattening reads the positions, not the setting.
    --
    -- It also sits ahead of the margin guard, and has to: the close flattens
    -- everything, which is a strictly stronger cut than the guard would make.
    if v_phase <> 'open' then
      if s.entered_day is not null then
        update public.delta_strategy_settings set entered_day = null
        where account_id = r.account_id;
      end if;

      if s.flattened_day is distinct from v_day
         and exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        -- Read before the flatten: afterwards the book is empty and Δp is 0 by
        -- construction, which says nothing about what was being carried.
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

    -- ---- Margin: where this account stands before it is allowed to sell ----
    select margin, equity into v_margin, v_equity
    from public.delta_account_margin(r.account_id, v_spot);

    v_cap  := v_equity * s.margin_cap_pct / 100.0;
    v_goal := v_equity * s.margin_target_pct / 100.0;
    -- Wiped equity lands here too: at or below zero every threshold is at or
    -- below zero, so any open short is over it and the cut branch takes over.
    v_hold := s.margin_cap_pct > 0 and v_margin > v_goal;

    -- ---- Margin cut: over the cap, so nothing else runs this cycle ---------
    --
    -- Ahead of the expiry check deliberately. delta_close_leg reads the leg's own
    -- row in the chain, not the expiry the strategy trades, so a cut does not need
    -- a contract to be tradeable — and an unlisted or settled expiry standing the
    -- strategy down while the book is past its equity is precisely the failure
    -- this control exists to prevent. Only the session-close flatten outranks it,
    -- and that is a strictly larger cut.
    -- `v_margin > 0` is not redundant with the cap test: on a wiped account every
    -- threshold is negative, so a flat book would enter this branch, find nothing
    -- to cut and log it every couple of seconds. Nothing with zero blocked margin
    -- has anything to cut, so testing it costs no real case.
    if s.margin_cap_pct > 0 and v_margin > v_cap and v_margin > 0 then
      -- Δp only decides which side to prefer, so it is best-effort: one leg
      -- without a published greek makes the whole sum meaningless, and that
      -- leaves the walk ordering on ITM distance alone rather than standing down.
      v_dp := public.delta_book_dp(r.account_id);

      v_cutside := case when v_dp is null then null
                        when v_dp < s.band_low then 'call_options'
                        when v_dp > s.band_high then 'put_options' end;

      -- How much margin has to come off to reach the target, and the first leg
      -- to take it off. Ordered by side preference, then by how deep in the
      -- money it is.
      v_short := v_margin - v_goal;

      select p.symbol, p.net_qty, coalesce(p.contract_value, 1) as cv,
             coalesce(c.mark_price, c.best_ask, p.avg_entry_price::numeric) as mark
        into v_leg
      from public.positions p
      left join public.delta_chain c on c.symbol = p.symbol
      where p.account_id = r.account_id and p.net_qty < 0
      order by (case when v_cutside is not null and p.contract_type = v_cutside then 0 else 1 end),
               (case when p.contract_type = 'call_options' then v_spot - p.strike_price::numeric
                     else p.strike_price::numeric - v_spot end) desc
      limit 1;

      -- No short to cut: the margin is all long premium, which is already capped
      -- at what was paid and cannot be reduced by closing at a loss.
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

      -- Rounded up, unlike every other size here: a roll rounds down so a
      -- correction cannot overshoot the band, but a cut landing a hair above the
      -- target has resolved nothing and would just fire again. Capped at the leg,
      -- so the rest falls to the next cycle and the next leg — which is what keeps
      -- the booked loss to the smallest one that clears the breach.
      v_q := least(ceil(v_short / v_perlot)::int, abs(v_leg.net_qty));
      if v_q <= 0 then continue; end if;

      perform public.delta_close_leg(r.account_id, r.user_id, v_leg.symbol, v_q, v_spot);
      -- No target: a cut answers to equity, not to the band.
      perform public.delta_reason(r.account_id, 'cut', v_spot, v_dp);

      raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
        r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
      v_n := v_n + 1;
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
      -- Held back in the hold zone: an entry is two fresh shorts, which is the
      -- last thing an account already near its cap should add. entered_day is
      -- left unset, so the entry is retried as soon as margin allows.
      if v_hold then
        raise log 'apply_delta_strategy: account % entry held — margin % over target % of equity %',
          r.account_id, round(v_margin, 2), round(v_goal, 2), round(v_equity, 2);
        continue;
      end if;

      -- Read before the sale, so the reason on the two new legs says what the
      -- book was before they joined it.
      v_dp := public.delta_book_dp(r.account_id);

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_desc := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot);
      if v_desc is null then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
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

    -- ---- Net portfolio delta ----------------------------------------------
    select count(*) filter (where c.delta is null),
           coalesce(sum(p.net_qty * c.delta), 0),
           max(p.contract_value)
      into v_missing, v_dp, v_cv
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = r.account_id and p.net_qty <> 0;

    if v_missing > 0 then
      raise log 'apply_delta_strategy: account % waiting on greeks for % leg(s)', r.account_id, v_missing;
      continue;
    end if;

    -- Δp in qty (underlying) units, the unit the band is set in: net_qty counts
    -- venue lots, so the lot-sized delta sum is scaled by the contract value.
    -- Sizing below divides it back out, since a correction is still placed in lots
    -- — leaving the lot count it computes identical to before, only the breach
    -- threshold now reads in the trader's own delta unit.
    v_cv := coalesce(v_cv, 1);
    v_dp := v_dp * v_cv;

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
    -- Runs in the hold zone as well. A roll closes q and sells q further out, so
    -- it does not grow the book and the replacement's lower mark makes it very
    -- slightly cheaper in margin; blocking it would strand the ITM queue exactly
    -- when the account can least afford an unmanaged in-the-money short.
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
        v_exp, v_rollside, s.entry_premium, 0, s.tie_break, v_leg.strike);
      if v_repl.symbol is null then continue; end if;

      v_gap := abs(v_leg.delta) - abs(v_repl.delta);
      if v_gap <= 0 then continue; end if;

      v_q := floor(abs(v_target - v_dp) / (v_cv * v_gap) + 1e-9)::int;
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

      -- One call, both rows: the leg bought back gets it as its exit reason, the
      -- leg sold in its place as its entry reason. They are the same decision.
      perform public.delta_reason(r.account_id, 'roll', v_spot, v_dp, v_target);

      raise log 'apply_delta_strategy: account % rolled % of % out to %',
        r.account_id, v_q, v_leg.symbol, v_repl.symbol;
      v_acted := true;
      exit;
    end loop;

    if v_acted then
      v_n := v_n + 1;
      continue;
    end if;

    -- ---- S5.4: band correction, no ITM leg left to roll --------------------
    -- Picked at entry_premium, the same rule every other sale uses. The spec sized
    -- these off a separate delta range; a price rule already says which strike that
    -- is, and one rule on screen beats two that have to be kept in step. No
    -- `beyond`: a correction is a fresh sell, not a replacement for a leg.
    --
    -- This is the branch that grows the book without bound, and so the one the
    -- hold zone exists to stop. Δp stays outside the band for now; the cut branch
    -- is what brings it back once margin passes the cap, and it prefers exactly
    -- the side this sell would have corrected.
    if v_hold then
      raise log 'apply_delta_strategy: account % band correction held — margin % over target % of equity %',
        r.account_id, round(v_margin, 2), round(v_goal, 2), round(v_equity, 2);
      continue;
    end if;

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null::numeric);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike quoted to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    if v_q <= 0 then continue; end if;

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
-- 3. The bracket sweep, calling it
-- ---------------------------------------------------------------------------
-- Body is 0034's. Only the write at the end changes: the same three lines around
-- the close, now stamping the fill rather than writing a log row.
create or replace function public.apply_tpsl_triggers()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  resp      record;
  res       jsonb;
  v_spot    numeric;
  v_bid     numeric;
  v_ask     numeric;
  v_mark    numeric;
  pos       public.positions;
  v_bullish boolean;
  v_long    boolean;
  v_ref     numeric;
  v_up      boolean;
  v_hit_tp  boolean;
  v_hit_sl  boolean;
  v_exit    numeric;
  v_n       integer := 0;
  -- The delta book's reason, for a bracket that fires on one of its legs.
  v_delta   boolean;
  v_dp      numeric;
begin
  for resp in
    select distinct on (symbol) symbol, content
    from (
      select (r.content::jsonb -> 'result' ->> 'symbol') as symbol,
             r.content,
             r.created
      from net._http_response r
      where r.status_code = 200
        and r.created > now() - interval '90 seconds'
    ) s
    where s.symbol is not null
    order by s.symbol, s.created desc
  loop
    begin
      res := resp.content::jsonb -> 'result';
    exception when others then
      continue;
    end;

    v_spot := nullif(res ->> 'spot_price', '')::numeric;
    v_mark := nullif(res ->> 'mark_price', '')::numeric;
    v_bid  := nullif(res -> 'quotes' ->> 'best_bid', '')::numeric;
    v_ask  := nullif(res -> 'quotes' ->> 'best_ask', '')::numeric;

    for pos in
      select * from public.positions
      where symbol = resp.symbol
        and (take_profit is not null or stop_loss is not null)
    loop
      v_long := pos.net_qty > 0;
      v_bullish := (pos.contract_type = 'call_options') = v_long;

      -- Pick the reference and the direction its rise means profit in.
      if pos.tpsl_trigger = 'mark' then
        v_ref := v_mark;
        v_up  := v_long;      -- a long option gains as its own mark rises
      else
        v_ref := v_spot;
        v_up  := v_bullish;   -- a bullish exposure gains as the index rises
      end if;
      if v_ref is null then continue; end if; -- reference not published yet

      v_hit_tp := pos.take_profit is not null and (
        case when v_up then v_ref >= pos.take_profit else v_ref <= pos.take_profit end
      );
      v_hit_sl := pos.stop_loss is not null and (
        case when v_up then v_ref <= pos.stop_loss else v_ref >= pos.stop_loss end
      );

      if not (v_hit_tp or v_hit_sl) then continue; end if;

      -- The close still books at the exit side of the book, mark as backstop.
      v_exit := case when v_long then coalesce(v_bid, v_mark) else coalesce(v_ask, v_mark) end;
      if v_exit is null then continue; end if;

      -- Read before the close, or Δp would already have the leg missing from it.
      -- The account-kind test is what keeps this out of the other two books: they
      -- have no delta to report and nothing that reads the column.
      v_delta := exists (
        select 1 from public.accounts a where a.id = pos.account_id and a.kind = 'delta'
      );
      v_dp := case when v_delta then public.delta_book_dp(pos.account_id) end;

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end
      );

      -- No target: a bracket answers to the option's own price, not to the band.
      if v_delta then
        perform public.delta_reason(
          pos.account_id,
          case when v_hit_tp then 'take_profit' else 'stop_loss' end,
          v_spot, v_dp);
      end if;

      v_n := v_n + 1;
    end loop;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_tpsl_triggers() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. reset_account, without the log it no longer has to clear
-- ---------------------------------------------------------------------------
-- Back to 0001's body. The reasons live on the fills and positions this already
-- deletes, so they go with them and there is nothing else to sweep.
create or replace function public.reset_account(p_account_id uuid)
returns void
language plpgsql
security invoker
as $$
begin
  -- RLS restricts these to the caller's own rows, so a bad id simply affects nothing.
  delete from public.fills where account_id = p_account_id;
  delete from public.orders where account_id = p_account_id;
  delete from public.positions where account_id = p_account_id;
  update public.accounts set cash_balance = starting_balance where id = p_account_id;
end;
$$;

grant execute on function public.reset_account(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The table, and the writer that fed it
-- ---------------------------------------------------------------------------
-- Last, so nothing above is left referring to something already gone. Dropping
-- the table takes its policies and index with it; the publication membership goes
-- with it too, so there is no publication to tidy up separately.
drop function if exists public.delta_remark(uuid, uuid, text, text, numeric, numeric, numeric, text, integer, boolean);

drop table if exists public.delta_remarks;
