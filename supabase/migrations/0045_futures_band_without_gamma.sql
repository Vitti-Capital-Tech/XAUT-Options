-- 0045_futures_band_without_gamma.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0044_futures_delta_hedge.sql.
--
-- The futures book stops reading gamma. One function changes -- the engine -- and
-- only in two places.
--
-- ---------------------------------------------------------------------------
-- Why gamma was there, and why that book does not want it
-- ---------------------------------------------------------------------------
-- Gamma has exactly one job here: `0039` derives the band from it, `band =
-- +/- |Gp| x gamma_multiplier`, on the reasoning that gamma is the rate Dp itself
-- moves at, so a book that runs through delta twice as fast should be given twice
-- the tolerance.
--
-- That argument was written for a book whose only answer to a breach was to sell
-- more premium -- where each correction is expensive, irreversible and grows the
-- book, so correcting less often is worth something. A futures hedge is none of
-- those: it is one linear trade, it costs the spread and a little margin, and the
-- next cycle can undo it. There is no reason to widen the tolerance for a book
-- that can simply hedge again, and a wider band on a fast-moving book is the
-- opposite of what a hedger wants -- it is the moment to be *closer* to flat, not
-- further from it. So the futures book defends the band as typed, and
-- `gamma_multiplier` becomes an options-only control.
--
-- ---------------------------------------------------------------------------
-- The consequence that actually matters
-- ---------------------------------------------------------------------------
-- Not the band -- the stand-down. `0039` made gamma *required* on the same terms
-- as delta, and correctly so: with a multiplier set, a leg silently missing from
-- Gp moves the band by that leg's whole share, which is worse than not trading.
-- So one leg with a null gamma stands the entire cycle down.
--
-- On the futures book that trade-off is now all cost and no benefit. Nothing reads
-- Gp, so a missing gamma corrupts nothing -- but it would still stop the book
-- being hedged, which is the one thing it exists to do. After this file, a
-- futures account needs `delta` on every leg and nothing more; an options account
-- is unchanged and still needs both.
--
-- Gp is still computed for the delta book, still per cycle, still from the same
-- `delta_book_gp`. And the perpetual still carries gamma 0 in the chain
-- (`0044`), which is what it is: a linear contract's delta does not move.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The engine
-- ---------------------------------------------------------------------------
-- Unchanged from 0044 except in the two places gamma is read:
--
--   * the band. A futures account takes `band_low`/`band_high` as typed and does
--     not call `delta_book_gp` at all; an options account derives as before.
--   * the stand-down. `gamma is null` only disqualifies a leg on an options
--     account. A futures account needs a delta per leg and nothing else.
--
-- Everything else is 0044 line for line: the chain insert carrying the perpetual,
-- the mode read off the account's kind, the cut skipping perpetuals, and the
-- futures branch answering a breach with `delta_hedge`.
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
  -- The book's net gamma, and the band actually defended this cycle.
  v_gp        numeric;
  v_band_low  numeric;
  v_band_high numeric;
  -- 'options' on a delta account, 'futures' on a futures one. Read off the
  -- account kind, so it cannot disagree with the page that owns the book.
  v_mode      text;
  -- Lots the hedge needs, signed: positive buys, negative sells.
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
  -- Margin guard, per account.
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

  -- The hedge instrument, in the same table as the strikes so that every reader
  -- of the chain prices it without knowing it is different. Its greeks are the
  -- literals a linear contract has — delta 1 per lot, gamma 0 — because the
  -- venue publishes `"greeks": null` on a perpetual. No strike, and 'PERP' where
  -- an expiry label would go: it never settles.
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
    -- never strand an open book. Flattening reads the positions, not the setting,
    -- so it closes the hedge on the same pass and by the same rule as the strikes.
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

    -- ---- The band this cycle defends -------------------------------------
    -- Derived once, here, rather than at each of the three places that read it:
    -- the margin cut needs it before the rebalance section has computed
    -- anything, and a band that differed between the cut's side preference and
    -- the breach test would be two rules wearing one name.
    --
    -- Positions cannot change between here and the rebalance below -- every
    -- branch that trades ends in `continue` -- so one reading stays correct for
    -- the whole pass.
    --
    -- The futures book does not derive its band. `gamma_multiplier` is an
    -- options-only control, and this is the one place that is enforced: Gp is not
    -- computed, `delta_band` is not called, and the typed pair is the band
    -- outright. See this file's header for why -- in short, widening the tolerance
    -- to correct less often is worth something when every correction is a fresh
    -- short, and worth nothing when it is a hedge the next cycle can undo.
    if v_mode = 'futures' then
      v_gp        := null;
      v_band_low  := s.band_low;
      v_band_high := s.band_high;
    else
      v_gp := public.delta_book_gp(r.account_id);
      select low, high into v_band_low, v_band_high
      from public.delta_band(s.band_low, s.band_high, s.gamma_multiplier, v_gp);
    end if;

    -- ---- Margin: where this account stands before it is allowed to sell ----
    select margin, equity into v_margin, v_equity
    from public.delta_account_margin(r.account_id, v_spot);

    v_cap  := v_equity * s.margin_cap_pct / 100.0;
    v_goal := v_equity * s.margin_target_pct / 100.0;
    -- Wiped equity lands here too: at or below zero every threshold is at or
    -- below zero, so any open short is over it and the cut branch takes over.

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

      -- Which side to take the lots off, measured against the band's MIDPOINT
      -- rather than against whether Dp has breached.
      --
      -- Reading a breach left this null while Dp was inside the band, so the cut
      -- had no preference and fell through to "deepest in the money" -- whichever
      -- leg spot had drifted nearest, with no regard for what closing it does to
      -- Dp. Closing a short put removes positive delta, so a put-side cut with Dp
      -- already below the middle drives Dp out of the band, and the correction
      -- then answers by re-selling the strike the cut just bought back. The two
      -- rules trade against each other every cycle, each paying the spread.
      --
      -- Below the mid, closing a call raises Dp; above it, closing a put lowers
      -- it. Either way the cut moves Dp toward the middle while it frees margin.
      -- On a real breach this is the same answer the old test gave.
      v_cutside := case
        when v_dp is null then null
        when v_dp < (v_band_low + v_band_high) / 2 then 'call_options'
        when v_dp > (v_band_low + v_band_high) / 2 then 'put_options'
      end;

      -- How much margin has to come off to reach the target, and the first leg
      -- to take it off. Ordered by side preference, then by how deep in the
      -- money it is.
      v_short := v_margin - v_goal;

      -- Option shorts only. A futures hedge is excluded on both counts: closing
      -- it would drop the one position on the book that is reducing directional
      -- risk, and it has no strike for the "deepest in the money" ordering to
      -- read — a null there would sort first and the cut would take the hedge
      -- before anything else. The hedge is re-sized by the rebalance instead,
      -- once the cut has moved Δp.
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

      -- No short to cut: the margin is all long premium and hedge, neither of
      -- which is reduced by closing an option at a loss.
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
    -- unsettled; with none chosen, expiry_pick's nearest/next applies. Both books
    -- need one: the daily entry is an option pair whichever way Δp is corrected.
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
      -- No margin gate here. An entry only ever runs on a book the previous
      -- close has flattened, so blocked margin is at or near zero when it fires;
      -- the gate that used to sit here was guarding a state the session clock
      -- already makes unreachable. Above the cap the cut branch returned long ago.

      -- Read before the sale, so the reason on the two new legs says what the
      -- book was before they joined it.
      v_dp := public.delta_book_dp(r.account_id);

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_desc := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot,
                                        s.max_notional_per_strike);
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
    -- On an options account gamma is required on the same terms as delta: with a
    -- multiplier set it is what the band is made of, so a leg silently absent
    -- from Gp would move the band by that leg's whole share, and trading against
    -- a band that wrong is worse than not trading.
    --
    -- On a futures account nothing reads Gp, so a missing gamma corrupts nothing
    -- -- and standing the cycle down for it would leave the book unhedged for the
    -- one reason that has no consequences. A delta on every leg is the whole
    -- requirement there.
    --
    -- The hedge itself satisfies both from the chain row 0044 writes for it, so it
    -- is never the leg that stands anything down.
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

    -- Δp in qty (underlying) units, the unit the band is set in: net_qty counts
    -- venue lots, so the lot-sized delta sum is scaled by the contract value.
    -- Sizing below divides it back out, since a correction is still placed in lots
    -- — leaving the lot count it computes identical to before, only the breach
    -- threshold now reads in the trader's own delta unit.
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

    -- ---- The breach, answered with futures ---------------------------------
    --
    -- One trade, either direction, sized straight off the gap Δp still has to
    -- close: `(target - Δp) / cv` lots, because one lot of the perpetual carries
    -- exactly one lot of delta. Positive buys, negative sells — and no side
    -- preference to compute, since a linear hedge is the same instrument whether
    -- the book needs delta added or taken away.
    --
    -- Rounded down in magnitude, like every option-side size here, so a hedge
    -- cannot overshoot the landing point it was aimed at. Under one lot it does
    -- nothing and says so: the smallest trade available is larger than the error
    -- it would be correcting.
    --
    -- Δp already contains the hedge, so this is always the *incremental* size.
    -- A hedge that has become too large as the option deltas came back reads as a
    -- breach on the other edge and is sold back down by this same branch — which
    -- is why nothing here records what was hedged, or needs to.
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

    v_rollside := case when v_breach = 'low' then 'call_options' else 'put_options' end;
    v_sellside := case when v_breach = 'low' then 'put_options'  else 'call_options' end;
    v_used     := case when v_breach = 'low' then s.rolls_used_call else s.rolls_used_put end;

    -- ---- S5.1/5.2: walk the ITM queue, most-ITM first ----------------------
    -- A roll closes q and sells q further out, so it does not grow the book and
    -- the replacement's lower mark makes it very slightly cheaper in margin. It
    -- ran even under the old hold zone, for the reason that zone is now gone
    -- entirely: stranding the ITM queue when the account can least afford an
    -- unmanaged in-the-money short is the wrong trade-off at any margin level.
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
      -- Never more than the leg being replaced holds, and never more than the
      -- replacement strike has room for. `least` ignores nulls, so an unset cap
      -- (room_lots null) leaves the size exactly as it was.
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
    -- This is the branch that grows the book without bound, and it now runs at
    -- any margin below the cap. It used to be frozen above margin_target_pct,
    -- which left a breached band uncorrected through that whole zone -- the
    -- strategy's one job, not done, in precisely the state where Dp is most
    -- likely to be moving. The cut branch answers the risk instead, and it prefers
    -- exactly the side this sell would have corrected, so the two pull the same
    -- way rather than against each other.

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null::numeric,
      r.account_id, s.max_notional_per_strike, v_spot);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike with room to correct with',
        r.account_id, v_sellside;
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    -- Sell what fits. The picker has already skipped strikes with no room at all,
    -- so this only trims the last partial one, and the next cycle carries on from
    -- the strike after it.
    v_q := least(v_q, v_pick.room_lots);

    -- ...and no more margin than the cap has left. This is the half that stops
    -- this rule and the cut trading against each other: sized off Dp alone, a
    -- correction re-blocks the exact margin a cut just freed, which puts the book
    -- back over the cap and fires the next cut -- a loop that converges on
    -- nothing and pays the bid-ask spread every lap.
    --
    -- Same per-lot margin the cut prices with, off the price this would sell at.
    -- Landing exactly on the cap is fine: the cut needs `> cap`, so the boundary
    -- is not a breach. Crossing it is what the book must not do.
    --
    -- The futures branch above carries no such trim, deliberately: it reduces the
    -- risk this one adds.
    if s.margin_cap_pct > 0 then
      v_perlot := (0.01 * v_spot + v_pick.premium) * v_cv;
      if v_perlot > 0 then
        v_q := least(v_q, greatest(0, floor((v_cap - v_margin) / v_perlot)::int));
      end if;
    end if;

    if v_q <= 0 then
      raise log 'apply_delta_strategy: account % Dp outside the band but margin % is at the cap % — nothing to sell with',
        r.account_id, round(v_margin, 2), round(v_cap, 2);
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
