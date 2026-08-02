-- ============================================================================
-- XAUT Options Paper Trading — expiry settlement
-- Run this whole file in the Supabase SQL Editor (Dashboard > SQL Editor).
--
-- Until this ran, an expired position simply sat there: its quotes vanished so
-- it valued at zero rather than at intrinsic, a short kept its margin blocked
-- for ever, and it could not be closed by hand because the chain only loads
-- live products. This settles it the way the venue does.
--
-- Delta publishes the settled premium on the product itself once it expires --
-- GET /v2/products/{symbol} returns state 'expired' and a settlement_price
-- that is already the option's intrinsic value against the 30-minute TWAP of
-- the index. So there is no payoff maths here on purpose: we take their number.
-- Nothing derives the settlement time either, because it is not uniform --
-- XAUT settles 16:00Z, ETH 12:00Z -- we just ask whether they call it expired.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Schema: a settlement is a fill with no order behind it.
-- ---------------------------------------------------------------------------
alter table public.fills alter column order_id drop not null;
alter table public.fills add column if not exists is_settlement boolean not null default false;

comment on column public.fills.is_settlement is
  'True for the closing fill written by settle_symbol. order_id is null on these.';

-- What we settled and at what price, kept for audit and so a re-run is visibly
-- a no-op rather than silently one.
create table if not exists public.settlements (
  symbol            text primary key,
  settlement_price  numeric(20, 8) not null,
  settlement_time   timestamptz,
  recorded_at       timestamptz not null default now()
);

alter table public.settlements enable row level security;

drop policy if exists settlements_read on public.settlements;
create policy settlements_read on public.settlements
  for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- The money: close every open position on a settled symbol, across all
-- accounts, at the price the venue settled it at.
--
-- security definer because the caller is pg_cron, which is nobody -- it has no
-- auth.uid() and so would see nothing through RLS. Execute is revoked below;
-- this must never be reachable from the client, or any signed-in user could
-- settle any symbol at a price of their choosing.
-- ---------------------------------------------------------------------------
create or replace function public.settle_symbol(
  p_symbol          text,
  p_price           numeric,
  p_settlement_time timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  pos        public.positions;
  v_realized numeric;
  v_count    integer := 0;
begin
  -- A negative settlement would pay someone to be wrong. Refuse rather than
  -- move cash on a number we do not believe.
  if p_price is null or p_price < 0 then
    raise exception 'settlement price for % must be >= 0, got %', p_symbol, p_price;
  end if;

  insert into public.settlements (symbol, settlement_price, settlement_time)
  values (p_symbol, p_price, p_settlement_time)
  on conflict (symbol) do nothing;

  -- Locked, so a fill landing in the same instant cannot double-close.
  for pos in
    select * from public.positions where symbol = p_symbol for update
  loop
    -- Identical to the realized-P&L arm of execute_fill, with the settlement
    -- price standing in for a trade price.
    v_realized := case
      when pos.net_qty > 0
        then (p_price - pos.avg_entry_price) * abs(pos.net_qty) * pos.contract_value
      else (pos.avg_entry_price - p_price) * abs(pos.net_qty) * pos.contract_value
    end;

    insert into public.fills (
      order_id, account_id, user_id, symbol, contract_type, strike_price,
      side, order_type, qty, price, contract_value,
      premium, notional, fee, realized_pnl, spot_at_fill, is_settlement
    )
    values (
      null, pos.account_id, pos.user_id, pos.symbol, pos.contract_type, pos.strike_price,
      -- Settlement closes the exposure, so it books as the opposing side.
      case when pos.net_qty > 0 then 'sell' else 'buy' end,
      'market', abs(pos.net_qty), p_price, pos.contract_value,
      p_price * pos.contract_value * abs(pos.net_qty),
      0,      -- no spot is recorded at settlement, so no notional to state
      0,      -- and no taker fee: this is not a trade anyone took
      v_realized, null, true
    );

    update public.accounts
    set cash_balance = cash_balance + v_realized
    where id = pos.account_id;

    delete from public.positions where id = pos.id;
    v_count := v_count + 1;
  end loop;

  -- A resting order on a dead contract can never fill, and the browser-side
  -- limit engine skips it silently for ever. Close it out.
  update public.orders
  set status = 'cancelled', cancel_reason = 'contract expired'
  where symbol = p_symbol and status = 'open';

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reaching the venue from the database.
--
-- pg_net is asynchronous: http_get queues, and the reply turns up later in
-- net._http_response. That is why this is two functions on two schedules
-- rather than one -- there is nothing to read at the moment we ask.
--
-- We poll only the symbols someone actually holds, which is a handful, and we
-- let Delta tell us whether they are expired rather than tracking settlement
-- times ourselves.
-- ---------------------------------------------------------------------------
create extension if not exists pg_net;

create or replace function public.queue_settlement_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r     record;
  v_n   integer := 0;
begin
  for r in select distinct symbol from public.positions loop
    perform net.http_get(
      url := 'https://api.india.delta.exchange/v2/products/' || r.symbol,
      timeout_milliseconds := 5000
    );
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function public.apply_settlement_responses()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r         record;
  v_result  jsonb;
  v_symbol  text;
  v_price   numeric;
  v_n       integer := 0;
begin
  for r in
    select id, content
    from net._http_response
    where status_code = 200
      and created > now() - interval '2 hours'
  loop
    -- A body that is not the JSON we expect is not an error worth aborting the
    -- whole sweep for; the next poll will ask again.
    begin
      v_result := (r.content::jsonb) -> 'result';
    exception when others then
      continue;
    end;

    if v_result is null then continue; end if;
    if v_result ->> 'state' is distinct from 'expired' then continue; end if;

    v_symbol := v_result ->> 'symbol';
    v_price  := nullif(v_result ->> 'settlement_price', '')::numeric;
    if v_symbol is null or v_price is null then continue; end if;

    -- No-op once the positions are gone, so replaying old responses is safe.
    perform public.settle_symbol(
      v_symbol,
      v_price,
      nullif(v_result ->> 'settlement_time', '')::timestamptz
    );
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions. These three run as their owner and range over every account, so
-- the client must not be able to call them. create function grants execute to
-- public by default, which is exactly what we do not want here.
-- ---------------------------------------------------------------------------
revoke all on function public.settle_symbol(text, numeric, timestamptz) from public, anon, authenticated;
revoke all on function public.queue_settlement_checks() from public, anon, authenticated;
revoke all on function public.apply_settlement_responses() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Schedule. pg_cron has to be enabled for the project first:
--   Dashboard > Database > Extensions > pg_cron.
-- Ask on the hour and every ten minutes after; read two minutes behind, which
-- is far longer than the 5s request timeout.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

select cron.schedule(
  'settlement-poll',
  '*/10 * * * *',
  $$select public.queue_settlement_checks()$$
);

select cron.schedule(
  'settlement-apply',
  '2-59/10 * * * *',
  $$select public.apply_settlement_responses()$$
);
