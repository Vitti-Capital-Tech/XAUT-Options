-- 0035_reason_on_the_row.sql
--
-- Run this whole file in the Supabase SQL Editor after 0034_delta_tpsl_remarks.sql.
--
-- The reasoning moves to the row it explains.
--
-- 0033 and 0034 record why the delta engine acts, and they read well as a log —
-- but a log is a second place to look. The question is always asked *of a row*:
-- this leg closed at 14:32, why? That leg is open, why did it get bought? Asking
-- it means finding the matching line in another table, by eye, by timestamp.
--
-- So the reason is stamped onto the trade and onto the position:
--
--     fills.reason         why this exit happened      -> Trade History
--     positions.entry_reason  why this leg was opened  -> Positions
--
-- Both carry the same shape of line — what the engine did, where it was aiming,
-- the spot it was priced at, and net delta either side of the action:
--
--     Rolled further out — band breach (target -0.60) · spot $4243.10 · Δp -1.35 → -0.62
--     Take-profit hit · spot $4243.10 · Δp -0.62 → -0.30
--
-- `delta_remarks` stays as it is. It holds the same decisions with their fields
-- separated, including the ones that produced no trade at all — an entry held
-- back by margin, a Δp that could not be trusted — which by definition have no
-- row to be stamped onto. The strategy bar's `Last` line reads from it, and that
-- is the only place those now surface.
--
-- ---------------------------------------------------------------------------
-- Which fills get an exit reason
-- ---------------------------------------------------------------------------
-- The ones that closed exposure: every `buy`, plus any fill that realized P&L.
--
-- The first half is exact for this book and not a guess — the strategy is
-- sell-only, so a buy is always a close. The second half covers the one leg it
-- could not otherwise reach: a long that a human opened by hand on the delta
-- account, which the session-close flatten exits by *selling*.
--
-- Opening fills are deliberately left null. Their reason is not lost — it is on
-- the position they opened, which is where "why do I hold this" is asked. Under a
-- column headed Exit Reason it would be an answer to a different question.
--
-- ---------------------------------------------------------------------------
-- How the stamp finds its rows
-- ---------------------------------------------------------------------------
-- `created_at >= now()`. `now()` is the transaction's start time and does not
-- advance inside it, so the rows written by this cycle are exactly the rows whose
-- default timestamp equals it. `delta_remark` is called immediately after the
-- action it describes and inside the same transaction, and the engine takes at
-- most one action per account per cycle, so the match cannot span two decisions.
-- `reason is null` keeps it from ever rewriting one.
--
-- Positions match on `opened_at`, which only moves when a row is inserted — so
-- adding to a leg that already exists leaves its original entry reason alone,
-- which is the right answer: it is still the reason that leg is on the book.

-- ---------------------------------------------------------------------------
-- 1. The two columns
-- ---------------------------------------------------------------------------
alter table public.fills add column if not exists reason text;

comment on column public.fills.reason is
  'Why the delta engine closed this leg, with the spot and the net delta either side of it. Null on opening fills and on anything the delta engine did not do.';

alter table public.positions add column if not exists entry_reason text;

comment on column public.positions.entry_reason is
  'Why the delta engine opened this leg. Set when the position row is created and left alone when the leg is added to.';

-- ---------------------------------------------------------------------------
-- 2. The writer, now stamping the rows as well as logging
-- ---------------------------------------------------------------------------
-- Body is 0033's with the line composed and stamped at the end. No call site
-- changes: the head of the sentence comes from the action, the tail from the
-- fields the caller already passes, so the engine and the bracket sweep write
-- these without knowing they do.
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
  v_last  record;
  v_band  record;
  v_after numeric;
  v_line  text;
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

  -- Read once: the log row and the stamped line must report the same number, and
  -- reading it twice would price them off two different statements.
  v_after := public.delta_book_dp(p_account);

  insert into public.delta_remarks (account_id, user_id, action, spot, dp_before,
                                    dp_target, dp_after, band_low, band_high,
                                    symbol, qty, note)
  values (p_account, p_user, p_action, p_spot, p_dp_before,
          p_dp_target, v_after, v_band.band_low, v_band.band_high,
          p_symbol, p_qty, p_note);

  delete from public.delta_remarks
  where account_id = p_account and created_at < now() - interval '30 days';

  -- ---- The line that goes on the row --------------------------------------
  -- Short enough for a table column, and saying the three things a trader asks
  -- of a trade they did not place: what rule ran, what the market was, and what
  -- it did to the book's delta. The long-form sentence stays in the log.
  --
  -- `hold` and `wait` fall out here with a null head, which is correct twice
  -- over: nothing was traded, so there is no row to stamp.
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

  if v_line is null then return; end if;

  v_line := v_line
    -- Only where there is one. A cut, a flatten and a bracket answer to margin
    -- or to the option's own price, and have no delta they are aiming for.
    || case when p_dp_target is null then ''
            else format(' (target %s)', round(p_dp_target, 2)) end
    || format(' · spot $%s · Δp %s → %s',
              coalesce(round(p_spot, 2)::text, '—'),
              coalesce(round(p_dp_before, 2)::text, '—'),
              coalesce(round(v_after, 2)::text, '—'));

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
  -- an existing leg is added to.
  update public.positions
  set entry_reason = v_line
  where account_id = p_account
    and entry_reason is null
    and opened_at >= now();
end;
$$;

revoke all on function public.delta_remark(uuid, uuid, text, text, numeric, numeric, numeric, text, integer, boolean)
  from public, anon, authenticated;
