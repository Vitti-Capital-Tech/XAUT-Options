-- 0069_one_window_one_book.sql
--
-- Run this whole file in the Supabase SQL Editor after 0068.
--
-- Three reported faults on the futures book, and they share two causes.
--
--   * Entries land outside the premium range, some of them far above it.
--   * ATM exits close some legs in full and others in part, and a leg closed in
--     full stands the book down for the rest of the window instead of re-entering.
--   * More than one expiry is open at a time, so the entry and exit rules are
--     being applied across contracts they were not computed for.
--
-- ---------------------------------------------------------------------------
-- 1. The premium range was never a range
-- ---------------------------------------------------------------------------
--
-- delta_pick_premium_ranked takes p_floor and p_ceil and treats them as
-- different kinds of thing. The floor is a hard filter:
--
--     and (b.floor_val <= 0 or c.best_bid >= b.floor_val)
--
-- The ceiling has no filter at all. p_ceil only ever supplied a ranking target,
-- and only when p_entry was 0 -- so with an entry premium set, which is the
-- normal configuration, the maximum was read from the window, passed down two
-- function calls, and then ignored. The picker ranked every strike by distance
-- from the target and took the nearest, however rich.
--
-- With Pairs > 1 it compounds: ranks 2..N are by construction further from the
-- target than rank 1, so the extra pairs are exactly the legs furthest outside
-- the range. That is the "multiple entries in parallel, including entries at
-- prices significantly above the intended range" in one sentence -- one entry of
-- N pairs, the later ones badly out of range.
--
-- The panel calls the field "Premium range (Min - Max). Set 0 for no limit", so
-- the ceiling is now a filter on the same terms as the floor. The target is
-- clamped into the range as well: an entry premium set above the maximum used to
-- drag the ranking up past it, and now lands on the richest strike inside it.
--
-- A side with nothing quoted inside the range opens nothing, which is already
-- what the floor does. Half a pair is a directional position this strategy never
-- intends to hold, and delta_sell_entry's inner join means an empty side on
-- either wing opens neither.
--
-- ---------------------------------------------------------------------------
-- 2. Two expiries, from two entries, from three routes into one branch
-- ---------------------------------------------------------------------------
--
-- 0068 fixed the expiry *rule* drifting off its session day. It did not stop the
-- book holding two expiries at once, because the entry was never gated on the
-- book being empty -- only on stamps describing what the engine believed it had
-- already done.
--
--   a. Window handover. delta_session_window reports phase 'open' continuously
--      across back-to-back windows and simply changes which one governs (0066),
--      and the end minute is inclusive -- 09:00-12:00 and 12:00-16:00 are both
--      open at 12:00, and the later-starting one wins. The close-flatten only
--      runs when the phase is not 'open', so it never ran between them: window B
--      entered on top of window A's live book, and since every window resolves
--      its own daysToExpiry, that entry was on a different contract by
--      construction.
--
--   b. Adoption. A book left open at the start of a session was adopted, which
--      stamped entered_day -- but the entry's other arm, "this window is not in
--      entered_window_ids", was still true, so it entered anyway, on top of what
--      it had just adopted. The adopt test was unscoped too, so a book on last
--      session's contract satisfied it.
--
--   c. A close that did not close. delta_close_leg needs an ask, and the chain
--      drops any row the venue stopped quoting two minutes ago. The session
--      flatten stamped flattened_day whether or not the book went flat, and was
--      gated on that same stamp, so no later cycle came back for what was left.
--      The remainder ran into the next session to be adopted there.
--
-- So the entry now tests the state that matters -- no short option leg open --
-- rather than inferring it from the stamps, and three things keep that state
-- true: a flatten when the governing window changes, a close of any leg on a
-- contract this window is not trading, and a session flatten that only claims
-- the day once the book is actually flat.
--
-- open_window_id is the new column behind the first of those: the window that
-- owns whatever is open, stamped by the entry and cleared by every flatten. Null
-- is left alone -- a book with no owning window is one a person opened, and
-- flattening it on sight would be this engine liquidating a position it never
-- placed.
--
-- The shift and re-entry budgets now reset at each handover as well. They are
-- read off the window (0061 made every filter per-window), and a per-window
-- allowance drawn from a per-day counter is not an allowance: window B asking
-- for two shifts would find window A had spent them.
--
-- ---------------------------------------------------------------------------
-- 3. The ATM exit, and what happens after it
-- ---------------------------------------------------------------------------
--
-- The exit was sized as
--
--     v_q := least(abs(v_leg.net_qty), coalesce(v_pick.room_lots, ...))
--
-- where room_lots is how much of the *replacement* strike is left under the
-- per-strike notional cap. So the size of the exit was decided by a cap on a
-- different strike: near its cap, part of the ATM leg was bought back and the
-- rest left in the money -- the one position this rule exists to not hold; with
-- room, the whole leg went. Same trigger, two outcomes.
--
-- The exit is now always the whole leg, and the cap sizes only the strike being
-- sold. The buy-back is also checked against the position rather than assumed:
-- delta_close_leg returns normally on a leg it cannot price, and a replacement
-- sold on the assumption the exit landed doubles the side instead of moving it.
--
-- After a full exit with no shift left, the side used to be left empty -- and
-- the empty-wing rule then flattens the book on the next cycle, while the entry
-- stamps still say this window has traded, so nothing re-opens until the next
-- window. An exit that shifted carried on; an exit that closed in full ended the
-- window. That is the inconsistency reported, and the fix is a second tier: sell
-- the side back on at the window's own entry premium range, out of the money,
-- bounded by max_reentries per side per window.
--
-- ---------------------------------------------------------------------------
-- What this does not change
-- ---------------------------------------------------------------------------
--
--   * The delta book. Everything above is inside `if v_mode = 'futures'` or is
--     an entry path an options book reaches with p_ceil 0 and a single window.
--   * The hedge, the band, the margin guard, and the roll: untouched.
--   * A futures book with no schedule windows. v_win_id is the constant
--     'default' there, so the handover branch never fires.
--   * The shift's own target. shiftPct is a percentage of the exit price, not a
--     premium range, so the shift pick still passes p_ceil 0.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
alter table public.delta_strategy_settings
  add column if not exists max_reentries       integer not null default 1,
  add column if not exists reentries_used_call integer not null default 0,
  add column if not exists reentries_used_put  integer not null default 0,
  add column if not exists open_window_id      text;

alter table public.delta_strategy_settings drop constraint if exists delta_max_reentries_chk;
alter table public.delta_strategy_settings
  add constraint delta_max_reentries_chk check (max_reentries >= 0);

comment on column public.delta_strategy_settings.max_reentries is
  'ATM re-entries allowed per side per window, once the shift budget is spent. 0 = never re-enter.';
comment on column public.delta_strategy_settings.reentries_used_call is
  'ATM re-entries used on the call side by the window currently holding the book.';
comment on column public.delta_strategy_settings.reentries_used_put is
  'ATM re-entries used on the put side by the window currently holding the book.';
comment on column public.delta_strategy_settings.open_window_id is
  'The schedule window that opened the book currently on the table; null when flat or hand-opened.';

-- ---------------------------------------------------------------------------
-- 2. The premium range, as a range
-- ---------------------------------------------------------------------------
create or replace function public.delta_pick_premium_ranked(
  p_exp     text,
  p_kind    text,
  p_entry   numeric,
  p_floor   numeric,
  p_tie     text,
  p_beyond  numeric,
  p_account uuid    default null,
  p_cap     numeric default 0,
  p_spot    numeric default null,
  p_ceil    numeric default 0,
  p_limit   int     default 1
)
returns table (rank int, symbol text, strike numeric, premium numeric,
               delta numeric, room_lots int)
language sql
stable
as $$
  with raw as (
    -- Both bounds normalised before either is used, so a range entered the wrong
    -- way round is still the range between the two numbers.
    select case when p_floor > 0 and p_ceil > 0 then least(p_floor, p_ceil)
                when p_floor > 0 then p_floor
                else 0 end as floor_val,
           case when p_floor > 0 and p_ceil > 0 then greatest(p_floor, p_ceil)
                when p_ceil > 0 then p_ceil
                else 0 end as ceil_val
  ),
  bounds as (
    select b.floor_val,
           b.ceil_val,
           -- 0069: the target is clamped into the range rather than allowed to
           -- drag the ranking outside it. An entry premium of $6 against a 2-4
           -- range now lands on the richest strike at or under $4, where before
           -- it ranked by distance from $6 and the ceiling did nothing at all.
           case
             when p_entry > 0 then
               least(greatest(p_entry, b.floor_val),
                     case when b.ceil_val > 0 then b.ceil_val else p_entry end)
             when b.ceil_val > 0  then b.ceil_val
             when b.floor_val > 0 then b.floor_val
             else 0
           end as target_val
    from raw b
  ),
  priced as (
    select c.symbol, c.strike, c.best_bid as premium, c.delta, c.contract_value,
           coalesce(abs(pos.net_qty), 0) as held
    from public.delta_chain c
    cross join bounds b
    left join public.positions pos
           on pos.account_id = p_account and pos.symbol = c.symbol
    where c.expiry_label = p_exp
      and c.contract_type = p_kind
      and c.best_bid is not null
      and c.delta is not null
      -- Hard floor: at or above the minimum premium.
      and (b.floor_val <= 0 or c.best_bid >= b.floor_val)
      -- 0069: hard ceiling, on the same terms. This is the whole fix for entries
      -- landing above the range -- everything else in this function was already
      -- ranking correctly, it was simply ranking over strikes that should never
      -- have been candidates. Callers that mean "no ceiling" pass 0, which is
      -- every caller but the entry and the ATM re-entry.
      and (b.ceil_val <= 0 or c.best_bid <= b.ceil_val)
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
    select c.*, 0 as pri, c.premium - b.target_val as nearness
    from open_strikes c
    cross join bounds b
    where p_tie = 'above' and c.premium >= b.target_val
    union all
    select c.*, 0, b.target_val - c.premium
    from open_strikes c
    cross join bounds b
    where p_tie = 'below' and c.premium <= b.target_val
    union all
    select c.*, 1, abs(c.premium - b.target_val)
    from open_strikes c
    cross join bounds b
  ),
  best as (
    select distinct on (k.symbol) k.*
    from ranked k
    order by k.symbol, k.pri asc, k.nearness asc
  )
  select (row_number() over (order by b.pri asc, b.nearness asc))::int,
         b.symbol, b.strike, b.premium, b.delta, b.room_lots
  from best b
  order by b.pri asc, b.nearness asc
  limit greatest(1, coalesce(p_limit, 1));
$$;
revoke all on function public.delta_pick_premium_ranked(
  text, text, numeric, numeric, text, numeric, uuid, numeric, numeric, numeric, int)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reasons for the three new actions
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
    when 'shift'              then 'ATM reached — shifted further out'
    when 'atm_exit'           then 'ATM reached — closed position'
    -- 0069: the side sold back on at the entry premium range after a full ATM
    -- exit, and the two flattens that keep the book to one window's one expiry.
    when 'reentry'            then 'ATM exit — re-entered in the premium range'
    when 'window_handover'    then 'Window handover — flattened the previous window''s book'
    when 'stale_expiry_exit'  then 'Not the traded expiry — closed'
    when 'empty_side_flatten' then 'Wing empty — closed all positions'
    when 'band'               then 'Fresh sell — band correction'
    when 'hedge_buy'          then 'Bought futures — band breach'
    when 'hedge_sell'         then 'Sold futures — band breach'
    when 'futures_hedge'      then (case when coalesce(p_dp_before, 0) < coalesce(p_dp_target, 0) then 'Bought futures — band breach' else 'Sold futures — band breach' end)
    when 'hedge'              then (case when coalesce(p_dp_before, 0) < coalesce(p_dp_target, 0) then 'Bought futures — band breach' else 'Sold futures — band breach' end)
    when 'delta_exit'         then 'No margin to hedge — closed the leg driving Δp, loss booked'
    when 'cut'                then 'Margin cut — loss booked'
    when 'flatten'            then 'Session close — flattened'
    when 'take_profit'        then 'Take-profit hit'
    when 'stop_loss'          then 'Stop-loss hit'
    else 'Action: ' || coalesce(p_action, '')
  end;

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
    and created_at >= now() - interval '10 seconds'
    and (case when contract_type = 'perpetual_futures'
              then true
              else side = 'buy' or realized_pnl <> 0 end);

  update public.positions
  set entry_reason = v_line
  where account_id = p_account
    and entry_reason is null
    and opened_at >= now() - interval '10 seconds';
end;
$$;
revoke all on function public.delta_reason(uuid, text, numeric, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The engine
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

    if s.session_day is distinct from v_day then
      update public.delta_strategy_settings
      set session_day = v_day, rolls_used_call = 0, rolls_used_put = 0,
          shifts_used_call = 0, shifts_used_put = 0,
          reentries_used_call = 0, reentries_used_put = 0,
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
              open_window_id = null
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
          set open_window_id = null, touched_symbols = '{}', pass_open = false
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
          reentries_used_call = 0, reentries_used_put = 0
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
      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null,
          open_window_id = coalesce(open_window_id, v_win_id),
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
    if ((v_win_id is not null and not (v_win_id = any(s.entered_window_ids)))
        or (s.entered_day is distinct from v_day))
       and not exists (select 1 from public.positions
                       where account_id = r.account_id
                         and net_qty < 0
                         and contract_type in ('call_options', 'put_options')) then
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
            -- 0069: the window that opened the book owns it until it is flat.
            open_window_id = v_win_id,
            shifts_used_call = 0, shifts_used_put = 0,
            reentries_used_call = 0, reentries_used_put = 0,
            entered_window_ids = case when v_win_id is not null and not (v_win_id = any(entered_window_ids))
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
        set open_window_id = null, touched_symbols = '{}', pass_open = false
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
-- 5. Resolve every name at apply time, and prove each rule is actually in force
-- ---------------------------------------------------------------------------
-- The convention since 0056: plpgsql resolves names on first *execution*, so a
-- migration that applies cleanly can still die hours later on a branch that had
-- not run yet. Each check below is written against the behaviour, not the
-- wording, wherever a query can express it.
do $$
declare
  v_eng text;
  v_pick text;
  v_n   int;
begin
  select pr.prosrc into v_eng from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'apply_delta_strategy';
  select pr.prosrc into v_pick from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_pick_premium_ranked';

  -- 1. The ceiling is a filter, not a ranking hint.
  if v_pick not like '%ceil_val <= 0 or c.best_bid <= b.ceil_val%' then
    raise exception 'delta_pick_premium_ranked still has no ceiling filter';
  end if;

  -- 2. The exit is never sized by the replacement's room again.
  if v_eng like '%least(abs(v_leg.net_qty), coalesce(v_pick.room_lots%' then
    raise exception 'the ATM exit is still sized by the replacement strike''s cap room';
  end if;
  if v_eng not like '%v_exit_q := abs(v_leg.net_qty)::int;%' then
    raise exception 'the ATM exit no longer closes the whole leg';
  end if;

  -- 3. The entry is gated on the book, not only on the stamps.
  if v_eng not like '%and not exists (select 1 from public.positions%' then
    raise exception 'the entry no longer checks that the option book is empty';
  end if;

  -- 4. The three rules that keep one window to one book.
  if v_eng not like '%open_window_id is distinct from v_win_id%' then
    raise exception 'the window handover flatten is missing';
  end if;
  if v_eng not like '%stale_expiry_exit%' then
    raise exception 'the stale-expiry close is missing';
  end if;
  if v_eng like '%if s.flattened_day is distinct from v_day%' then
    raise exception 'the session flatten is gated on its own stamp again';
  end if;

  -- 5. And the re-entry tier, with a budget to bound it.
  if v_eng not like '%reentries_used_call%' or v_eng not like '%v_max_reent%' then
    raise exception 'the ATM re-entry tier is missing';
  end if;

  -- Carried forward from 0060, 0062, 0067 and 0068 -- every one of these was a
  -- live incident, and none of them may come back through a copied engine.
  if position('(now() at time zone ''Asia/Kolkata'')::date' in v_eng) > 0 then
    raise exception 'apply_delta_strategy still counts an expiry from the calendar date';
  end if;
  if position('(now() at time zone ''UTC'')::date' in v_eng) > 0 then
    raise exception 'apply_delta_strategy has gone back to the UTC date (0067)';
  end if;
  if position('v_day::date' in v_eng) = 0 then
    raise exception 'apply_delta_strategy does not anchor the expiry on the session day';
  end if;
  if v_eng not like '%delta_session_window%' or v_eng not like '%delta_session(%' then
    raise exception 'apply_delta_strategy no longer resolves a session day to anchor on';
  end if;
  if position('interval ''16 hours''' in v_eng) = 0 then
    raise exception 'apply_delta_strategy lost the 16-hour expiry liveness filter';
  end if;
  if v_eng ~* 'max\s*\(\s*spot_price\s*\)' then
    raise exception 'apply_delta_strategy still derives spot from max(spot_price)';
  end if;
  if v_eng ~* '(from|join)[[:space:]]+[a-z_."]+[[:space:]]+(as[[:space:]]+)?(r|s)\M' then
    raise exception 'apply_delta_strategy aliases a table "r" or "s"';
  end if;
  if v_eng not like '%marginCapPct%' or v_eng not like '%daysToExpiry%' then
    raise exception 'apply_delta_strategy no longer reads the window overrides 0061/0062 added';
  end if;

  -- Resolve the signatures the engine calls, now rather than mid-session.
  perform public.delta_session_window('[]'::jsonb, array[1,2,3,4,5,6,7]::smallint[]);
  perform 1 from public.delta_pick_premium_ranked('010101', 'call_options', 4, 2, 'closest',
                                                  null, null, 0, null, 6, 3);
  perform 1 from public.delta_pick_premium('010101', 'call_options', 4, 2, 'closest',
                                           null, null, 0, null, 6);

  raise log '0069: one window, one book, one expiry — and the premium range is a range';
end;
$$;

-- And prove the ceiling on data rather than on the source, with a row that only
-- a working filter excludes: a $9 strike in a 2-4 range. The chain is real, so
-- this uses a label no expiry can collide with and cleans up after itself.
do $$
declare
  v_n int;
begin
  insert into public.delta_chain (symbol, contract_type, strike, expiry_label,
                                  contract_value, best_bid, best_ask, delta, gamma,
                                  spot_price, mark_price)
  values ('C-XAUT-9999-069CHK', 'call_options', 9999, '069CHK', 0.001, 9.00, 9.10, 0.2, 0.001, 4000, 9.05),
         ('C-XAUT-9998-069CHK', 'call_options', 9998, '069CHK', 0.001, 3.00, 3.10, 0.3, 0.001, 4000, 3.05)
  on conflict (symbol) do nothing;

  select count(*) into v_n
  from public.delta_pick_premium_ranked('069CHK', 'call_options', 4, 2, 'closest',
                                        null, null, 0, null, 4, 10);

  delete from public.delta_chain where expiry_label = '069CHK';

  if v_n <> 1 then
    raise exception 'the premium ceiling admitted % strikes where only the $3 one is in a 2-4 range', v_n;
  end if;

  raise log '0069: a $9 strike is no longer a candidate for a $2-$4 entry';
end;
$$;
