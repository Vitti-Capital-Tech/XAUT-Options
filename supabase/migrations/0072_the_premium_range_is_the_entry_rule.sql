-- 0072_the_premium_range_is_the_entry_rule.sql
--
-- Run this whole file in the Supabase SQL Editor after 0071.
--
-- The futures panel carried two controls that both said where to sell, and they
-- did different jobs:
--
--   Entry premium    a target to rank against. The strike quoted nearest it won.
--   Premium range    a floor and a ceiling to filter by.
--
-- Before 0069 only the target bound anything, because the ceiling excluded
-- nothing at all — it merely supplied a target of its own when the entry premium
-- was unset. Making the range hard put the two controls on the same panel
-- contradicting each other, and the configuration that was actually running says
-- it plainly: an entry premium of $6 against a range of $3–$5. A target outside
-- the only strikes that were allowed to be sold.
--
-- 0069 clamped the target into the range, so it worked. It also explained
-- nothing to the person reading the panel, and left them tuning a number that
-- could not do what it looked like it did.
--
-- So on a futures book the range is now the whole rule, and the target falls out
-- of it. `delta_pick_premium_ranked` already reads a zero entry premium as "aim
-- at the top of the range":
--
--     target_val = ceil_val   when p_entry is 0 and a ceiling is set
--
-- which ranks the richest in-range strike first and the rest below it in order.
-- Three pairs is then the three richest strikes inside the band — a ladder,
-- which is what a multi-pair strangle wants — instead of three clustered around
-- a separate number that had nothing to do with the band.
--
-- ---------------------------------------------------------------------------
-- What a half-set range means
-- ---------------------------------------------------------------------------
--
--   min and max    sell inside the band, richest first.
--   max only       nothing richer than this; aim at it. Unchanged.
--   min only       nothing cheaper than this; aim at it — the cheapest strike
--                  that clears the floor, which is the furthest out of the
--                  money. Unchanged.
--   neither        no rule at all. With no entry premium left to fall back on,
--                  ranking against a target of zero would sell whatever happens
--                  to be quoted cheapest on the board. The book does not enter,
--                  and says so in the log on every cycle.
--
-- That last case is unreachable from the panel, which requires a range now. A
-- row in it was written by hand, or by a client older than this migration.
--
-- ---------------------------------------------------------------------------
-- Scope
-- ---------------------------------------------------------------------------
--
-- Futures books only, and deliberately. The delta book has no premium range —
-- `entry_premium` is the only price rule it has, and it is read by the roll
-- replacement and the band correction as well as the entry. The column, the
-- account setting and the Delta Strategy panel's own control are all untouched.
--
-- No schema change: `entry_premium` and the window's `entryPremium` key both
-- stay where they are. Nothing on a futures book reads them any more.
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
  -- 0069: the re-entry budget, and how much of it this side has spent.
  v_max_reent     int;
  v_reent_used    int;
  -- 0069: the ATM leg's own size, kept apart from v_q so the replacement can be
  -- sized by the cap's room while the exit stays the whole leg.
  v_exit_q        int;
  -- 0069: did the buy-back actually move the position. delta_close_leg swallows
  -- a leg the chain cannot price, so a replacement must never be sold on the
  -- assumption that the exit landed.
  v_before        numeric;
  v_after         numeric;
  v_shifted       boolean;
  -- 0069: legs on a contract this window is not trading.
  v_stale         record;
  v_stale_n       int;
  -- 0070: distinct short strikes per side on the traded expiry, either side of a
  -- call to delta_sell_entry, so how many pairs it actually opened is counted
  -- from the book rather than parsed out of its description.
  v_c0            int;
  v_p0            int;
  v_c1            int;
  v_p1            int;
  v_opened        int;
  -- 0070: the top-up's margin brake. Its own flag, not v_acted — that one is
  -- read again after the ATM loop to decide whether the hedge still runs, and
  -- borrowing it here would silently switch delta management off for a cycle.
  v_brake         boolean;
  -- 0071: does the governing window's own bookkeeping say it opened the book
  -- that is currently on the table.
  v_owns          boolean;
  -- 0072: does this book have a premium range to sell inside. On a futures book
  -- it is the entire entry rule, so without one there is nothing to enter on.
  v_has_range     boolean;
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
        v_max_reent    := coalesce(nullif(v_win ->> 'maxReentries', '')::int, s.max_reentries, 1);
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
        v_max_reent    := coalesce(s.max_reentries, 1);
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
      v_max_reent    := coalesce(s.max_reentries, 1);
      v_dte          := null;
      v_margin_cap   := s.margin_cap_pct;
      v_margin_tgt   := s.margin_target_pct;
    end if;

    -- ---- The premium range is the entry rule -------------------------------
    -- 0072: a futures book has no entry premium any more.
    --
    -- It had two controls saying where to sell and they did different jobs:
    -- `entryPremium` was a target to rank against, `entryPremiumMin/Max` a range
    -- to filter by. Before 0069 only the target really bound anything, because
    -- the maximum excluded nothing; after 0069 made the range hard, the two sat
    -- on the same panel contradicting each other. The observed configuration was
    -- an entry premium of $6 against a range of $3–$5 — a target outside the only
    -- strikes that were allowed to be sold. 0069 clamped it into the range to
    -- keep it sane, which works and explains nothing to the person reading the
    -- panel.
    --
    -- So the range is now the whole rule, and the target falls out of it:
    -- `delta_pick_premium_ranked` already reads a zero entry premium as "aim at
    -- the top of the range", which ranks the richest in-range strike first and
    -- the rest below it in order. Three pairs is then the three richest strikes
    -- inside the band — a ladder, which is what a multi-pair strangle wants —
    -- rather than three clustered around an arbitrary separate number.
    --
    -- The column and the panel control stay for the delta book, which has no
    -- range and for which the entry premium is still the only price rule it has.
    -- This is scoped to `futures` for exactly that reason.
    if v_mode = 'futures' then
      v_entry_prem := 0;
      -- One bound is enough: a floor alone means "nothing cheaper than this" and
      -- aims at the floor, a ceiling alone means "nothing richer than this" and
      -- aims at the ceiling. Neither is the state that matters — with no entry
      -- premium left to fall back on, a book with no range has no rule at all,
      -- and ranking against a target of zero would sell whatever is quoted
      -- cheapest on the board. It does not enter.
      v_has_range := coalesce(v_prem_min, 0) > 0 or coalesce(v_prem_max, 0) > 0;
    else
      v_has_range := true;
    end if;

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          shifts_used_call = 0, shifts_used_put = 0,
          reentries_used_call = 0, reentries_used_put = 0, pairs_open = 0,
          entered_day = null, flattened_day = null, touched_symbols = '{}', pass_open = false,
          entered_window_ids = '{}', open_window_id = null
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
    end if;

    -- ---- Session closed: flatten -------------------------------------------
    if v_phase <> 'open' then
      if s.entered_day is not null then
        update public.delta_strategy_settings set entered_day = null
        where account_id = r.account_id;
      end if;

      -- 0069: the gate is the book, not the stamp, and the stamp follows the
      -- outcome rather than the attempt.
      --
      -- `flattened_day is distinct from v_day` used to stand in front of this.
      -- It read as "flatten once a day", and it made the close unrepeatable: a
      -- leg delta_close_leg could not price -- it needs an ask, and the chain
      -- drops any row the venue stopped quoting two minutes ago -- was left open
      -- with the day marked flattened, so no later cycle came back for it. That
      -- book then ran into the next session, was adopted there, and the new
      -- window sold its own expiry on top of it. Two expiries in one book, from
      -- one failed buy-back.
      --
      -- So: flatten whenever anything is open past the close, and only claim the
      -- day when the book is actually flat afterwards. A leg that will not close
      -- is named in the log every cycle until it does, which is the only honest
      -- thing to do with a position the engine cannot reach.
      if exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        select count(*) into v_legs
        from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        perform public.delta_reason(r.account_id, 'flatten', v_spot, v_dp);

        select count(*), string_agg(symbol, ', ') into v_stale_n, v_unpriced
        from public.positions where account_id = r.account_id and net_qty <> 0;

        if coalesce(v_stale_n, 0) = 0 then
          update public.delta_strategy_settings
          set flattened_day = v_day, touched_symbols = '{}', pass_open = false,
              open_window_id = null, pairs_open = 0
          where account_id = r.account_id;
          raise log 'apply_delta_strategy: account % flattened % leg(s) at window/session close', r.account_id, v_legs;
        else
          raise log 'apply_delta_strategy: account % flattened % of % leg(s) at close — % still open: %',
            r.account_id, v_legs - v_stale_n, v_legs, v_stale_n, v_unpriced;
        end if;
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

    -- ---- Window handover ---------------------------------------------------
    -- 0069: one window's book never runs into the next window's.
    --
    -- The close-flatten above only fires when the phase is not 'open', and
    -- between two back-to-back windows it never is. delta_session_window reports
    -- 'open' continuously across a handover and simply changes which window
    -- governs -- and the end minute is inclusive, so 09:00-12:00 and 12:00-16:00
    -- are both open at 12:00 and the later-starting one wins (0066). The book
    -- from the first window was therefore still on the table when the second
    -- window's entry fired, and since every window resolves its own
    -- `daysToExpiry`, that entry was on a different contract by construction.
    -- That is where the second expiry came from, and where the second entry
    -- came from.
    --
    -- `open_window_id` is the window that owns whatever is open. It is stamped
    -- by the entry and cleared by every flatten, so a mismatch here means the
    -- governing window changed while a book was live: flatten it, and let the
    -- incoming window open its own on the next cycle.
    --
    -- Null is left alone deliberately. A book opened by hand, or one carried
    -- across this migration, has no owning window, and flattening it on sight
    -- would be this engine liquidating a position it never opened. The adopt
    -- branch below claims such a book for the current window instead, and the
    -- stale-expiry rule closes the part of it that is on the wrong contract.
    if s.open_window_id is not null and s.open_window_id is distinct from v_win_id then
      if exists (select 1 from public.positions where account_id = r.account_id and net_qty <> 0) then
        select count(*) into v_legs
        from public.positions where account_id = r.account_id and net_qty <> 0;
        v_dp := public.delta_book_dp(r.account_id);

        perform public.delta_flatten(r.account_id, r.user_id, v_spot);
        perform public.delta_reason(r.account_id, 'window_handover', v_spot, v_dp);

        select count(*), string_agg(symbol, ', ') into v_stale_n, v_unpriced
        from public.positions where account_id = r.account_id and net_qty <> 0;

        if coalesce(v_stale_n, 0) = 0 then
          update public.delta_strategy_settings
          set open_window_id = null, touched_symbols = '{}', pass_open = false,
              pairs_open = 0
          where account_id = r.account_id;
          raise log 'apply_delta_strategy: account % handover % -> % — flattened % leg(s)',
            r.account_id, s.open_window_id, coalesce(v_win_id, '(none)'), v_legs;
        else
          raise log 'apply_delta_strategy: account % handover % -> % — flattened % of %, % still open: %',
            r.account_id, s.open_window_id, coalesce(v_win_id, '(none)'),
            v_legs - v_stale_n, v_legs, v_stale_n, v_unpriced;
        end if;
        v_n := v_n + 1;
        continue;
      end if;

      -- Nothing open, so there is nothing to flatten and no reason to spend a
      -- cycle on it: hand the budgets to the incoming window and carry on into
      -- its entry below.
      --
      -- The budgets reset here rather than only at the session-day roll because
      -- `maxShifts` and `maxReentries` are read off the window (0061 made every
      -- filter per-window). A per-window allowance drawn from a per-day counter
      -- is not an allowance at all -- window B asking for two shifts would find
      -- window A had already spent them.
      update public.delta_strategy_settings
      set open_window_id = null, touched_symbols = '{}', pass_open = false,
          shifts_used_call = 0, shifts_used_put = 0,
          reentries_used_call = 0, reentries_used_put = 0, pairs_open = 0
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
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
          and to_date(expiry_label, 'DDMMYY') = v_day::date
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
          and to_date(expiry_label, 'DDMMYY') >= v_day::date + 1
        group by expiry_label order by to_date(expiry_label, 'DDMMYY') asc limit 1;

      elsif v_rule = 'friday' then
        select expiry_label into v_exp
        from public.delta_chain
        where expiry_label ~ '^\d{6}$'
          and (to_date(expiry_label, 'DDMMYY')::timestamp at time zone 'UTC') + interval '16 hours' > now()
          and to_date(expiry_label, 'DDMMYY') >= v_day::date
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

    -- ---- Stale expiries ----------------------------------------------------
    -- 0069: a leg on any contract but the one this window trades is closed on
    -- sight, before the entry, the band or the ATM scan gets to look at the book.
    --
    -- Everything downstream reads the book as one position set: Δp sums every
    -- leg, the ATM scan ranks every short by its distance through spot, the
    -- margin cut picks the nearest to spot, the empty-wing rule counts sides.
    -- None of them filter by expiry, and none of them can be made to sensibly --
    -- 30 points from spot buys $5 of premium at eight hours to settlement and 80
    -- points buys it at thirty-two, so a band correction computed across two
    -- expiries at once is arithmetic on two different instruments.
    --
    -- Rather than teach six rules to filter, the book is kept to one expiry:
    -- this is the only place that has to know, and every rule after it is
    -- single-expiry by construction.
    --
    -- A leg that will not close keeps its place and blocks the entry below,
    -- which is the conservative half of the same rule: the alternative is
    -- selling a second expiry on top of the one we just failed to be rid of.
    -- The usual reason is a contract the venue has stopped quoting, which
    -- apply_settlement_responses clears at settlement.
    -- Futures only, like every other rule in this block. A delta book reaches
    -- the same state by different routes -- it has no windows, and its roll
    -- replaces a leg rather than re-entering a book -- and forcing a close on it
    -- is a change nobody asked for.
    if v_mode = 'futures' then
      select count(*) into v_stale_n
      from public.positions
      where account_id = r.account_id
        and net_qty <> 0
        and contract_type in ('call_options', 'put_options')
        and coalesce(expiry_label, split_part(symbol, '-', 4)) is distinct from v_exp;
    else
      v_stale_n := 0;
    end if;

    if coalesce(v_stale_n, 0) > 0 then
      v_dp := public.delta_book_dp(r.account_id);

      for v_stale in
        select symbol, net_qty,
               coalesce(expiry_label, split_part(symbol, '-', 4)) as exp
        from public.positions
        where account_id = r.account_id
          and net_qty <> 0
          and contract_type in ('call_options', 'put_options')
          and coalesce(expiry_label, split_part(symbol, '-', 4)) is distinct from v_exp
      loop
        if v_stale.net_qty < 0 then
          perform public.delta_buy_back(r.account_id, r.user_id, v_stale.symbol,
                                        abs(v_stale.net_qty)::int, v_spot);
        else
          perform public.delta_sell(r.account_id, r.user_id, v_stale.symbol,
                                    v_stale.net_qty::int, v_spot);
        end if;
      end loop;

      perform public.delta_reason(r.account_id, 'stale_expiry_exit', v_spot, v_dp);

      select count(*), string_agg(symbol || ' (' || coalesce(expiry_label, split_part(symbol, '-', 4)) || ')', ', ')
        into v_legs, v_unpriced
      from public.positions
      where account_id = r.account_id
        and net_qty <> 0
        and contract_type in ('call_options', 'put_options')
        and coalesce(expiry_label, split_part(symbol, '-', 4)) is distinct from v_exp;

      raise log 'apply_delta_strategy: account % trades % — closed % leg(s) on other expiries, % left: %',
        r.account_id, v_exp, v_stale_n - coalesce(v_legs, 0), coalesce(v_legs, 0),
        coalesce(v_unpriced, '(none)');

      v_n := v_n + 1;

      -- Something closed, so the book has changed under every figure computed
      -- below. Re-read it next cycle rather than acting on a stale one. Nothing
      -- closed and there is no progress to wait for: fall through, and let the
      -- entry gate refuse to add to it.
      if coalesce(v_legs, 0) < v_stale_n then
        continue;
      end if;
    end if;

    -- ---- Reconcile the bookkeeping against the book -------------------------
    -- 0071: `pairs_open` may never understate what is actually open.
    --
    -- 0070 introduced the counter and set it from the entry, which is correct
    -- for every book opened after 0070 and wrong for every book that was already
    -- on the table when it applied. Those rows got the column default of 0 while
    -- holding a live pair, and nothing recounted them: the adopt branch below is
    -- the only thing that ever sets the counter from the book, and it is gated on
    -- `entered_day is distinct from v_day` -- false for a book this window
    -- entered earlier the same session.
    --
    -- The same gap covers `open_window_id`, which 0069 added: a book opened
    -- before 0069 has no owning window, and the top-up is gated on the window
    -- owning the book, so it could never run.
    --
    -- Both halves showed as the same symptom -- a panel reading "Pairs 0 / 3"
    -- beside a book holding one pair, with the top-up silently unreachable. But
    -- the counter being low is the more dangerous half of the two, and it was
    -- dangerous in the other direction: had `open_window_id` happened to be set,
    -- a `pairs_open` of 0 against a `pairsCount` of 3 would have asked the top-up
    -- for three *more* pairs on a book already holding one. Four pairs, from a
    -- window configured for three.
    --
    -- `greatest` is what makes this safe to run every cycle. The counter may be
    -- raised to meet the book and never lowered to it:
    --
    --   book above counter   a migration, an adoption, a hand-opened leg. The
    --                        counter catches up, and the top-up asks only for
    --                        what is genuinely missing.
    --   book below counter   an ATM exit closed a leg and the re-entry budget
    --                        did not replace it. The counter stays where it was,
    --                        so the top-up does not quietly refill what the
    --                        re-entry budget deliberately declined to.
    --
    -- That asymmetry is the whole rule, and it is why this cannot be written as
    -- "pairs_open = pairs on the book".
    if v_mode = 'futures' then
      select count(distinct symbol) filter (where contract_type = 'call_options'),
             count(distinct symbol) filter (where contract_type = 'put_options')
        into v_c0, v_p0
      from public.positions
      where account_id = r.account_id and net_qty < 0
        and contract_type in ('call_options', 'put_options')
        and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

      v_opened := least(coalesce(v_c0, 0), coalesce(v_p0, 0));

      -- Ownership is claimed only on this window's own word: its id is in
      -- `entered_window_ids` and the entry stamp is this session day. That is
      -- the engine saying it opened a book here, which is a different thing from
      -- finding a book and assuming it. A book nobody claims stays unowned and
      -- reaches the adopt branch below, exactly as 0069 intended.
      v_owns := v_win_id is not null
                and s.entered_day = v_day
                and v_win_id = any(coalesce(s.entered_window_ids, '{}'));

      if v_opened > 0
         and (coalesce(s.pairs_open, 0) < v_opened
              or (s.open_window_id is null and v_owns)) then
        update public.delta_strategy_settings
        set pairs_open = greatest(coalesce(pairs_open, 0), v_opened),
            open_window_id = case when open_window_id is null and v_owns
                                  then v_win_id else open_window_id end
        where account_id = r.account_id;
        select * into s from public.delta_strategy_settings where account_id = r.account_id;

        raise log 'apply_delta_strategy: account % reconciled — % pair(s) on % under window %',
          r.account_id, v_opened, v_exp, coalesce(s.open_window_id, '(unowned)');
      end if;
    end if;

    -- ---- Adopt hand-opened books -------------------------------------------
    -- 0069: scoped to the traded expiry, and the adopting window now owns what
    -- it adopted.
    --
    -- Unscoped, a book left on last session's contract satisfied this test, so
    -- the engine adopted a strangle it was about to close as stale. And because
    -- adopting only stamped `entered_day`, the entry's window arm below --
    -- `v_win_id not in entered_window_ids` -- was still true, so it entered on
    -- top of the book it had just adopted. That is the second route to two
    -- entries at once, and it fires on the first cycle of every session that
    -- opens with anything on the table.
    --
    -- Claiming the window as well closes it: an adopted book is this window's
    -- book, entered, and flattened at its close like any other.
    if s.entered_day is distinct from v_day
       and exists (select 1 from public.positions p where p.account_id = r.account_id
                     and p.contract_type = 'call_options' and p.net_qty < 0
                     and coalesce(p.expiry_label, split_part(p.symbol, '-', 4)) = v_exp)
       and exists (select 1 from public.positions p where p.account_id = r.account_id
                     and p.contract_type = 'put_options' and p.net_qty < 0
                     and coalesce(p.expiry_label, split_part(p.symbol, '-', 4)) = v_exp) then
      -- 0070: count what is already there, so the top-up fills a real shortfall
      -- rather than treating an adopted book as if it had opened nothing. Left
      -- at zero, a hand-opened pair would read as "3 pairs still owed" and the
      -- engine would sell three more over the top of it.
      select count(distinct symbol) filter (where contract_type = 'call_options'),
             count(distinct symbol) filter (where contract_type = 'put_options')
        into v_c0, v_p0
      from public.positions
      where account_id = r.account_id and net_qty < 0
        and contract_type in ('call_options', 'put_options')
        and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null,
          open_window_id = coalesce(open_window_id, v_win_id),
          pairs_open = least(coalesce(v_c0, 0), coalesce(v_p0, 0)),
          entered_window_ids = case when v_win_id is not null and not (v_win_id = any(entered_window_ids))
                                    then array_append(entered_window_ids, v_win_id)
                                    else entered_window_ids end
      where account_id = r.account_id;
      select * into s from public.delta_strategy_settings where account_id = r.account_id;
      v_adopted := true;
      raise log 'apply_delta_strategy: account % adopted existing % book for session % under window %',
        r.account_id, v_exp, v_day, coalesce(v_win_id, '(none)');
    end if;

    -- ---- Window / Daily Entry -----------------------------------------------
    if v_mode = 'futures' and not v_has_range then
      -- Loud, and every cycle. A futures book with no premium range will never
      -- open anything, and this is the only thing that says so — the panel's
      -- entry controls make the state unreachable, so a row in it was written by
      -- hand or by a client older than 0072.
      raise log 'apply_delta_strategy: account % has no premium range — a futures book has no other entry rule, so nothing will be sold until one is set',
        r.account_id;

    -- 0069: and only onto an empty option book.
    --
    -- The two arms are an OR, so either one firing opens a full set of pairs,
    -- whatever is already on the table. The handover flatten and the stale-
    -- expiry close above should leave nothing there by the time this runs -- but
    -- "should" is what the last four migrations each thought about a different
    -- route into this branch, and the cost of being wrong here is a second
    -- strangle sold on top of a live one. So the state that actually matters is
    -- tested directly, rather than inferred from the stamps.
    --
    -- Short option legs only: the perpetual is a hedge on the book, not a book,
    -- and it is flat by the close like everything else.
    elsif ((v_win_id is not null and not (v_win_id = any(s.entered_window_ids)))
        or (s.entered_day is distinct from v_day))
       and not exists (select 1 from public.positions
                       where account_id = r.account_id
                         and net_qty < 0
                         and contract_type in ('call_options', 'put_options')) then
      v_dp := public.delta_book_dp(r.account_id);

      select count(distinct symbol) filter (where contract_type = 'call_options'),
             count(distinct symbol) filter (where contract_type = 'put_options')
        into v_c0, v_p0
      from public.positions
      where account_id = r.account_id and net_qty < 0
        and contract_type in ('call_options', 'put_options')
        and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

      v_desc := public.delta_sell_entry(
        r.account_id, r.user_id, v_exp, v_entry_prem,
        v_prem_min, v_tie_break, v_qty, v_spot,
        v_notional_cap,
        case when v_mode = 'futures' then v_pairs else 1 end,
        v_prem_max
      );

      if v_desc is not null then
        -- 0070: how many pairs actually opened, counted off the book.
        --
        -- delta_sell_entry returns a description, and the old code read "it
        -- returned something" as "the window is fully entered". It is not: a
        -- narrow premium range on a thin chain routinely fills one pair of three,
        -- and the stamps below then closed the window to any further entry for
        -- the rest of its life. The number is what the top-up branch works from,
        -- so it is measured rather than assumed — distinct short strikes per
        -- side, before and against after, and the smaller of the two moves.
        select count(distinct symbol) filter (where contract_type = 'call_options'),
               count(distinct symbol) filter (where contract_type = 'put_options')
          into v_c1, v_p1
        from public.positions
        where account_id = r.account_id and net_qty < 0
          and contract_type in ('call_options', 'put_options')
          and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

        v_opened := greatest(0, least(coalesce(v_c1, 0) - coalesce(v_c0, 0),
                                      coalesce(v_p1, 0) - coalesce(v_p0, 0)));

        update public.delta_strategy_settings
        set entered_day = v_day,
            flattened_day = null,
            -- 0069: the window that opened the book owns it until it is flat.
            open_window_id = v_win_id,
            shifts_used_call = 0, shifts_used_put = 0,
            reentries_used_call = 0, reentries_used_put = 0,
            pairs_open = v_opened,
            entered_window_ids = case when v_win_id is not null and not (v_win_id = any(entered_window_ids))
                                      then array_append(entered_window_ids, v_win_id)
                                      else entered_window_ids end
        where account_id = r.account_id;

        perform public.delta_reason(r.account_id, 'entry', v_spot, v_dp);
        raise log 'apply_delta_strategy: account % opened window % — % of % pair(s) — %',
          r.account_id, coalesce(v_win_id, 'default'), v_opened,
          case when v_mode = 'futures' then v_pairs else 1 end, v_desc;
        v_n := v_n + 1;
        continue;
      else
        raise log 'apply_delta_strategy: account % entry did not fill, continuing cycle', r.account_id;
      end if;

    -- ---- Top up an entry that only partly filled ---------------------------
    -- 0070: the window asked for N pairs and got fewer, so keep asking.
    --
    -- delta_sell_entry opens as many of the N as the chain can price *at that
    -- moment*, and since 0069 made the premium range a hard range, "fewer than
    -- N" is the ordinary case rather than the exception: on a thin 0DTE chain a
    -- $2-wide band may hold one strike with a live bid per side, and the other
    -- two pairs simply do not exist yet. Ten minutes later they do.
    --
    -- The old code could not act on that. A non-null description stamped the
    -- window as entered, and the entry branch above is gated on the window not
    -- being entered, so one pair of three was the window's final answer. The
    -- reported symptom -- "positions hain par pair nahi aaya" -- is exactly this.
    --
    -- Three things keep this from becoming a second way to over-sell:
    --
    --   * `pairs_open` counts pairs this window *opened*, and is never
    --     decremented by the ATM rules. A leg closed and not replaced is the
    --     re-entry budget's business, not this branch's; without that separation
    --     a spent re-entry budget would be silently refilled from here.
    --   * delta_sell_entry skips strikes already short on this expiry, so a
    --     top-up adds pairs at new strikes rather than deepening the ones held.
    --   * The margin brake below. A top-up runs on a live book, unlike the
    --     opening entry, and adding pairs up to the cut line only to have the
    --     margin guard cut them back next cycle is a loop, not a strategy.
    elsif v_mode = 'futures'
          and s.open_window_id is not null
          and s.open_window_id = v_win_id
          and coalesce(s.pairs_open, 0) < v_pairs
          and s.entered_day = v_day then

      v_brake := false;

      if v_margin_cap > 0 then
        select margin, equity into v_margin, v_equity
        from public.delta_account_margin(r.account_id, v_spot);
        -- At or past the cut-to line there is no headroom worth spending on a
        -- pair. Measured against the target rather than the cap so the top-up
        -- stops short of the guard instead of trading into it.
        if coalesce(v_equity, 0) > 0
           and coalesce(v_margin, 0) >= (v_margin_tgt / 100.0) * v_equity then
          v_brake := true;
        end if;
      end if;

      if not v_brake then
        v_dp := public.delta_book_dp(r.account_id);

        select count(distinct symbol) filter (where contract_type = 'call_options'),
               count(distinct symbol) filter (where contract_type = 'put_options')
          into v_c0, v_p0
        from public.positions
        where account_id = r.account_id and net_qty < 0
          and contract_type in ('call_options', 'put_options')
          and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

        v_desc := public.delta_sell_entry(
          r.account_id, r.user_id, v_exp, v_entry_prem,
          v_prem_min, v_tie_break, v_qty, v_spot,
          v_notional_cap,
          v_pairs - coalesce(s.pairs_open, 0),
          v_prem_max
        );

        if v_desc is not null then
          select count(distinct symbol) filter (where contract_type = 'call_options'),
                 count(distinct symbol) filter (where contract_type = 'put_options')
            into v_c1, v_p1
          from public.positions
          where account_id = r.account_id and net_qty < 0
            and contract_type in ('call_options', 'put_options')
            and coalesce(expiry_label, split_part(symbol, '-', 4)) = v_exp;

          v_opened := greatest(0, least(coalesce(v_c1, 0) - coalesce(v_c0, 0),
                                        coalesce(v_p1, 0) - coalesce(v_p0, 0)));

          if v_opened > 0 then
            update public.delta_strategy_settings
            set pairs_open = coalesce(pairs_open, 0) + v_opened
            where account_id = r.account_id;

            perform public.delta_reason(r.account_id, 'entry_top_up', v_spot, v_dp);
            raise log 'apply_delta_strategy: account % topped window % up to % of % pair(s) — %',
              r.account_id, coalesce(v_win_id, 'default'),
              coalesce(s.pairs_open, 0) + v_opened, v_pairs, v_desc;
            v_n := v_n + 1;
            continue;
          end if;
        end if;
      end if;

      -- Nothing opened. No log line: this branch runs every cycle for as long as
      -- the range holds no second strike, and a line per cycle would bury the
      -- ones that mean something. The panel carries it instead, as "Pairs 1 / 3".

    elsif (v_win_id is not null and not (v_win_id = any(s.entered_window_ids)))
          or (s.entered_day is distinct from v_day) then
      -- The stamps say this window has not opened a book, and yet one is open.
      -- Worth a line every cycle it lasts: it is either a leg the close could not
      -- buy back, or a position opened by hand on the strategy's own account, and
      -- both are things somebody has to look at. The entry stays refused either
      -- way -- selling a second strangle over the top is not the recovery.
      select count(*), string_agg(symbol, ', ') into v_legs, v_unpriced
      from public.positions
      where account_id = r.account_id and net_qty < 0
        and contract_type in ('call_options', 'put_options');

      raise log 'apply_delta_strategy: account % window % has not entered, but % short leg(s) are open: % — entry refused',
        r.account_id, coalesce(v_win_id, 'default'), v_legs, coalesce(v_unpriced, '?');
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

        -- 0069: the book is gone, so the window no longer owns one. The entry
        -- stamps stay put: a wing that emptied past the re-entry budget is a
        -- window that is done trading, not one to re-open.
        update public.delta_strategy_settings
        set open_window_id = null, touched_symbols = '{}', pass_open = false,
            pairs_open = 0
        where account_id = r.account_id;

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
        v_reent_used := case when v_rollside = 'call' then coalesce(s.reentries_used_call, 0)
                             else coalesce(s.reentries_used_put, 0) end;
        v_dp := public.delta_book_dp(r.account_id);

        -- 0069: the exit is the whole leg. Always.
        --
        -- It used to be `least(abs(net_qty), v_pick.room_lots)` -- the exit sized
        -- by how much room the *replacement* strike had left under the per-strike
        -- notional cap. So on a strike near its cap the engine bought back part of
        -- the ATM leg and left the rest sitting in the money, which is the one
        -- position this rule exists to not hold; on a strike with room it closed
        -- the lot. Same trigger, same book, two different outcomes decided by a
        -- cap that has nothing to do with the leg being exited.
        --
        -- The cap belongs to the strike being sold, so it sizes the replacement
        -- and nothing else. A replacement that can only take part of the size is
        -- a smaller replacement, never a smaller exit.
        v_exit_q := abs(v_leg.net_qty)::int;

        v_before := coalesce((select net_qty from public.positions
                              where account_id = r.account_id and symbol = v_leg.symbol), 0);
        perform public.delta_buy_back(r.account_id, r.user_id, v_leg.symbol, v_exit_q, v_spot);
        v_after  := coalesce((select net_qty from public.positions
                              where account_id = r.account_id and symbol = v_leg.symbol), 0);

        -- delta_close_leg returns normally on a leg the chain cannot price, so a
        -- replacement sold on the assumption the exit landed would double the
        -- side rather than move it. The position is the only proof.
        if v_after <= v_before then
          raise log 'apply_delta_strategy: account % ATM exit on % did not fill — left for the next cycle',
            r.account_id, v_leg.symbol;
          exit;
        end if;

        update public.delta_strategy_settings
        set touched_symbols = array_append(touched_symbols, v_leg.symbol)
        where account_id = r.account_id;

        -- Tier 1 -- the shift: same side, further out, at shiftPct of the price
        -- the exit paid. No premium range on this one: the shift's target is
        -- derived from the exit, which is what shiftPct means.
        v_shifted := false;
        if v_used < v_max_shifts then
          select * into v_pick from public.delta_pick_premium(
            v_exp, v_leg.contract_type,
            v_leg.mark * (v_shift_pct / 100.0),
            0, v_tie_break, v_leg.strike, r.account_id, v_notional_cap, v_spot, 0
          );

          if v_pick.symbol is not null then
            v_q := least(v_exit_q, coalesce(v_pick.room_lots, v_exit_q));
            if v_q > 0 then
              perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set shifts_used_call = case when v_rollside = 'call' then shifts_used_call + 1 else shifts_used_call end,
                  shifts_used_put  = case when v_rollside = 'put'  then shifts_used_put  + 1 else shifts_used_put  end
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'shift', v_spot, v_dp, v_pick.strike);
              raise log 'apply_delta_strategy: account % ATM exit on % (% lots) shifted to % (% lots)',
                r.account_id, v_leg.symbol, v_exit_q, v_pick.symbol, v_q;
              v_shifted := true;
            end if;
          end if;
        end if;

        -- Tier 2 -- the re-entry: the shift budget is spent, or nothing further
        -- out could be priced. Sell the side back on at the window's own entry
        -- premium range rather than leave the wing empty.
        --
        -- Without this the full exit was the end of the book: one empty wing, and
        -- the empty-side rule above flattens the whole thing on the next cycle --
        -- while entered_day and entered_window_ids still say this window has
        -- traded, so nothing re-opens until the next window or the next session.
        -- An ATM exit that shifted carried on; one that closed in full stood the
        -- book down for the rest of the window. Same rule, two outcomes, which is
        -- what "does not consistently re-enter" was.
        --
        -- p_beyond => v_spot is the entry's own test: strictly out of the money,
        -- so the replacement cannot be ATM the moment it is sold. The premium
        -- range is the window's, and it is a hard range now -- a wing with nothing
        -- quoted inside it is not re-opened at any price, and the empty-side
        -- flatten takes the book instead. That is the right answer when a side
        -- cannot be sold on the terms it was set.
        if not v_shifted and v_reent_used < v_max_reent then
          select * into v_pick from public.delta_pick_premium(
            v_exp, v_leg.contract_type, v_entry_prem, v_prem_min,
            v_tie_break, v_spot, r.account_id, v_notional_cap, v_spot, v_prem_max
          );

          if v_pick.symbol is not null then
            v_q := least(v_exit_q, coalesce(v_pick.room_lots, v_exit_q));
            if v_q > 0 then
              perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);

              update public.delta_strategy_settings
              set reentries_used_call = case when v_rollside = 'call' then reentries_used_call + 1 else reentries_used_call end,
                  reentries_used_put  = case when v_rollside = 'put'  then reentries_used_put  + 1 else reentries_used_put  end
              where account_id = r.account_id;

              perform public.delta_reason(r.account_id, 'reentry', v_spot, v_dp, v_pick.strike);
              raise log 'apply_delta_strategy: account % ATM exit on % (% lots) re-entered at % (% lots, % of % used)',
                r.account_id, v_leg.symbol, v_exit_q, v_pick.symbol, v_q,
                v_reent_used + 1, v_max_reent;
              v_shifted := true;
            end if;
          end if;
        end if;

        if not v_shifted then
          perform public.delta_reason(r.account_id, 'atm_exit', v_spot, v_dp);
          raise log 'apply_delta_strategy: account % ATM exit on % closed % lot(s) in full — nothing to sell back (shifts % of %, re-entries % of %)',
            r.account_id, v_leg.symbol, v_exit_q, v_used, v_max_shifts, v_reent_used, v_max_reent;
        end if;

        v_acted := true;
        v_n := v_n + 1;
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
-- Resolve every name at apply time, and prove the rule is in force
-- ---------------------------------------------------------------------------
do $$
declare
  v_eng   text;
  v_entry text;
  v_pick  text;
  v_n     int;
begin
  select pr.prosrc into v_eng from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'apply_delta_strategy';
  select pr.prosrc into v_entry from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_sell_entry';
  select pr.prosrc into v_pick from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_pick_premium_ranked';

  -- 1. A futures book no longer carries an entry premium into the picker.
  if v_eng not like '%v_entry_prem := 0;%' then
    raise exception 'a futures book still ranks against an entry premium';
  end if;

  -- 2. And does not enter at all without a range to rank inside.
  if v_eng not like '%v_has_range%' then
    raise exception 'the missing-range guard is not there';
  end if;
  if v_eng not like '%if v_mode = ''futures'' and not v_has_range then%' then
    raise exception 'the missing-range guard does not gate the entry chain';
  end if;

  -- 3. The delta book keeps its entry premium — the roll and the band correction
  --    are the only price rule it has.
  if v_eng not like '%s.entry_premium%' then
    raise exception 'the delta book lost its entry premium too';
  end if;

  -- Carried forward from 0071, 0070 and 0069.
  if v_eng not like '%pairs_open = greatest(coalesce(pairs_open, 0), v_opened)%' then
    raise exception 'the pairs_open reconciliation is gone (0071)';
  end if;
  if v_eng not like '%entry_top_up%' or v_eng not like '%v_brake%' then
    raise exception 'the top-up branch or its margin brake is gone (0070)';
  end if;
  if v_entry not like '%where not exists (select 1 from public.positions po%' then
    raise exception 'delta_sell_entry no longer skips strikes it already holds (0070)';
  end if;
  if v_pick not like '%ceil_val <= 0 or c.best_bid <= b.ceil_val%' then
    raise exception 'the premium ceiling filter is gone (0069)';
  end if;
  if v_eng not like '%v_exit_q := abs(v_leg.net_qty)::int;%' then
    raise exception 'the ATM exit no longer closes the whole leg (0069)';
  end if;
  if v_eng not like '%open_window_id is distinct from v_win_id%' then
    raise exception 'the window handover flatten is missing (0069)';
  end if;
  if v_eng not like '%stale_expiry_exit%' then
    raise exception 'the stale-expiry close is missing (0069)';
  end if;
  if v_eng like '%if s.flattened_day is distinct from v_day%' then
    raise exception 'the session flatten is gated on its own stamp again (0069)';
  end if;
  if v_eng not like '%reentries_used_call%' or v_eng not like '%v_max_reent%' then
    raise exception 'the ATM re-entry tier is missing (0069)';
  end if;
  if position('(now() at time zone ''Asia/Kolkata'')::date' in v_eng) > 0 then
    raise exception 'apply_delta_strategy counts an expiry from the calendar date again';
  end if;
  if position('v_day::date' in v_eng) = 0 then
    raise exception 'apply_delta_strategy does not anchor the expiry on the session day';
  end if;
  if position('interval ''16 hours''' in v_eng) = 0 then
    raise exception 'apply_delta_strategy lost the 16-hour expiry liveness filter';
  end if;
  if v_eng ~* 'max\s*\(\s*spot_price\s*\)' then
    raise exception 'apply_delta_strategy derives spot from max(spot_price) again';
  end if;
  if v_eng ~* '(from|join)[[:space:]]+[a-z_."]+[[:space:]]+(as[[:space:]]+)?(r|s)\M' then
    raise exception 'apply_delta_strategy aliases a table "r" or "s"';
  end if;

  perform public.delta_session_window('[]'::jsonb, array[1,2,3,4,5,6,7]::smallint[]);
  perform 1 from public.delta_pick_premium_ranked('010101', 'call_options', 0, 2, 'closest',
                                                  null, null, 0, null, 5, 3);

  raise log '0072: on a futures book the premium range is the entry rule';
end;
$$;

-- And prove on data that a zero entry premium ranks the richest in-range strike
-- first, which is the behaviour the removed control used to supply by hand.
do $$
declare
  v_first numeric;
  v_n     int;
begin
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, best_bid, best_ask, delta, gamma,
                                  spot_price, mark_price)
  values ('C-XAUT-4100-072CHK', 'call_options', 4100, '072CHK', 0.001, 4.80, 4.90, 0.30, 0.001, 4000, 4.85),
         ('C-XAUT-4200-072CHK', 'call_options', 4200, '072CHK', 0.001, 3.50, 3.60, 0.20, 0.001, 4000, 3.55),
         ('C-XAUT-4300-072CHK', 'call_options', 4300, '072CHK', 0.001, 1.20, 1.30, 0.10, 0.001, 4000, 1.25),
         ('C-XAUT-4050-072CHK', 'call_options', 4050, '072CHK', 0.001, 7.90, 8.00, 0.40, 0.001, 4000, 7.95)
  on conflict (symbol) do nothing;

  -- Range $3-$5, no entry premium. The $7.90 and the $1.20 are out; of the two
  -- left, the $4.80 must rank first.
  select count(*) into v_n
  from public.delta_pick_premium_ranked('072CHK', 'call_options', 0, 3, 'closest',
                                        4000, null, 0, null, 5, 10);
  select premium into v_first
  from public.delta_pick_premium_ranked('072CHK', 'call_options', 0, 3, 'closest',
                                        4000, null, 0, null, 5, 10)
  where rank = 1;

  delete from public.delta_chain where expiry_label = '072CHK';

  if v_n <> 2 then
    raise exception 'expected 2 strikes inside $3-$5, got %', v_n;
  end if;
  if v_first <> 4.80 then
    raise exception 'expected the richest in-range strike ($4.80) to rank first, got %', v_first;
  end if;

  raise log '0072: a $3-$5 range with no entry premium ranks $4.80 first, then $3.50';
end;
$$;
