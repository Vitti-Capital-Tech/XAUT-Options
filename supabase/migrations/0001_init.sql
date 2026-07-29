-- ============================================================================
-- XAUT Options Paper Trading — initial schema
-- Run this whole file in the Supabase SQL Editor (Dashboard > SQL Editor > New query).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- accounts: paper sub-accounts. One auth user can own many.
-- ---------------------------------------------------------------------------
create table if not exists public.accounts (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  name              text not null,
  starting_balance  numeric(20, 8) not null default 10000,
  -- Realized cash only: starting_balance + realized P&L - fees.
  -- Open-position value is NOT included here; equity = cash_balance + unrealized.
  cash_balance      numeric(20, 8) not null default 10000,
  is_archived       boolean not null default false,
  created_at        timestamptz not null default now(),
  constraint accounts_name_len check (char_length(trim(name)) between 1 and 40)
);

create index if not exists accounts_user_idx on public.accounts (user_id, created_at);

-- ---------------------------------------------------------------------------
-- orders: market orders land as 'filled'; limit orders sit 'open' until crossed.
-- ---------------------------------------------------------------------------
create table if not exists public.orders (
  id              uuid primary key default gen_random_uuid(),
  account_id      uuid not null references public.accounts (id) on delete cascade,
  user_id         uuid not null references auth.users (id) on delete cascade,
  symbol          text not null,
  product_id      bigint not null,
  contract_type   text not null check (contract_type in ('call_options', 'put_options')),
  strike_price    numeric(20, 8) not null,
  expiry_label    text not null,              -- e.g. '300726', straight from the symbol
  contract_value  numeric(20, 8) not null,    -- XAUT per lot, e.g. 0.001
  side            text not null check (side in ('buy', 'sell')),
  order_type      text not null check (order_type in ('market', 'limit')),
  qty             integer not null check (qty > 0),
  limit_price     numeric(20, 8),
  status          text not null default 'open' check (status in ('open', 'filled', 'cancelled')),
  avg_fill_price  numeric(20, 8),
  filled_qty      integer not null default 0,
  reduce_only     boolean not null default false,
  cancel_reason   text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- A limit order must carry a price; a market order must not.
  constraint orders_limit_price_required check (
    (order_type = 'limit' and limit_price is not null and limit_price > 0)
    or (order_type = 'market' and limit_price is null)
  )
);

create index if not exists orders_account_status_idx on public.orders (account_id, status, created_at desc);
-- Partial index: the fill engine only ever scans open orders.
create index if not exists orders_open_idx on public.orders (account_id) where status = 'open';

-- ---------------------------------------------------------------------------
-- fills: immutable trade history. One row per execution.
-- ---------------------------------------------------------------------------
create table if not exists public.fills (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders (id) on delete cascade,
  account_id      uuid not null references public.accounts (id) on delete cascade,
  user_id         uuid not null references auth.users (id) on delete cascade,
  symbol          text not null,
  contract_type   text not null,
  strike_price    numeric(20, 8) not null,
  side            text not null check (side in ('buy', 'sell')),
  order_type      text not null,
  qty             integer not null check (qty > 0),
  price           numeric(20, 8) not null,    -- premium price, quote units (USD per XAUT)
  contract_value  numeric(20, 8) not null,
  premium         numeric(20, 8) not null,    -- price * contract_value * qty, in USD
  notional        numeric(20, 8) not null,    -- spot * contract_value * qty, in USD
  fee             numeric(20, 8) not null default 0,
  realized_pnl    numeric(20, 8) not null default 0,  -- non-zero only when this fill closed exposure
  spot_at_fill    numeric(20, 8),
  created_at      timestamptz not null default now()
);

create index if not exists fills_account_idx on public.fills (account_id, created_at desc);

-- ---------------------------------------------------------------------------
-- positions: netted per (account, symbol). net_qty is signed — long > 0, short < 0.
-- Rows with net_qty = 0 are deleted, so a present row is always live exposure.
-- ---------------------------------------------------------------------------
create table if not exists public.positions (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references public.accounts (id) on delete cascade,
  user_id           uuid not null references auth.users (id) on delete cascade,
  symbol            text not null,
  product_id        bigint not null,
  contract_type     text not null,
  strike_price      numeric(20, 8) not null,
  expiry_label      text not null,
  contract_value    numeric(20, 8) not null,
  net_qty           integer not null,
  avg_entry_price   numeric(20, 8) not null,
  realized_pnl      numeric(20, 8) not null default 0,
  opened_at         timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  -- One netted position per symbol per account. The engine relies on this for upserts.
  unique (account_id, symbol)
);

create index if not exists positions_account_idx on public.positions (account_id);

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders
  for each row execute function public.touch_updated_at();

drop trigger if exists positions_touch on public.positions;
create trigger positions_touch before update on public.positions
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Row Level Security: every table is scoped to the owning auth user.
-- ---------------------------------------------------------------------------
alter table public.accounts  enable row level security;
alter table public.orders    enable row level security;
alter table public.fills     enable row level security;
alter table public.positions enable row level security;

-- One policy per table, covering every verb: USING gates select/update/delete,
-- WITH CHECK gates insert/update so a row cannot be attributed to another user.
drop policy if exists accounts_owner_all on public.accounts;
create policy accounts_owner_all on public.accounts
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists orders_owner_all on public.orders;
create policy orders_owner_all on public.orders
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists fills_owner_all on public.fills;
create policy fills_owner_all on public.fills
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists positions_owner_all on public.positions;
create policy positions_owner_all on public.positions
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Atomic order placement + position netting.
--
-- Why a function: a fill has to write three tables (orders, fills, positions)
-- and adjust the account balance. Doing that from the browser in four round
-- trips can tear — a refresh mid-sequence would leave a fill with no position.
-- This runs it in one transaction instead.
--
-- Netting rules:
--   * adding to a position    -> weighted-average entry price
--   * reducing a position     -> realize P&L on the closed lots, entry unchanged
--   * flipping through zero   -> realize on the closed lots, remainder re-opens
--                                at the fill price
-- ---------------------------------------------------------------------------
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
  v_signed     integer;      -- this fill's signed lot delta
  v_same_dir   boolean;
  v_new_qty    integer;
  v_new_avg    numeric;
  v_close_qty  integer;
  v_realized   numeric := 0;
  v_fill       public.fills;
begin
  -- Lock the order so two concurrent tabs cannot fill the same limit order twice.
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

  v_cv := o.contract_value;
  v_signed := case when o.side = 'buy' then p_qty else -p_qty end;

  select * into pos
  from public.positions
  where account_id = o.account_id and symbol = o.symbol
  for update;

  if not found then
    v_new_qty := v_signed;
    v_new_avg := p_price;
  else
    -- Compared explicitly rather than via sign(): net_qty is an integer and
    -- sign()'s integer overload resolution is not worth relying on here.
    v_same_dir := (pos.net_qty > 0 and v_signed > 0) or (pos.net_qty < 0 and v_signed < 0);

    if v_same_dir then
      -- Same direction: blend the entry price over the combined lots.
      v_new_qty := pos.net_qty + v_signed;
      v_new_avg := (abs(pos.net_qty) * pos.avg_entry_price + p_qty * p_price)
                   / (abs(pos.net_qty) + p_qty);
    else
      -- Opposing direction: close what we can, realize it.
      v_close_qty := least(abs(pos.net_qty), p_qty);
      v_realized := case
        when pos.net_qty > 0 then (p_price - pos.avg_entry_price) * v_close_qty * v_cv
        else (pos.avg_entry_price - p_price) * v_close_qty * v_cv
      end;
      v_new_qty := pos.net_qty + v_signed;
      v_new_avg := case
        when v_new_qty = 0 then 0                                   -- flat
        when (v_new_qty > 0) <> (pos.net_qty > 0) then p_price       -- flipped through zero
        else pos.avg_entry_price                                    -- partial reduce
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
    p_price * v_cv * p_qty, coalesce(p_spot, 0) * v_cv * p_qty,
    p_fee, v_realized, p_spot
  )
  returning * into v_fill;

  update public.orders
  set status = 'filled',
      filled_qty = o.filled_qty + p_qty,
      -- Single-fill orders only, so the average is just this price.
      avg_fill_price = p_price
  where id = o.id;

  if v_new_qty = 0 then
    delete from public.positions where account_id = o.account_id and symbol = o.symbol;
  else
    insert into public.positions (
      account_id, user_id, symbol, product_id, contract_type, strike_price,
      expiry_label, contract_value, net_qty, avg_entry_price, realized_pnl
    )
    values (
      o.account_id, o.user_id, o.symbol, o.product_id, o.contract_type, o.strike_price,
      o.expiry_label, v_cv, v_new_qty, v_new_avg, v_realized
    )
    -- In ON CONFLICT the existing row is referenced by bare table name, not schema-qualified.
    on conflict (account_id, symbol) do update
      set net_qty = v_new_qty,
          avg_entry_price = v_new_avg,
          realized_pnl = positions.realized_pnl + v_realized;
  end if;

  -- Cash moves only on realized P&L and fees. Unrealized stays off the balance.
  update public.accounts
  set cash_balance = cash_balance + v_realized - p_fee
  where id = o.account_id;

  return v_fill;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reset an account back to its starting balance and wipe its trading history.
-- ---------------------------------------------------------------------------
create or replace function public.reset_account(p_account_id uuid)
returns void
language plpgsql
security invoker
as $$
begin
  -- RLS restricts these to the caller's own rows, so a bad id simply affects nothing.
  delete from public.fills where account_id = p_account_id;
  delete from public.orders where account_id = p_account_id;
  delete from public.positions where account_id = p_account_id;
  update public.accounts set cash_balance = starting_balance where id = p_account_id;
end;
$$;

-- Both functions run as the caller, so RLS still scopes every row they touch.
grant execute on function public.execute_fill(uuid, integer, numeric, numeric, numeric) to authenticated;
grant execute on function public.reset_account(uuid) to authenticated;
