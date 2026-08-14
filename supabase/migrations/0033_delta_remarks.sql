-- 0033_delta_remarks.sql
--
-- Run this whole file in the Supabase SQL Editor after 0032_auto_window_edit_takes_effect_now.sql.
--
-- The delta engine could not say why it did anything.
--
-- Trade History records *what* it traded — symbol, side, price, realized P&L —
-- and the panel's `Next` line says what it is about to do. Between those two
-- there is nothing: a leg closed at 14:32 is a row with no reason beside it, and
-- by the time you read it the spot, the greeks and Δp that produced it are gone.
-- The engine did compute all three, said them in a `raise log`, and threw them
-- away — Postgres logs are not something a trader reads, and they are not scoped
-- to an account.
--
-- This stores that reasoning as it happens, one row per decision:
--
--   * the spot the decision was priced at,
--   * Δp when the book was checked, and the band it was checked against,
--   * where the correction was aiming (`dp_target`),
--   * Δp once the action had gone through (`dp_after`) — what the action actually
--     made, not what it intended,
--   * the leg and size, and a line of English saying why.
--
-- `dp_after` is the half that cannot be reconstructed later. It is measured
-- inside the same transaction and off the same chain snapshot as `dp_before`, so
-- the pair is a clean before/after of one action rather than two readings taken
-- at different prices.
--
-- ---------------------------------------------------------------------------
-- Decisions that are not trades
-- ---------------------------------------------------------------------------
-- The interesting question is often "why did it do *nothing* for an hour", so
-- the branches that decline to act are recorded too: an entry held back by
-- margin, a correction held back by margin, a Δp that cannot be trusted because
-- a greek has not arrived, an expiry that is no longer listed, no strike quoted
-- to correct with, a breach worth less than one contract.
--
-- Those repeat every cycle, which at 5 seconds is 720 rows an hour of the same
-- sentence. They are written `once`: skipped when the account's newest remark
-- already says exactly that. The row therefore reads as "this started here" and
-- the next remark below it is what changed. Actions are never deduplicated —
-- two identical rolls are two facts.
--
-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
-- Thirty days per account, trimmed on write. An action-only log on a 5-second
-- engine is a few hundred rows a day at most, and the dedupe above is what keeps
-- the non-action rows from being the bulk of it.

-- ---------------------------------------------------------------------------
-- 1. The log
-- ---------------------------------------------------------------------------
create table if not exists public.delta_remarks (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,

  -- What was decided. The six that trade, then the two that decline to.
  --   entry   — the session's opening pair
  --   roll    — partial exit of an ITM short, replaced further out
  --   exit    — full close, the side's roll budget spent (loss booked)
  --   band    — fresh OTM sell, nothing left to roll
  --   cut     — margin over the cap (loss booked)
  --   flatten — session close, or a day the strategy does not trade
  --   hold    — margin over cut-to: something was deliberately not done
  --   wait    — could not act: missing greek, unlisted expiry, no quote
  action      text not null,

  -- The market the decision was priced at.
  spot        numeric(20, 8),

  -- Δp when the book was checked, where the correction aimed, and where it
  -- landed. All three are nullable: a greek missing anywhere in the book makes Δp
  -- unknowable, and a margin cut or a flatten has no delta target at all.
  dp_before   numeric(20, 8),
  dp_target   numeric(20, 8),
  dp_after    numeric(20, 8),

  -- The band as it stood at that moment, so a remark still reads correctly after
  -- the band has been re-tuned.
  band_low    numeric(20, 8),
  band_high   numeric(20, 8),

  -- The leg acted on and the lots, where one leg was. Null for an entry (two
  -- legs, both named in the note) and for the branches that did nothing.
  symbol      text,
  qty         integer,

  note        text not null,
  created_at  timestamptz not null default now(),

  constraint delta_remarks_action_chk
    check (action in ('entry', 'roll', 'exit', 'band', 'cut', 'flatten', 'hold', 'wait'))
);

comment on table public.delta_remarks is
  'Why the delta engine acted: spot, Δp before and after, the band and target, and a line of English. Written by apply_delta_strategy; read-only to the trader.';

-- The one access pattern: this account's newest first, for the panel and for the
-- dedupe check below.
create index if not exists delta_remarks_account_idx
  on public.delta_remarks (account_id, created_at desc);

alter table public.delta_remarks enable row level security;

-- Read and clear, nothing else. Every row is written by the engine through a
-- security-definer function, so no client needs insert — and without update, a
-- remark cannot be edited after the fact, which is the whole value of a journal.
--
-- Delete is granted for one reason: resetting an account wipes its fills,
-- orders and positions, and a log left describing trades that no longer exist is
-- worse than no log. `reset_account` runs as the caller, so it needs the right.
drop policy if exists delta_remarks_owner on public.delta_remarks;
drop policy if exists delta_remarks_read on public.delta_remarks;
create policy delta_remarks_read on public.delta_remarks
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists delta_remarks_clear on public.delta_remarks;
create policy delta_remarks_clear on public.delta_remarks
  for delete to authenticated
  using (user_id = auth.uid());

grant select, delete on public.delta_remarks to authenticated;

-- Realtime, so a remark shows the moment the engine writes it rather than on the
-- next poll — the same treatment the settings row gets.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'delta_remarks'
  ) then
    alter publication supabase_realtime add table public.delta_remarks;
  end if;
end $$;

-- A reset clears the log with the rest of the book. Body is 0001's with one line
-- added; it still runs as the caller, so RLS scopes every delete to their own
-- rows and a bad id affects nothing.
create or replace function public.reset_account(p_account_id uuid)
returns void
language plpgsql
security invoker
as $$
begin
  delete from public.fills where account_id = p_account_id;
  delete from public.orders where account_id = p_account_id;
  delete from public.positions where account_id = p_account_id;
  -- The engine's reasoning belongs to the trades it explains: keeping it past a
  -- reset would leave a log describing a book that no longer exists.
  delete from public.delta_remarks where account_id = p_account_id;
  update public.accounts set cash_balance = starting_balance where id = p_account_id;
end;
$$;

grant execute on function public.reset_account(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Net portfolio delta for an account, as one callable
-- ---------------------------------------------------------------------------
-- The engine computed this inline in one place. It is now needed in four — the
-- flatten, the entry, the cut and every `dp_after` — so it becomes a function
-- rather than four copies that can drift apart.
--
-- Δp in qty (underlying) units, the unit the band is set in: net_qty counts venue
-- lots, so the lot-sized delta sum is scaled by the contract value. Null when any
-- open leg has no published greek — a partial sum is not a smaller truth here, it
-- is a wrong number, and every caller treats null as "cannot say".
--
-- A flat book is 0, not null: zero legs means zero missing greeks.
create or replace function public.delta_book_dp(p_account uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case
           when count(*) filter (where c.delta is null) > 0 then null::numeric
           else coalesce(sum(p.net_qty * c.delta), 0) * coalesce(max(p.contract_value), 1)
         end
  from public.positions p
  left join public.delta_chain c on c.symbol = p.symbol
  where p.account_id = p_account and p.net_qty <> 0;
$$;

revoke all on function public.delta_book_dp(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The writer
-- ---------------------------------------------------------------------------
-- Called immediately after the action it describes, so `dp_after` is read from
-- the book the action just left behind — same transaction, same chain snapshot,
-- same spot. The band is copied from the settings row rather than passed in, so
-- no caller can label a remark with a band that was not in force.
--
-- `p_once` is the dedupe for the branches that decline to act: skip when this
-- account's newest remark is already the same action with the same words.
create or replace function public.delta_remark(
  p_account   uuid,
  p_user      uuid,
  p_action    text,
  p_note      text,
  p_spot      numeric default null,
  p_dp_before numeric default null,
  p_dp_target numeric default null,
  p_symbol    text default null,
  p_qty       integer default null,
  p_once      boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last record;
  v_band record;
begin
  if p_once then
    select action, note into v_last
    from public.delta_remarks
    where account_id = p_account
    order by created_at desc, id desc
    limit 1;

    if found and v_last.action = p_action and v_last.note = p_note then
      return;
    end if;
  end if;

  select band_low, band_high into v_band
  from public.delta_strategy_settings
  where account_id = p_account;

  insert into public.delta_remarks (account_id, user_id, action, spot, dp_before,
                                    dp_target, dp_after, band_low, band_high,
                                    symbol, qty, note)
  values (p_account, p_user, p_action, p_spot, p_dp_before,
          p_dp_target, public.delta_book_dp(p_account), v_band.band_low, v_band.band_high,
          p_symbol, p_qty, p_note);

  delete from public.delta_remarks
  where account_id = p_account and created_at < now() - interval '30 days';
end;
$$;

revoke all on function public.delta_remark(uuid, uuid, text, text, numeric, numeric, numeric, text, integer, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. delta_sell_entry now says what it sold
-- ---------------------------------------------------------------------------
-- The body is 0024's, unchanged in what it does. Only the return value moves: it
-- was a leg count the caller compared against 2, and it is now a description of
-- the pair — `1 × 4200C @ $4.10 / 1 × 4000P @ $3.90` — or null when nothing
-- opened. The caller needs the strikes for the remark, and the alternative was
-- re-picking them afterwards and hoping the second pick matched the first.
--
-- Return type changes, so the old signature has to go rather than be replaced.
drop function if exists public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, numeric, numeric);

create or replace function public.delta_sell_entry(p_account uuid, p_user uuid, p_exp text,
                                                   p_entry numeric, p_floor numeric,
                                                   p_tie text, p_qty numeric, p_spot numeric)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  c        record;
  p        record;
  v_before numeric;
  v_after  numeric;
  v_lots_c int;
  v_lots_p int;
begin
  select * into c from public.delta_pick_premium(p_exp, 'call_options', p_entry, p_floor, p_tie, null);
  select * into p from public.delta_pick_premium(p_exp, 'put_options',  p_entry, p_floor, p_tie, null);

  -- Symmetric or not at all: half a pair is a directional position the strategy
  -- never intends to open.
  if c.symbol is null or p.symbol is null then
    raise log 'delta_sell_entry: no symmetric pair at or above the % floor', p_floor;
    return null;
  end if;

  -- XAUT to lots, per leg, off that contract's own value. A missing or zero
  -- contract_value falls back to one lot rather than sizing off a guess.
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_c from public.delta_chain where symbol = c.symbol;
  select greatest(1, coalesce(round(p_qty / nullif(contract_value, 0))::int, 1))
    into v_lots_p from public.delta_chain where symbol = p.symbol;

  if coalesce(v_lots_c, 0) <= 0 or coalesce(v_lots_p, 0) <= 0 then
    raise log 'delta_sell_entry: qty % sized to no lots', p_qty;
    return null;
  end if;

  -- One block, one implicit savepoint. delta_sell swallows a failed fill and
  -- returns normally, so a leg that did not open is detected by the position not
  -- moving and turned into an exception here — which unwinds everything this block
  -- did, including the other leg's fill.
  begin
    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    perform public.delta_sell(p_account, p_user, c.symbol, v_lots_c, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = c.symbol), 0);
    -- Selling makes net_qty more negative, so a fill moves this the other way.
    if v_before - v_after <= 0 then
      raise exception 'call leg % did not fill', c.symbol;
    end if;

    v_before := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    perform public.delta_sell(p_account, p_user, p.symbol, v_lots_p, p_spot);
    v_after  := coalesce((select net_qty from public.positions
                          where account_id = p_account and symbol = p.symbol), 0);
    if v_before - v_after <= 0 then
      raise exception 'put leg % did not fill', p.symbol;
    end if;
  exception when others then
    raise log 'delta_sell_entry: % — entry rolled back, nothing left open', sqlerrm;
    return null;
  end;

  return format('%s × %sC @ $%s / %s × %sP @ $%s',
                v_lots_c, round(c.strike, 0), round(c.premium, 2),
                v_lots_p, round(p.strike, 0), round(p.premium, 2));
end;
$$;

revoke all on function public.delta_sell_entry(uuid, uuid, text, numeric, numeric, text, numeric, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. The engine, writing a remark at every decision
-- ---------------------------------------------------------------------------
-- Unchanged from 0031 in what it decides. Every branch that acted, or decided
-- not to, now records why beside its `raise log` — the log line stays, because it
-- is what an operator greps when the engine itself is the suspect, and the remark
-- is what the trader reads.
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
  -- Δp as text for a remark: a null one has to read as "unknown", not vanish
  -- into a format() blank.
  v_dptxt     text;
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

        perform public.delta_remark(
          r.account_id, r.user_id, 'flatten',
          format('%s — bought back all %s open leg(s) and stood flat.',
                 -- The same test delta_session makes: a day outside trade_days
                 -- reports closed, so say which kind of closed it is.
                 case when s.trade_days is not null
                           and not (extract(isodow from v_day::date)::smallint = any (s.trade_days))
                      then 'Not a trading day'
                      else 'Session closed' end,
                 v_legs),
          v_spot, v_dp, null, null, null);
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
      v_dptxt := coalesce(round(v_dp, 2)::text, 'unknown');

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
        perform public.delta_remark(
          r.account_id, r.user_id, 'wait',
          format('Margin $%s is over the cut-at level $%s, but there is no short left to cut.',
                 round(v_margin, 2), round(v_cap, 2)),
          v_spot, v_dp, null, null, null, true);
        continue;
      end if;

      v_perlot := (0.01 * v_spot + v_leg.mark) * v_leg.cv;
      if v_perlot <= 0 then
        raise log 'apply_delta_strategy: account % cannot price margin on % — skipping cut',
          r.account_id, v_leg.symbol;
        perform public.delta_remark(
          r.account_id, r.user_id, 'wait',
          format('Margin $%s is over the cut-at level $%s, but %s has no price to size a cut against.',
                 round(v_margin, 2), round(v_cap, 2), v_leg.symbol),
          v_spot, v_dp, null, v_leg.symbol, null, true);
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

      raise log 'apply_delta_strategy: account % margin % > cap % of equity % — cut % of %',
        r.account_id, round(v_margin, 2), round(v_cap, 2), round(v_equity, 2), v_q, v_leg.symbol;
      perform public.delta_remark(
        r.account_id, r.user_id, 'cut',
        format('Margin $%s passed the cut-at level $%s (%s%% of equity $%s), so the book is being cut, not corrected. Closed %s lot(s) of %s — deepest in the money%s — to bring margin back to $%s. Δp was %s. Loss booked.',
               round(v_margin, 2), round(v_cap, 2),
               case when v_equity > 0 then round(v_margin / v_equity * 100, 0)::text else 'over' end,
               round(v_equity, 2), v_q, v_leg.symbol,
               case when v_cutside is null then ''
                    when v_cutside = 'call_options' then ' and a call, whose exit lifts Δp back toward the band'
                    else ' and a put, whose exit pulls Δp back toward the band' end,
               round(v_goal, 2), v_dptxt),
        v_spot, v_dp, null, v_leg.symbol, v_q);
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
      perform public.delta_remark(
        r.account_id, r.user_id, 'wait',
        format('Expiry %s is not listed any more, so there is nothing to trade. Pick a live date to start again.',
               coalesce(s.expiry_label, '(chosen by rule)')),
        v_spot, public.delta_book_dp(r.account_id), null, null, null, true);
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
        perform public.delta_remark(
          r.account_id, r.user_id, 'hold',
          format('Opening pair held back: margin $%s is already over the cut-to level $%s (equity $%s). It will open as soon as margin comes down.',
                 round(v_margin, 2), round(v_goal, 2), round(v_equity, 2)),
          v_spot, public.delta_book_dp(r.account_id), null, null, null, true);
        continue;
      end if;

      -- 0 is the floor argument: there is no minimum premium any more. Asking for
      -- the strike closest to entry_premium already decides what may be sold.
      v_dp := public.delta_book_dp(r.account_id);
      v_desc := public.delta_sell_entry(r.account_id, r.user_id, v_exp, s.entry_premium,
                                        0, s.tie_break, s.qty, v_spot);
      if v_desc is null then
        raise log 'apply_delta_strategy: account % entry did not fill, retrying next refresh',
          r.account_id;
        perform public.delta_remark(
          r.account_id, r.user_id, 'wait',
          format('Could not open the pair on expiry %s — no symmetric call and put quoted near $%s. Retrying every cycle.',
                 v_exp, round(s.entry_premium, 2)),
          v_spot, v_dp, null, null, null, true);
        continue;
      end if;

      update public.delta_strategy_settings
      set entered_day = v_day, flattened_day = null
      where account_id = r.account_id;

      perform public.delta_remark(
        r.account_id, r.user_id, 'entry',
        format('Session open — sold the pair nearest $%s: %s.', round(s.entry_premium, 2), v_desc),
        v_spot, v_dp, null, null, null);
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
      perform public.delta_remark(
        r.account_id, r.user_id, 'wait',
        format('%s open leg(s) have no delta published yet, so net delta cannot be trusted. Holding until they arrive.',
               v_missing),
        v_spot, null, null, null, null, true);
      continue;
    end if;

    -- Δp in qty (underlying) units, the unit the band is set in: net_qty counts
    -- venue lots, so the lot-sized delta sum is scaled by the contract value.
    -- Sizing below divides it back out, since a correction is still placed in lots
    -- — leaving the lot count it computes identical to before, only the breach
    -- threshold now reads in the trader's own delta unit.
    v_cv := coalesce(v_cv, 1);
    v_dp := v_dp * v_cv;
    v_dptxt := round(v_dp, 2)::text;

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

        perform public.delta_remark(
          r.account_id, r.user_id, 'exit',
          format('Net delta %s left the band %s to %s. %s is %s points in the money, but all %s roll(s) on the %s side are spent — so it was closed in full instead of rolled, and the loss booked.',
                 v_dptxt, round(s.band_low, 2), round(s.band_high, 2), v_leg.symbol,
                 round(v_leg.itm_distance, 0), s.max_rolls,
                 case when v_rollside = 'call_options' then 'call' else 'put' end),
          v_spot, v_dp, v_target, v_leg.symbol, abs(v_leg.net_qty));

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

      perform public.delta_remark(
        r.account_id, r.user_id, 'roll',
        format('Net delta %s left the band %s to %s (spot $%s). %s is %s points in the money, so %s lot(s) were bought back and re-sold further out at %s (delta %s against %s), aiming to bring net delta to %s.',
               v_dptxt, round(s.band_low, 2), round(s.band_high, 2), round(v_spot, 2),
               v_leg.symbol, round(v_leg.itm_distance, 0), v_q, v_repl.symbol,
               round(v_repl.delta, 3), round(v_leg.delta, 3), round(v_target, 2)),
        v_spot, v_dp, v_target, v_leg.symbol, v_q);

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
      perform public.delta_remark(
        r.account_id, r.user_id, 'hold',
        format('Net delta %s is outside the band %s to %s and nothing is left to roll, but margin $%s is over the cut-to level $%s (equity $%s) — so no fresh leg was sold. The breach stands until margin comes down or the cut fires.',
               v_dptxt, round(s.band_low, 2), round(s.band_high, 2),
               round(v_margin, 2), round(v_goal, 2), round(v_equity, 2)),
        v_spot, v_dp, v_target, null, null, true);
      continue;
    end if;

    select * into v_pick from public.delta_pick_premium(
      v_exp, v_sellside, s.entry_premium, 0, s.tie_break, null::numeric);
    if v_pick.symbol is null then
      raise log 'apply_delta_strategy: account % has no % strike quoted to correct with',
        r.account_id, v_sellside;
      perform public.delta_remark(
        r.account_id, r.user_id, 'wait',
        format('Net delta %s is outside the band %s to %s, but no %s is quoted on expiry %s to correct with.',
               v_dptxt, round(s.band_low, 2), round(s.band_high, 2),
               case when v_sellside = 'call_options' then 'call' else 'put' end, v_exp),
        v_spot, v_dp, v_target, null, null, true);
      continue;
    end if;

    v_q := floor(abs(v_target - v_dp) / (v_cv * abs(v_pick.delta)) + 1e-9)::int;
    if v_q <= 0 then
      perform public.delta_remark(
        r.account_id, r.user_id, 'wait',
        format('Net delta %s is just outside the band %s to %s, but the gap to %s is worth less than one contract of %s — left alone rather than overshooting.',
               v_dptxt, round(s.band_low, 2), round(s.band_high, 2),
               round(v_target, 2), v_pick.symbol),
        v_spot, v_dp, v_target, v_pick.symbol, null, true);
      continue;
    end if;

    perform public.delta_sell(r.account_id, r.user_id, v_pick.symbol, v_q, v_spot);

    perform public.delta_remark(
      r.account_id, r.user_id, 'band',
      format('Net delta %s left the band %s to %s (spot $%s) and no in-the-money leg was left to roll, so %s lot(s) of %s were sold fresh at $%s (delta %s) to pull net delta back to %s.',
             v_dptxt, round(s.band_low, 2), round(s.band_high, 2), round(v_spot, 2),
             v_q, v_pick.symbol, round(v_pick.premium, 2), round(v_pick.delta, 3),
             round(v_target, 2)),
      v_spot, v_dp, v_target, v_pick.symbol, v_q);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_delta_strategy() from public, anon, authenticated;
