-- 0052_futures_fees.sql
--
-- Run this file in the Supabase SQL Editor after 0051.
--
-- Sets fee calculation to 0.01% of notional (0.0001 * notional) on every fill
-- (options & perpetual futures) and deducts fees from cash balance so realized PnL,
-- balance, and total PnL accurately include fees.
-- ============================================================================

create or replace function public.execute_fill(
  p_order_id  uuid,
  p_qty       integer,
  p_price     numeric,
  p_fee       numeric,
  p_spot      numeric
)
returns public.fills
language plpgsql
security invoker
as $$
declare
  o            public.orders;
  pos          public.positions;
  v_cv         numeric;
  v_signed     integer;
  v_same_dir   boolean;
  v_new_qty    integer;
  v_new_avg    numeric;
  v_close_qty  integer;
  v_realized   numeric := 0;
  v_fill       public.fills;
  v_notional   numeric;
  v_fee        numeric;
begin
  -- Lock the order to prevent concurrent double-fills
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if o.status <> 'open' then
    raise exception 'order % is %, not open', p_order_id, o.status;
  end if;
  if p_qty <> o.qty - o.filled_qty then
    raise exception 'partial fills are not supported (asked %, remaining %)',
      p_qty, o.qty - o.filled_qty;
  end if;

  v_cv := coalesce(o.contract_value, 0.001);
  v_signed := case when o.side = 'buy' then p_qty else -p_qty end;

  -- Notional value calculation
  if o.contract_type = 'perpetual_futures' then
    v_notional := coalesce(nullif(p_price, 0), p_spot, 0) * v_cv * p_qty;
  else
    v_notional := coalesce(nullif(p_spot, 0), p_price, 0) * v_cv * p_qty;
  end if;

  -- Fee formula: 0.01% of notional (0.0001 * notional)
  if p_fee is not null and p_fee > 0 then
    v_fee := p_fee;
  else
    v_fee := 0.0001 * v_notional;
  end if;

  select * into pos
  from public.positions
  where account_id = o.account_id and symbol = o.symbol
  for update;

  if not found then
    v_new_qty := v_signed;
    v_new_avg := p_price;
  else
    v_same_dir := (pos.net_qty > 0 and v_signed > 0) or (pos.net_qty < 0 and v_signed < 0);

    if v_same_dir then
      -- Same direction: blend the average entry price
      v_new_qty := pos.net_qty + v_signed;
      v_new_avg := (abs(pos.net_qty) * pos.avg_entry_price + p_qty * p_price)
                   / (abs(pos.net_qty) + p_qty);
    else
      -- Opposing direction: close what we can, realize PnL
      v_close_qty := least(abs(pos.net_qty), p_qty);
      v_realized := case
        when pos.net_qty > 0 then (p_price - pos.avg_entry_price) * v_close_qty * v_cv
        else (pos.avg_entry_price - p_price) * v_close_qty * v_cv
      end;
      v_new_qty := pos.net_qty + v_signed;
      v_new_avg := case
        when v_new_qty = 0 then 0
        when (v_new_qty > 0) <> (pos.net_qty > 0) then p_price
        else pos.avg_entry_price
      end;
    end if;
  end if;

  insert into public.fills (
    order_id, account_id, user_id, symbol, contract_type, strike_price,
    side, order_type, qty, price, contract_value,
    premium, notional, fee, realized_pnl, spot_at_fill
  )
  values (
    o.id, o.account_id, o.user_id, o.symbol, o.contract_type, o.strike_price,
    o.side, o.order_type, p_qty, p_price, v_cv,
    p_price * v_cv * p_qty, v_notional,
    v_fee, v_realized, p_spot
  )
  returning * into v_fill;

  update public.orders
  set status = 'filled',
      filled_qty = o.filled_qty + p_qty,
      avg_fill_price = p_price
  where id = o.id;

  if v_new_qty = 0 then
    delete from public.positions where account_id = o.account_id and symbol = o.symbol;
  else
    insert into public.positions (
      account_id, user_id, symbol, product_id, contract_type, strike_price,
      expiry_label, contract_value, net_qty, avg_entry_price, realized_pnl, leverage
    )
    values (
      o.account_id, o.user_id, o.symbol, o.product_id, o.contract_type, o.strike_price,
      o.expiry_label, v_cv, v_new_qty, v_new_avg, v_realized, o.leverage
    )
    on conflict (account_id, symbol) do update
      set net_qty = v_new_qty,
          avg_entry_price = v_new_avg,
          realized_pnl = positions.realized_pnl + v_realized,
          leverage = case when abs(v_new_qty) > abs(positions.net_qty)
                          then coalesce(o.leverage, positions.leverage)
                          else positions.leverage end;
  end if;

  -- Cash balance updates on realized PnL minus fees
  update public.accounts
  set cash_balance = cash_balance + v_realized - v_fee
  where id = o.account_id;

  return v_fill;
end;
$$;

grant execute on function public.execute_fill(uuid, integer, numeric, numeric, numeric) to authenticated;
