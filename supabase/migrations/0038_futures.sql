-- 0038_futures.sql
--
-- Run this whole file in the Supabase SQL Editor after 0037_auto_trailing_stop.sql.
--
-- A fourth book: the XAUT perpetual future, traded by hand from a page of its
-- own. Delta India lists exactly one non-option XAUT contract --
--
--     XAUTUSD   perpetual_futures   cv 0.001 XAUT   tick 0.01
--               IM 1%   MM 0.5%   max leverage 100x   funding every 8h
--
-- -- so there is no chain to draw and no expiry to pick. One symbol, one row,
-- long or short.
--
-- ---------------------------------------------------------------------------
-- What had to give
-- ---------------------------------------------------------------------------
-- The schema was written for options and says so in three places, all of which
-- a perpetual fails:
--
--     orders.contract_type   check (... in ('call_options', 'put_options'))
--     {orders,positions,fills}.strike_price   not null
--     accounts.kind          check (... in ('manual', 'auto', 'delta'))
--
-- A perpetual has no strike and never expires, so `strike_price` becomes
-- nullable rather than gaining a sentinel: null is the honest answer and every
-- reader already handles a missing number. `expiry_label` stays not-null and
-- carries the literal 'PERP' -- it is a display string, it is never parsed as a
-- date, and a fourth nullable column to say "no expiry" would buy nothing.
--
-- ---------------------------------------------------------------------------
-- Leverage
-- ---------------------------------------------------------------------------
-- The one genuinely new field. An option's margin follows from the contract; a
-- perpetual's follows from the leverage the trader picked when they opened it,
-- so it has to be stored per position. It rides on the order and `execute_fill`
-- copies it across, the same way `contract_value` already travels.
--
-- Null on every option, and on anything written before this file ran.
--
-- The venue floors it at the product's own initial margin -- 1%, i.e. 100x --
-- and that floor is enforced client-side in the ticket rather than as a
-- constraint here, because the number that has to be beaten lives on the
-- product and would go stale the moment Delta moved it.
--
-- ---------------------------------------------------------------------------
-- Funding
-- ---------------------------------------------------------------------------
-- A perpetual never settles; it pays funding instead, and a paper book that
-- skips it drifts from the real one inside a day. `product_specs.expiry_interval`
-- is 28800 -- eight hours -- so funding falls at 00:00, 08:00 and 16:00 UTC
-- (05:30, 13:30, 21:30 IST). `funding_method` is `mark_price`:
--
--     payment = mark x contract_value x |net_qty| x funding_rate / 100
--
-- `funding_rate` is a percentage for the period and is read live off the ticker.
-- Positive means longs pay shorts, which is the sign convention below: the
-- payment is *debited* from a long and *credited* to a short.
--
-- Charged to positions open *before* the boundary, so a position opened in the
-- gap between the boundary and the pass that notices it is not billed for a
-- period it did not hold through. `funding_payments` carries a unique key on
-- (account, symbol, funding_time), which is what makes an overlapping pass or a
-- re-run harmless.
--
-- ---------------------------------------------------------------------------
-- Liquidation
-- ---------------------------------------------------------------------------
-- The other thing a perpetual has that an option does not. At 100x a 1% move is
-- the whole margin, and a paper account that carries a position straight through
-- that is not teaching anyone anything.
--
-- The book is cross-margined -- `available = equity - margin`, account-wide --
-- so the test is account-wide too, not a per-position liquidation price:
--
--     equity = cash + unrealized      maintenance = 0.5% x mark x cv x |qty|
--     liquidate when equity < maintenance
--
-- and the whole book goes, at the mark, booked as `close_reason = 'liquidation'`.
-- Delta liquidates in steps and takes a penalty out of the remaining margin; this
-- does neither. Closing the lot at the mark is the conservative simplification --
-- it never leaves an account alive that the venue would have taken, and it never
-- invents a penalty the venue's own numbers do not tell us the size of.
--
-- The 0.5% is the product's published `maintenance_margin` and is written here as
-- a constant, deliberately: it is one number on one contract, and reading it
-- through another HTTP hop every five seconds to find out it is still 0.5 would
-- be worse in every respect than a line that has to be edited if Delta moves it.
--
-- Scoped to accounts of kind 'futures', which by construction hold nothing but
-- perpetuals -- so the equity sum needs no option marks and cannot be thrown off
-- by a leg whose greeks have not arrived.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The fourth kind
-- ---------------------------------------------------------------------------
alter table public.accounts drop constraint if exists accounts_kind_chk;
alter table public.accounts
  add constraint accounts_kind_chk check (kind in ('manual', 'auto', 'delta', 'futures'));

-- ---------------------------------------------------------------------------
-- 2. A contract with no strike
-- ---------------------------------------------------------------------------
alter table public.orders drop constraint if exists orders_contract_type_check;
alter table public.orders
  add constraint orders_contract_type_check
  check (contract_type in ('call_options', 'put_options', 'perpetual_futures'));

alter table public.orders    alter column strike_price drop not null;
alter table public.positions alter column strike_price drop not null;
alter table public.fills     alter column strike_price drop not null;

comment on column public.positions.strike_price is
  'Null on a perpetual, which has no strike. Every reader treats it as absent.';

-- ---------------------------------------------------------------------------
-- 3. Leverage, carried from the order onto the position
-- ---------------------------------------------------------------------------
alter table public.orders    add column if not exists leverage numeric(20, 8);
alter table public.positions add column if not exists leverage numeric(20, 8);

alter table public.orders    drop constraint if exists orders_leverage_chk;
alter table public.orders    add constraint orders_leverage_chk
  check (leverage is null or leverage > 0);
alter table public.positions drop constraint if exists positions_leverage_chk;
alter table public.positions add constraint positions_leverage_chk
  check (leverage is null or leverage > 0);

comment on column public.positions.leverage is
  'The leverage this perpetual was opened at; margin is notional / leverage. Null on options.';

-- ---------------------------------------------------------------------------
-- 4. execute_fill, recreated only to carry leverage across
--
-- Line for line the 0001 function apart from the two leverage clauses. An
-- increase in exposure adopts the incoming order's leverage -- that is what the
-- trader just chose -- while a reduce leaves the position's own setting alone,
-- since a closing order carries none.
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
          -- Only an order that adds exposure restates the leverage.
          leverage = case when abs(v_new_qty) > abs(positions.net_qty)
                          then coalesce(o.leverage, positions.leverage)
                          else positions.leverage end;
  end if;

  -- Cash moves only on realized P&L and fees. Unrealized stays off the balance.
  update public.accounts
  set cash_balance = cash_balance + v_realized - p_fee
  where id = o.account_id;

  return v_fill;
end;
$$;

grant execute on function public.execute_fill(uuid, integer, numeric, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. apply_tpsl_triggers: a perpetual is bullish when it is long
--
-- The bracket engine decided direction with
--
--     v_bullish := (pos.contract_type = 'call_options') = v_long;
--
-- which reads a perpetual as a put -- long XAUTUSD would have been treated as a
-- bearish exposure and its take-profit would have fired on the index *falling*.
-- A non-option has no such inversion: long is bullish, short is bearish, and the
-- mark branch already says exactly that, which is why only the index branch
-- needed the case split.
--
-- Otherwise identical to the 0036 function, including the delta-book reason it
-- writes for accounts of that kind.
-- ---------------------------------------------------------------------------
create or replace function public.apply_tpsl_triggers()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  resp      record;
  res       jsonb;
  v_spot    numeric;
  v_bid     numeric;
  v_ask     numeric;
  v_mark    numeric;
  pos       public.positions;
  v_bullish boolean;
  v_long    boolean;
  v_ref     numeric;
  v_up      boolean;
  v_hit_tp  boolean;
  v_hit_sl  boolean;
  v_exit    numeric;
  v_n       integer := 0;
  -- The delta book's reason, for a bracket that fires on one of its legs.
  v_delta   boolean;
  v_dp      numeric;
begin
  for resp in
    select distinct on (symbol) symbol, content
    from (
      select (r.content::jsonb -> 'result' ->> 'symbol') as symbol,
             r.content,
             r.created
      from net._http_response r
      where r.status_code = 200
        and r.created > now() - interval '90 seconds'
    ) s
    where s.symbol is not null
    order by s.symbol, s.created desc
  loop
    begin
      res := resp.content::jsonb -> 'result';
    exception when others then
      continue;
    end;

    v_spot := nullif(res ->> 'spot_price', '')::numeric;
    v_mark := nullif(res ->> 'mark_price', '')::numeric;
    v_bid  := nullif(res -> 'quotes' ->> 'best_bid', '')::numeric;
    v_ask  := nullif(res -> 'quotes' ->> 'best_ask', '')::numeric;

    for pos in
      select * from public.positions
      where symbol = resp.symbol
        and (take_profit is not null or stop_loss is not null)
    loop
      v_long := pos.net_qty > 0;
      -- An option inverts on the put side; anything else is bullish when long.
      v_bullish := case
        when pos.contract_type = 'call_options' then v_long
        when pos.contract_type = 'put_options'  then not v_long
        else v_long
      end;

      -- Pick the reference and the direction its rise means profit in.
      if pos.tpsl_trigger = 'mark' then
        v_ref := v_mark;
        v_up  := v_long;      -- a long option gains as its own mark rises
      else
        v_ref := v_spot;
        v_up  := v_bullish;   -- a bullish exposure gains as the index rises
      end if;
      if v_ref is null then continue; end if; -- reference not published yet

      v_hit_tp := pos.take_profit is not null and (
        case when v_up then v_ref >= pos.take_profit else v_ref <= pos.take_profit end
      );
      v_hit_sl := pos.stop_loss is not null and (
        case when v_up then v_ref <= pos.stop_loss else v_ref >= pos.stop_loss end
      );

      if not (v_hit_tp or v_hit_sl) then continue; end if;

      -- The close still books at the exit side of the book, mark as backstop.
      v_exit := case when v_long then coalesce(v_bid, v_mark) else coalesce(v_ask, v_mark) end;
      if v_exit is null then continue; end if;

      -- Read before the close, or dp would already have the leg missing from it.
      v_delta := exists (
        select 1 from public.accounts a where a.id = pos.account_id and a.kind = 'delta'
      );
      v_dp := case when v_delta then public.delta_book_dp(pos.account_id) end;

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end
      );

      -- No target: a bracket answers to the option's own price, not to the band.
      if v_delta then
        perform public.delta_reason(
          pos.account_id,
          case when v_hit_tp then 'take_profit' else 'stop_loss' end,
          v_spot, v_dp);
      end if;

      v_n := v_n + 1;
    end loop;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Funding ledger
--
-- One row per position per funding boundary. The unique key is the whole
-- mechanism: every pass tries to insert, and the second one loses.
-- ---------------------------------------------------------------------------
create table if not exists public.funding_payments (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.accounts (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  symbol        text not null,
  funding_time  timestamptz not null,
  -- The rate as the venue quotes it: a percentage for the eight-hour period.
  funding_rate  numeric(20, 8) not null,
  mark_price    numeric(20, 8) not null,
  net_qty       integer not null,
  -- Signed in the account's favour: negative is paid away, positive received.
  amount        numeric(20, 8) not null,
  created_at    timestamptz not null default now(),
  unique (account_id, symbol, funding_time)
);

create index if not exists funding_account_idx
  on public.funding_payments (account_id, funding_time desc);

alter table public.funding_payments enable row level security;

drop policy if exists funding_owner_read on public.funding_payments;
create policy funding_owner_read on public.funding_payments
  for select to authenticated using (user_id = auth.uid());

-- The eight-hour boundary at or before a moment: 00:00, 08:00, 16:00 UTC.
create or replace function public.funding_period(p_at timestamptz)
returns timestamptz
language sql
immutable
as $$
  select to_timestamp(floor(extract(epoch from p_at) / 28800) * 28800);
$$;

-- ---------------------------------------------------------------------------
-- 7. The poller: one ticker per held perpetual
--
-- Separate from queue_tpsl_checks, which only asks about symbols with a bracket
-- armed. Liquidation and funding apply to every open perpetual, armed or not.
-- ---------------------------------------------------------------------------
create or replace function public.queue_futures_checks()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r   record;
  v_n integer := 0;
begin
  for r in
    select distinct p.symbol
    from public.positions p
    where p.contract_type = 'perpetual_futures' and p.net_qty <> 0
  loop
    perform net.http_get(
      url := 'https://api.india.delta.exchange/v2/tickers/' || r.symbol,
      timeout_milliseconds := 5000
    );
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. The applier: funding when a boundary has passed, then liquidation
--
-- Funding first, deliberately. It moves cash, and an account that the payment
-- itself pushes under maintenance should be liquidated on this pass rather than
-- the next one -- which is exactly the order the venue applies them in.
--
-- Only ticker replies are read. The settlement poller puts *product* payloads in
-- the same table under the same symbol, and those carry no mark; the
-- contract_type test below is what tells the two apart.
-- ---------------------------------------------------------------------------
create or replace function public.apply_futures_maintenance()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  -- The product's published maintenance margin, as a fraction. See the header.
  c_mm_rate constant numeric := 0.005;

  resp     record;
  res      jsonb;
  v_mark   numeric;
  v_rate   numeric;
  v_period timestamptz := public.funding_period(now());
  pos      public.positions;
  acct     record;
  v_amount numeric;
  v_equity numeric;
  v_maint  numeric;
  v_n      integer := 0;
  -- Freshest mark per perpetual symbol this pass, for the equity sum below.
  v_marks  jsonb := '{}'::jsonb;
begin
  for resp in
    select distinct on (symbol) symbol, content
    from (
      select (r.content::jsonb -> 'result' ->> 'symbol') as symbol,
             r.content,
             r.created
      from net._http_response r
      where r.status_code = 200
        and r.created > now() - interval '90 seconds'
    ) s
    where s.symbol is not null
    order by s.symbol, s.created desc
  loop
    begin
      res := resp.content::jsonb -> 'result';
    exception when others then
      continue;
    end;

    -- Tickers only, and only perpetuals: a product payload has no mark_price and
    -- an option ticker is none of this function's business.
    if coalesce(res ->> 'contract_type', '') <> 'perpetual_futures' then
      continue;
    end if;

    v_mark := nullif(res ->> 'mark_price', '')::numeric;
    v_rate := nullif(res ->> 'funding_rate', '')::numeric;
    if v_mark is null then continue; end if;

    v_marks := v_marks || jsonb_build_object(resp.symbol, v_mark);

    -- ---- Funding -----------------------------------------------------------
    -- Held through the boundary, and not already billed for it. The unique key
    -- on funding_payments makes the second attempt a no-op rather than a double
    -- charge, so two overlapping passes are safe.
    if v_rate is not null then
      for pos in
        select * from public.positions
        where symbol = resp.symbol
          and contract_type = 'perpetual_futures'
          and net_qty <> 0
          and opened_at < v_period
      loop
        -- Positive rate: longs pay. The sign here is the account's, so a long
        -- gets a negative amount and a short a positive one.
        v_amount := -1 * sign(pos.net_qty) * v_rate / 100
                    * v_mark * pos.contract_value * abs(pos.net_qty);

        begin
          insert into public.funding_payments (
            account_id, user_id, symbol, funding_time,
            funding_rate, mark_price, net_qty, amount
          )
          values (
            pos.account_id, pos.user_id, pos.symbol, v_period,
            v_rate, v_mark, pos.net_qty, v_amount
          );
        exception when unique_violation then
          continue;  -- already billed for this boundary
        end;

        update public.accounts
        set cash_balance = cash_balance + v_amount
        where id = pos.account_id;

        v_n := v_n + 1;
      end loop;
    end if;
  end loop;

  -- ---- Liquidation ---------------------------------------------------------
  -- Account-wide, because the book is cross-margined. An account is skipped
  -- whenever any leg it holds has no fresh mark this pass: a partial equity is
  -- worse than no test at all, and the next pass is five seconds away.
  for acct in
    select a.id
    from public.accounts a
    where a.kind = 'futures'
      and exists (select 1 from public.positions p
                  where p.account_id = a.id and p.net_qty <> 0)
  loop
    if exists (
      select 1 from public.positions p
      where p.account_id = acct.id and p.net_qty <> 0
        and v_marks -> p.symbol is null
    ) then
      continue;
    end if;

    select a.cash_balance
             + coalesce(sum(case when p.net_qty > 0
                                 then ((v_marks ->> p.symbol)::numeric - p.avg_entry_price)
                                 else (p.avg_entry_price - (v_marks ->> p.symbol)::numeric)
                            end * abs(p.net_qty) * p.contract_value), 0),
           coalesce(sum(c_mm_rate * (v_marks ->> p.symbol)::numeric
                        * p.contract_value * abs(p.net_qty)), 0)
      into v_equity, v_maint
    from public.accounts a
    left join public.positions p on p.account_id = a.id and p.net_qty <> 0
    where a.id = acct.id
    group by a.cash_balance;

    if v_equity is null or v_equity >= v_maint then continue; end if;

    -- Under maintenance: the whole book goes, at the mark.
    for pos in
      select * from public.positions where account_id = acct.id and net_qty <> 0
    loop
      perform public.close_position_triggered(
        pos.id, (v_marks ->> pos.symbol)::numeric, 'liquidation'
      );
      v_n := v_n + 1;
    end loop;

    raise log 'apply_futures_maintenance: liquidated account % -- equity % under maintenance %',
      acct.id, round(v_equity, 2), round(v_maint, 2);
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Schedules
--
-- The same five-second poll/apply pair the brackets use, and for the same
-- reason: at 100x leverage the interval between passes is the error in the
-- liquidation price. Funding only does work three times a day but rides the
-- same pass, since it needs the identical ticker reply.
-- ---------------------------------------------------------------------------
select cron.schedule('futures-poll',  '5 seconds', $$select public.queue_futures_checks()$$);
select cron.schedule('futures-apply', '5 seconds', $$select public.apply_futures_maintenance()$$);
