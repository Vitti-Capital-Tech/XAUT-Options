-- 0044_futures_delta_hedge.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0043_stop_the_cut_correction_loop.sql.
--
-- The futures book stops being a place to trade a perpetual by hand and becomes
-- the delta strategy again -- the same strategy, with one rule swapped:
--
--     delta account     Dp is corrected with OPTIONS   (roll, then a fresh sell)
--     futures account   Dp is corrected with FUTURES   (buy or sell XAUTUSD)
--
-- Everything else is shared, and shared by construction rather than by being
-- kept in step: one settings table, one engine, one session clock, one entry,
-- one band, one bracket, one margin guard. A futures account sells the same
-- symmetric option pair at the open and flattens at the same close. The only
-- branch that differs is the one that answers a breach.
--
-- ---------------------------------------------------------------------------
-- Why the mode is not a setting
-- ---------------------------------------------------------------------------
-- It is read off `accounts.kind`. A `delta` account hedges with options, a
-- `futures` account hedges with futures, and there is no third state to get
-- wrong -- no column that can disagree with the page the trader is looking at,
-- and no way to leave a book half-migrated between the two. The page picks the
-- book; the book picks the rule.
--
-- ---------------------------------------------------------------------------
-- The perpetual, as one more row in the chain
-- ---------------------------------------------------------------------------
-- `queue_delta_checks` now asks for `perpetual_futures` alongside the two option
-- types, which is one request rather than two: /v2/tickers accepts the mixed
-- filter and answers with the ~126 options and XAUTUSD in the same array.
--
-- It lands in `delta_chain` with the greeks a linear contract actually has:
--
--     delta 1     one lot of the perpetual is one lot of the underlying
--     gamma 0     that delta never changes, whatever spot does
--
-- Written as literals rather than read from the payload, because the payload
-- carries `"greeks": null` on a perpetual -- the venue publishes no greeks for a
-- contract whose greeks are constants. Everything downstream then needs no
-- special case at all: `delta_book_dp` sums `net_qty * delta` and the hedge
-- counts itself, `delta_book_gp` sums `net_qty * gamma` and the hedge widens no
-- band, and `delta_flatten` closes it through the same two helpers as any option
-- leg -- a buy at the ask, a sell at the bid, which is right for a perpetual too.
--
-- Dp is therefore self-correcting: it already contains the hedge, so
-- `target - Dp` is always the *incremental* size the book still needs, and a
-- hedge that has grown too large reads as a breach on the other side and is sold
-- back down. Nothing has to remember what it hedged.
--
-- ---------------------------------------------------------------------------
-- What a hedge costs
-- ---------------------------------------------------------------------------
-- Margin, and only margin: `mark x cv x lots / leverage`, both sides posting it,
-- floored at the contract's own 1% -- the rule 0038 established, now taught to
-- `delta_account_margin` so the guard can price a book that holds one. At the
-- default 100x a 1.5 XAUT hedge against a $4,600 index blocks about $69, which
-- is why the default is 100 and not 1: leverage on a hedge changes what is
-- blocked, never what is risked.
--
-- Funding is charged to it exactly as 0038 charges it to anything else --
-- `apply_futures_maintenance` bills every open perpetual, whatever kind of
-- account holds it -- so the hedge pays or collects three times a day.
--
-- That function's *liquidation* branch is a different matter, and the reason it
-- needs no change here: it skips any account holding a leg with no fresh
-- perpetual mark this pass, and an option leg never has one. A book that is an
-- option strangle plus a hedge is therefore never liquidated, which is the same
-- answer the delta book already gets. The margin guard, not a liquidation, is
-- what bounds both books.
--
-- ---------------------------------------------------------------------------
-- What the hedge is NOT subject to
-- ---------------------------------------------------------------------------
-- The margin cut cannot take it: cut candidates are option shorts only. Closing
-- the hedge would remove the one position on the book that is *reducing*
-- directional risk, and it has no strike to order the walk by. So the cut takes
-- lots off the option shorts, Dp moves, and the next cycle re-hedges what is
-- left -- the two pulling the same way, as 0043 requires.
--
-- Nor is the hedge trimmed to what the margin cap has left, which the band
-- correction is (0043). That trim exists because selling a fresh option adds
-- risk the cut then has to take back off; a hedge does the opposite. Over the
-- cap the cut still runs first and the hedge waits a cycle, because the cut
-- outranks everything below the session close -- but nothing shrinks a hedge for
-- being expensive in margin.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The one new setting
-- ---------------------------------------------------------------------------
-- Per account, because it is what margins the hedge from the moment it opens.
-- Capped at the venue's own maximum: 100x is the reciprocal of the contract's 1%
-- initial margin, and asking for more would be asking for a margin the venue
-- does not offer. Unused on a delta account, which never opens a perpetual.
alter table public.delta_strategy_settings
  add column if not exists hedge_leverage numeric(20, 8) not null default 100;

alter table public.delta_strategy_settings drop constraint if exists delta_hedge_leverage_chk;
alter table public.delta_strategy_settings
  add constraint delta_hedge_leverage_chk check (hedge_leverage > 0 and hedge_leverage <= 100);

comment on column public.delta_strategy_settings.hedge_leverage is
  'Leverage the futures hedge opens at; margin is notional / leverage, floored at the contract 1% rate. Ignored on an options-hedged (delta) account.';

-- ---------------------------------------------------------------------------
-- 2. The poller: the perpetual rides the option fetch
-- ---------------------------------------------------------------------------
-- One request, not two. The engine's guard on the reply is unchanged and still
-- correct: it tests that the first element carries a `greeks` key, and a
-- perpetual carries one whose value is null -- the key exists, so a reply that
-- happens to list XAUTUSD first is still recognised as the chain reply.
create or replace function public.queue_delta_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
begin
  if not exists (select 1 from public.delta_strategy_settings where armed) then
    return 0;
  end if;

  perform net.http_get(
    url := 'https://api.india.delta.exchange/v2/tickers'
           || '?contract_types=call_options,put_options,perpetual_futures'
           || '&underlying_asset_symbols=XAUT',
    timeout_milliseconds := 8000
  );
  return 1;
end;
$$;
revoke all on function public.queue_delta_checks() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Margin, on a book that can hold a perpetual
-- ---------------------------------------------------------------------------
-- Three shapes now, not two:
--
--     long option    avg_entry x cv x lots            risk capped at the premium
--     short option   (1% x spot + mark) x cv x lots   the venue's shape
--     perpetual      mark x cv x lots / leverage      both sides post it
--
-- The perpetual arm reads its own leverage off the position, capped at 100x so a
-- hand-written row cannot claim a margin below the contract's 1% floor, and
-- defaulting to 100x when it is absent -- which is what the hedge always opens
-- at, and the only sane reading of a perpetual with no leverage recorded.
--
-- Unrealized needs no case: a long gains when the mark rises above entry, a
-- short when it falls below, and a perpetual is no different.
create or replace function public.delta_account_margin(p_account uuid, p_spot numeric)
returns table (margin numeric, equity numeric, unrealized numeric)
language sql
stable
security definer
set search_path = public
as $$
  with valued as (
    select
      p.net_qty,
      abs(p.net_qty)                          as lots,
      p.avg_entry_price::numeric              as avg_entry,
      coalesce(p.contract_value, 1)           as cv,
      p.contract_type = 'perpetual_futures'   as is_perp,
      least(coalesce(p.leverage, 100), 100)   as leverage,
      coalesce(
        c.mark_price,
        case when p.net_qty > 0 then c.best_bid else c.best_ask end,
        p.avg_entry_price::numeric
      )                                       as mark
    from public.positions p
    left join public.delta_chain c on c.symbol = p.symbol
    where p.account_id = p_account and p.net_qty <> 0
  ),
  legs as (
    select
      case
        when is_perp     then mark * cv * lots / leverage
        when net_qty > 0 then avg_entry * cv * lots
        else (0.01 * p_spot + mark) * cv * lots
      end as leg_margin,
      case
        when net_qty > 0 then (mark - avg_entry) * lots * cv
        else (avg_entry - mark) * lots * cv
      end as leg_unrealized
    from valued
  )
  select
    coalesce(sum(leg_margin), 0),
    (select cash_balance from public.accounts where id = p_account)
      + coalesce(sum(leg_unrealized), 0),
    coalesce(sum(leg_unrealized), 0)
  from legs;
$$;
revoke all on function public.delta_account_margin(uuid, numeric) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The hedge trade
-- ---------------------------------------------------------------------------
-- One market order in the perpetual, either way round. Priced the way every
-- other engine trade is: a buy lifts the ask, a sell hits the bid, so the spread
-- is paid honestly rather than assumed away at a mid.
--
-- Three things it does that `delta_sell` does not:
--
--   * it carries the leverage, which is what margins the position from here on
--     (`execute_fill` restates it only on an order that adds exposure);
--   * it arms no bracket. A take-profit on a hedge would close the hedge on a
--     move in the book's favour and leave the option legs unhedged, which is the
--     one thing this position exists to prevent. Dp is its only exit condition;
--   * it marks itself `reduce_only` when the trade can only shrink an opposing
--     position, so the ledger says which hedge trades were unwinds.
--
-- The perpetual is found by contract type rather than by symbol: there is
-- exactly one non-option XAUT contract listed, and naming it here as a literal
-- would be a second place to edit if the venue ever renamed it.
create or replace function public.delta_hedge(p_account uuid, p_user uuid, p_side text,
                                              p_lots int, p_spot numeric, p_leverage numeric)
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
  select * into c from public.delta_chain where contract_type = 'perpetual_futures' limit 1;
  if not found then
    raise log 'delta_hedge: no perpetual in the chain — cannot hedge account %', p_account;
    return;
  end if;

  v_px := case when p_side = 'buy' then c.best_ask else c.best_bid end;
  if v_px is null or v_px <= 0 then
    raise log 'delta_hedge: % has no %', c.symbol,
      case when p_side = 'buy' then 'ask' else 'bid' end;
    return;
  end if;

  select coalesce(net_qty, 0) into v_net
  from public.positions where account_id = p_account and symbol = c.symbol;
  v_net := coalesce(v_net, 0);

  insert into public.orders (account_id, user_id, symbol, product_id, contract_type,
                             strike_price, expiry_label, contract_value, side, order_type,
                             qty, limit_price, reduce_only, leverage)
  values (p_account, p_user, c.symbol, c.product_id, c.contract_type, null,
          c.expiry_label, c.contract_value, p_side, 'market', p_lots, null,
          (p_side = 'buy' and v_net < 0 and p_lots <= abs(v_net))
            or (p_side = 'sell' and v_net > 0 and p_lots <= v_net),
          p_leverage)
  returning id into v_order;

  begin
    perform public.execute_fill(v_order, p_lots, v_px, 0, p_spot);
  exception when others then
    raise log 'delta_hedge: fill failed on % — %', c.symbol, sqlerrm;
    update public.orders set status = 'cancelled', cancel_reason = 'delta strategy fill failed'
    where id = v_order;
  end;
end;
$$;
revoke all on function public.delta_hedge(uuid, uuid, text, int, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The reason lines, for the two new actions
-- ---------------------------------------------------------------------------
-- Same shape as every other one: the rule, where it was aiming, the spot it was
-- priced at, and Dp either side of the trade.
--
--     Bought futures — band breach (target -0.60) · spot $4622.13 · Δp -1.35 → -0.62
--
-- The size is not in the sentence and does not need to be: it is on the row the
-- sentence is written to, and the pair of deltas says what it achieved.
--
-- One thing had to change beyond the wording. Which fills are *exits* was
-- decided by `side = 'buy' or realized_pnl <> 0` -- correct on a sell-only
-- option book, where the only way out is to buy back. A hedge breaks it in both
-- directions: it opens with a buy as often as with a sell. So a perpetual fill is
-- an exit when it realized something, and nothing else. The one case that leaves
-- unlabelled is a hedge unwound at exactly its entry price, which books no P&L
-- and reads as an opening trade; a blank Exit Reason beats a wrong one.
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
    when 'hedge_buy'   then 'Bought futures — band breach'
    when 'hedge_sell'  then 'Sold futures — band breach'
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

  -- The exits. On an option, `side = 'buy'` is the sell-only book's own
  -- definition of a close, and the realized test picks up the one case it misses
  -- — a hand-opened long that the flatten exits by selling. On a perpetual only
  -- the realized test applies: the hedge opens either way round.
  update public.fills
  set reason = v_line
  where account_id = p_account
    and reason is null
    and created_at >= now()
    and (case when contract_type = 'perpetual_futures'
              then realized_pnl <> 0
              else side = 'buy' or realized_pnl <> 0 end);

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
-- 6. The engine, with the two hedging modes
-- ---------------------------------------------------------------------------
-- Unchanged from 0043 except in four places:
--
--   * the chain insert also carries the perpetual, at delta 1 and gamma 0;
--   * `v_mode` is read off the account's kind, once, at the top of its pass;
--   * the cut skips perpetuals, so a hedge is never what gets closed for margin;
--   * a futures account answers a breach with `delta_hedge` and returns, so the
--     ITM walk and the fresh-sell correction below it are options-only.
--
-- The order of the rules is otherwise identical for both books, and deliberately
-- so: flatten at the close, cut over the cap, enter at the open, then correct.
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
    -- A futures hedge contributes nothing to Γp (gamma 0), so a hedged book's
    -- band is set by its option legs alone. That is the honest answer: the
    -- tolerance is meant to scale with how fast Δp moves, and a linear hedge does
    -- not move it at all.
    v_gp := public.delta_book_gp(r.account_id);
    select low, high into v_band_low, v_band_high
    from public.delta_band(s.band_low, s.band_high, s.gamma_multiplier, v_gp);

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
    -- Gamma is required on the same terms as delta: with a multiplier set it is
    -- what the band is made of, so a leg silently absent from it would move the
    -- band by that leg's whole share. The hedge satisfies both from the chain row
    -- the ingest above wrote, so a hedged book stands down for a missing greek no
    -- more often than an unhedged one.
    select count(*) filter (where c.delta is null or c.gamma is null),
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
