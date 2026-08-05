-- ============================================================================
-- XAUT Options Paper Trading — take-profit / stop-loss
-- Run this whole file in the Supabase SQL Editor (Dashboard > SQL Editor).
-- Requires 0002_settlement.sql to have run (pg_net, pg_cron, the fills.order_id
-- nullable + is_settlement columns are all reused here).
--
-- A TP/SL is a resting exit that watches the underlying and closes the position
-- when it is hit. The watching runs server-side on pg_cron, the same way
-- settlement does, so a level fires whether or not the browser is open — which
-- is the whole reason a stop is worth having.
--
-- The trigger is read against the underlying index price, which is the number
-- Delta shows against these levels ("SL (USD): 63860"). The option's own ticker
-- carries that index as `spot_price`, alongside the mark and the book we close
-- at, so one fetch per held symbol answers everything.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The levels, on the position. Null means unset. Index-price terms.
-- ---------------------------------------------------------------------------
alter table public.positions add column if not exists take_profit numeric(20, 8);
alter table public.positions add column if not exists stop_loss numeric(20, 8);

-- ---------------------------------------------------------------------------
-- Set or clear the levels. security invoker, so RLS scopes it to the caller's
-- own position — a user can only arm their own exits. Pass null to clear.
-- ---------------------------------------------------------------------------
create or replace function public.set_position_tpsl(
  p_position_id uuid,
  p_take_profit numeric default null,
  p_stop_loss   numeric default null
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if p_take_profit is not null and p_take_profit <= 0 then
    raise exception 'take profit must be positive';
  end if;
  if p_stop_loss is not null and p_stop_loss <= 0 then
    raise exception 'stop loss must be positive';
  end if;

  update public.positions
  set take_profit = p_take_profit,
      stop_loss = p_stop_loss
  where id = p_position_id;
end;
$$;

grant execute on function public.set_position_tpsl(uuid, numeric, numeric) to authenticated;

-- ---------------------------------------------------------------------------
-- Close one position at a given premium, on a TP/SL hit. The realized-P&L arm
-- is identical to execute_fill and settle_symbol; only the trigger differs.
--
-- security definer because pg_cron is the caller and has no auth.uid(); execute
-- is revoked from the client below.
-- ---------------------------------------------------------------------------
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
    premium, notional, fee, realized_pnl, spot_at_fill, is_settlement
  )
  values (
    null, pos.account_id, pos.user_id, pos.symbol, pos.contract_type, pos.strike_price,
    -- A trigger closes the exposure, so it books as the opposing side.
    case when pos.net_qty > 0 then 'sell' else 'buy' end,
    'market', abs(pos.net_qty), p_price, pos.contract_value,
    p_price * pos.contract_value * abs(pos.net_qty),
    0, 0,   -- no notional/fee recorded on a triggered close, as with settlement
    v_realized, null, false
  );

  update public.accounts
  set cash_balance = cash_balance + v_realized
  where id = pos.account_id;

  delete from public.positions where id = pos.id;

  raise notice 'closed % on % at % (%)', p_position_id, pos.symbol, p_price, p_reason;
end;
$$;

-- ---------------------------------------------------------------------------
-- Ask Delta for the ticker of every held symbol that has a level armed. One
-- call per symbol; the reply carries the index, the mark and the book.
-- ---------------------------------------------------------------------------
create or replace function public.queue_tpsl_checks()
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
    select distinct symbol
    from public.positions
    where take_profit is not null or stop_loss is not null
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
-- Read the fresh replies and fire whatever has crossed.
--
-- The trigger is on the index. Which way it must move depends on the position's
-- directional exposure: long a call or short a put is bullish (gains as the
-- underlying rises); short a call or long a put is bearish. Take-profit fires on
-- the profitable side, stop-loss on the losing side.
--
-- Only replies from the last 90s are used — a stale index would fire a stop at a
-- price that has since moved. The close books at the exit side of the book (bid
-- for a long, ask for a short), falling back to the mark if that side is empty.
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
  v_symbol  text;
  v_spot    numeric;
  v_bid     numeric;
  v_ask     numeric;
  v_mark    numeric;
  pos       public.positions;
  v_bullish boolean;
  v_long    boolean;
  v_hit_tp  boolean;
  v_hit_sl  boolean;
  v_exit    numeric;
  v_n       integer := 0;
begin
  -- Freshest reply per symbol from the recent window.
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
    if v_spot is null then continue; end if;

    v_mark := nullif(res ->> 'mark_price', '')::numeric;
    v_bid  := nullif(res -> 'quotes' ->> 'best_bid', '')::numeric;
    v_ask  := nullif(res -> 'quotes' ->> 'best_ask', '')::numeric;

    -- Every armed position on this symbol (there can be more than one account).
    for pos in
      select * from public.positions
      where symbol = resp.symbol
        and (take_profit is not null or stop_loss is not null)
    loop
      v_long := pos.net_qty > 0;
      v_bullish := (pos.contract_type = 'call_options') = v_long;

      v_hit_tp := pos.take_profit is not null and (
        case when v_bullish then v_spot >= pos.take_profit else v_spot <= pos.take_profit end
      );
      v_hit_sl := pos.stop_loss is not null and (
        case when v_bullish then v_spot <= pos.stop_loss else v_spot >= pos.stop_loss end
      );

      if not (v_hit_tp or v_hit_sl) then continue; end if;

      v_exit := case when v_long then coalesce(v_bid, v_mark) else coalesce(v_ask, v_mark) end;
      if v_exit is null then continue; end if; -- cannot price the close yet

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end
      );
      v_n := v_n + 1;
    end loop;
  end loop;

  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Permissions: the three engine functions run as owner across every account,
-- so the client must never call them. set_position_tpsl is the only one it may.
-- ---------------------------------------------------------------------------
revoke all on function public.close_position_triggered(uuid, numeric, text) from public, anon, authenticated;
revoke all on function public.queue_tpsl_checks() from public, anon, authenticated;
revoke all on function public.apply_tpsl_triggers() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Schedule. pg_cron and pg_net were enabled by 0002. Sub-minute so a stop is
-- not minutes late; poll and apply on the same cadence, apply reads the last 90s
-- of replies so it always has the previous poll's answers to work from.
-- ---------------------------------------------------------------------------
select cron.schedule('tpsl-poll', '15 seconds', $$select public.queue_tpsl_checks()$$);
select cron.schedule('tpsl-apply', '15 seconds', $$select public.apply_tpsl_triggers()$$);
