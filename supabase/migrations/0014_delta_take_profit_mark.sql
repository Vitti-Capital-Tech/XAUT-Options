-- ============================================================================
-- XAUT Options Paper Trading — the delta take-profit is a mark price, not a multiple
-- Run this whole file in the Supabase SQL Editor after 0013_delta_take_profit.sql.
--
-- 0013 read the setting as a multiple of the premium sold, so a $4 leg bracketed
-- at 0.7 was bought back at $2.80. It is a *level* on the option's own mark: 0.7
-- means buy the leg back when its mark reaches $0.70, whatever it was sold for.
--
--     take_profit = take_profit_mark,  tpsl_trigger = 'mark'
--
-- A short gains as its mark falls, and apply_tpsl_triggers reads that correctly:
-- with the mark as the reference it sets v_up := v_long, so for a short the
-- take-profit fires on `v_ref <= take_profit`.
--
-- The column is renamed rather than replaced, and the stored numbers carry over
-- unchanged — at the default 0.7 that is the same number under both readings, but
-- any account that had tuned the old multiple now holds it as a dollar level.
--
-- No stop-loss is set. The strategy's own risk control is the roll budget and
-- exit-only mode in Section 5.3, not a per-leg stop.
-- ============================================================================

do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'delta_strategy_settings'
      and column_name = 'take_profit_mult'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'delta_strategy_settings'
      and column_name = 'take_profit_mark'
  ) then
    alter table public.delta_strategy_settings rename column take_profit_mult to take_profit_mark;
  end if;
end $$;

-- Null or zero disables the take-profit entirely.
alter table public.delta_strategy_settings
  add column if not exists take_profit_mark numeric(20, 8) default 0.7;

alter table public.delta_strategy_settings
  alter column take_profit_mark set default 0.7;

comment on column public.delta_strategy_settings.take_profit_mark is
  'Take-profit as a price on the option''s own mark. 0.7 buys any short leg back at $0.70. Null or 0 disables it.';

-- ---------------------------------------------------------------------------
-- delta_sell arms the bracket after the fill.
--
-- The level is read from the account's own settings rather than passed in, so the
-- signature is unchanged and apply_delta_strategy and delta_sell_entry carry on
-- calling this exactly as they did.
--
-- Guarded on net_qty < 0: delta_flatten also routes through here to close a long,
-- and a bracket on a position that is now flat has nothing to watch. Guarded on
-- avg_entry_price > the level too — a take-profit at or above what the leg was
-- sold for is not a profit, and would fire on the fill that opened it.
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

  -- Take profit, no stop. The level is absolute, so adding to an existing short
  -- leaves it where it is rather than re-basing it onto the new average entry.
  select take_profit_mark into v_tp
  from public.delta_strategy_settings where account_id = p_account;

  if v_tp is not null and v_tp > 0 then
    update public.positions
    set take_profit  = v_tp,
        stop_loss    = null,
        tpsl_trigger = 'mark'
    where account_id = p_account and symbol = p_symbol and net_qty < 0
      and avg_entry_price > v_tp;
  end if;
end;
$$;

revoke all on function public.delta_sell(uuid, uuid, text, int, numeric) from public, anon, authenticated;

-- Re-base any bracket 0013 already armed off the old multiple onto the level.
update public.positions p
set take_profit = s.take_profit_mark,
    stop_loss = null,
    tpsl_trigger = 'mark'
from public.accounts a
join public.delta_strategy_settings s on s.account_id = a.id
where a.id = p.account_id and a.kind = 'delta' and p.net_qty < 0
  and s.take_profit_mark is not null and s.take_profit_mark > 0
  and p.avg_entry_price > s.take_profit_mark
  and p.take_profit is distinct from s.take_profit_mark;
