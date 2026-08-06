-- ============================================================================
-- XAUT Options Paper Trading — record why a fill happened
-- Run this whole file in the Supabase SQL Editor after 0004_tpsl_trigger.sql.
--
-- Trade History could not say why a position closed: a manual market close, a
-- take-profit, a stop-loss and an expiry settlement all booked as identical
-- fills. Settlement was already flagged (is_settlement), and a triggered close
-- already computes its reason — it was just discarded in a raise notice. This
-- stores it, so the ledger can label each row.
--
-- Only close_position_triggered changes. A normal fill leaves close_reason null
-- (→ "Trade"); a settlement is told apart by is_settlement (→ "Settlement"); a
-- triggered close now carries 'take_profit' or 'stop_loss'. execute_fill and
-- settle_symbol are untouched.
-- ============================================================================

alter table public.fills add column if not exists close_reason text;

comment on column public.fills.close_reason is
  'Why a triggered close fired: take_profit or stop_loss. Null for ordinary fills and settlement.';

-- Recreate the triggered-close writer to persist its reason. Body is identical
-- to 0003 but for the added column; signature is unchanged, so the revoke from
-- 0003 carries over (re-issued below to be sure).
create or replace function public.close_position_triggered(
  p_position_id uuid,
  p_price       numeric,
  p_reason      text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  pos        public.positions;
  v_realized numeric;
begin
  select * into pos from public.positions where id = p_position_id for update;
  if not found then
    return; -- already closed by a fill or another pass; nothing to do
  end if;

  v_realized := case
    when pos.net_qty > 0
      then (p_price - pos.avg_entry_price) * abs(pos.net_qty) * pos.contract_value
    else (pos.avg_entry_price - p_price) * abs(pos.net_qty) * pos.contract_value
  end;

  insert into public.fills (
    order_id, account_id, user_id, symbol, contract_type, strike_price,
    side, order_type, qty, price, contract_value,
    premium, notional, fee, realized_pnl, spot_at_fill, is_settlement, close_reason
  )
  values (
    null, pos.account_id, pos.user_id, pos.symbol, pos.contract_type, pos.strike_price,
    case when pos.net_qty > 0 then 'sell' else 'buy' end,
    'market', abs(pos.net_qty), p_price, pos.contract_value,
    p_price * pos.contract_value * abs(pos.net_qty),
    0, 0,
    v_realized, null, false, p_reason
  );

  update public.accounts
  set cash_balance = cash_balance + v_realized
  where id = pos.account_id;

  delete from public.positions where id = pos.id;

  raise notice 'closed % on % at % (%)', p_position_id, pos.symbol, p_price, p_reason;
end;
$$;

revoke all on function public.close_position_triggered(uuid, numeric, text) from public, anon, authenticated;
