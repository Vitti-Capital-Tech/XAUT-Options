-- ============================================================================
-- XAUT Options Paper Trading — an optional stop on the delta strategy's shorts
-- Run this whole file in the Supabase SQL Editor after 0025_clear_entered_day_when_closed.sql.
--
--     delta_strategy_settings.stop_loss_mark   a price on the option's own mark; 0 = no stop
--
-- READ THIS FIRST. The rules document has no stop-loss, and says so by omission and
-- by design: §5.3 makes the per-side roll budget and exit-only mode the risk
-- control, and Section 6's list of constraints applied throughout never mentions
-- one. This is an addition, not an implementation of the spec — the same standing
-- as take_profit_mark.
--
-- It is worth knowing how a stop interacts with the roll logic before switching it
-- on. A short leg going against you is exactly the leg the ITM queue exists to
-- roll: buy part of it back, sell further out, keep collecting premium. A stop
-- closes that leg outright instead, so the roll never happens, the premium is not
-- replaced, and Δp jumps by the whole of that leg's contribution — which the next
-- cycle then corrects by selling somewhere else. Set generously if at all.
--
-- Shape mirrors the take-profit: a price on the mark, not a percentage, because
-- that is what TP mark is and one tab should not measure its two brackets in two
-- different units. A short gains as its mark falls and loses as it rises, so:
--
--     take_profit = take_profit_mark   fires when the mark falls to it
--     stop_loss   = stop_loss_mark     fires when the mark rises to it
--
-- apply_tpsl_triggers reads both correctly on a mark reference: it sets
-- v_up := v_long, so for a short the take-profit fires on `v_ref <= take_profit`
-- and the stop on `v_ref >= stop_loss`.
--
-- Default 0 — no stop — so nothing changes until it is set.
-- ============================================================================

alter table public.delta_strategy_settings
  add column if not exists stop_loss_mark numeric(20, 8) not null default 0;

alter table public.delta_strategy_settings drop constraint if exists delta_stop_loss_mark_chk;
alter table public.delta_strategy_settings
  add constraint delta_stop_loss_mark_chk check (stop_loss_mark >= 0);

comment on column public.delta_strategy_settings.stop_loss_mark is
  'Stop as a price on the option''s own mark: the short is bought back when its mark rises to this. 0 arms no stop, which is the rules document''s behaviour. Not part of the spec.';

-- ---------------------------------------------------------------------------
-- delta_sell arms whichever brackets are set. Body is 0014's; the stop is no
-- longer hardcoded to null, and each level carries its own sanity guard:
--
--   * a take-profit at or above what the leg sold for is not a profit
--   * a stop at or below what it sold for is already breached
--
-- Both would fire on the fill that opened the position. The update runs
-- unconditionally now, so clearing a level in the settings clears it on the book
-- rather than leaving the last one armed.
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

  select take_profit_mark, stop_loss_mark into v_tp, v_sl
  from public.delta_strategy_settings where account_id = p_account;

  -- Both levels are absolute, so adding to an existing short leaves them where they
  -- are rather than re-basing onto the new average entry.
  update public.positions
  set take_profit = case when coalesce(v_tp, 0) > 0 and avg_entry_price > v_tp then v_tp end,
      stop_loss   = case when coalesce(v_sl, 0) > 0 and avg_entry_price < v_sl then v_sl end,
      tpsl_trigger = 'mark'
  where account_id = p_account and symbol = p_symbol and net_qty < 0;
end;
$$;

revoke all on function public.delta_sell(uuid, uuid, text, int, numeric) from public, anon, authenticated;
