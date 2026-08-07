-- ============================================================================
-- XAUT Options Paper Trading — take-profit on delta strategy sells
-- Run this whole file in the Supabase SQL Editor after 0012_delta_strategy_engine.sql.
--
-- Every short the delta strategy opens now carries a take-profit and no stop.
-- The level is a multiple of the premium it sold at, watched on the option's own
-- mark — the same shape as the auto strategy's stop at twice entry, in the other
-- direction:
--
--     take_profit = take_profit_mult x avg_entry_price,  tpsl_trigger = 'mark'
--
-- A short gains as its mark falls, and apply_tpsl_triggers reads that correctly:
-- with the mark as the reference it sets v_up := v_long, so for a short the
-- take-profit fires on `v_ref <= take_profit`. At the default 0.7 a leg sold for
-- $4 is bought back at $2.80, booking 30% of the premium.
--
-- No stop-loss is set, and any stop left on a delta position is cleared. The
-- strategy's own risk control is the roll budget and exit-only mode in Section
-- 5.3, not a per-leg stop.
-- ============================================================================

-- Null or zero disables the take-profit entirely.
alter table public.delta_strategy_settings
  add column if not exists take_profit_mult numeric(20, 8) default 0.7;

comment on column public.delta_strategy_settings.take_profit_mult is
  'Take-profit as a multiple of the premium sold, on the mark. 0.7 buys a $4 leg back at $2.80. Null or 0 disables it.';

-- ---------------------------------------------------------------------------
-- delta_sell arms the bracket after the fill.
--
-- The multiple is read from the account's own settings rather than passed in, so
-- the signature is unchanged and apply_delta_strategy and delta_sell_entry carry
-- on calling this exactly as they did.
--
-- Guarded on net_qty < 0: delta_flatten also routes through here to close a long,
-- and a bracket on a position that is now flat has nothing to watch.
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

  -- Take profit, no stop. avg_entry_price is the blended entry, so adding to an
  -- existing short re-bases the level onto the new average rather than leaving it
  -- pinned to the first fill.
  select take_profit_mult into v_tp
  from public.delta_strategy_settings where account_id = p_account;

  if v_tp is not null and v_tp > 0 then
    update public.positions
    set take_profit  = v_tp * avg_entry_price,
        stop_loss    = null,
        tpsl_trigger = 'mark'
    where account_id = p_account and symbol = p_symbol and net_qty < 0;
  end if;
end;
$$;

revoke all on function public.delta_sell(uuid, uuid, text, int, numeric) from public, anon, authenticated;

-- Clear any stop already sitting on a delta account's positions.
update public.positions p
set stop_loss = null
from public.accounts a
where a.id = p.account_id and a.kind = 'delta' and p.stop_loss is not null;
