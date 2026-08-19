-- 0040_spot_on_every_fill.sql
--
-- Run this whole file in the Supabase SQL Editor after 0039_delta_gamma_band.sql.
--
-- Every fill records the underlying at the moment it happened, so the trade
-- history can show where gold was on each row rather than only what the option
-- traded at.
--
-- ---------------------------------------------------------------------------
-- What was already right, and what was not
-- ---------------------------------------------------------------------------
-- `fills.spot_at_fill` has existed since 0001 and is populated correctly by
-- everything that goes through `execute_fill`: manual trades from the ticket,
-- and every leg either strategy opens or closes, since `delta_close_leg` and
-- `delta_sell` both route through it with the engine's own spot.
--
-- The gap is `close_position_triggered`, which writes a fill directly and passed
-- a literal null for the column. That is not a rare path -- it is every
-- take-profit, every stop, the auto strategy's window close, and the futures
-- book's liquidation. On a delta account running the default 0.70 take-profit it
-- is a large share of the history, and those rows would have been the blank ones
-- in a spot column.
--
-- So the function takes the spot as an argument and its three callers pass the
-- one they are already holding:
--
--     apply_tpsl_triggers          v_spot, off the ticker reply it just read
--     apply_auto_exit              added to the _exit_marks snapshot
--     apply_futures_maintenance    collected beside the mark, per symbol
--
-- The parameter defaults to null rather than being required. There is exactly
-- one function after the drop below, so a three-argument call still resolves to
-- it -- an overload would have silently kept old callers writing nulls, which is
-- the failure this file exists to fix.
--
-- ---------------------------------------------------------------------------
-- `notional` comes along with it
-- ---------------------------------------------------------------------------
-- The same insert wrote `notional = 0`, with the honest reason that notional is
-- `spot x contract_value x qty` and there was no spot to compute it from. There
-- is one now, so it is computed. Strictly this is more than "record the spot",
-- but a zero notional sitting next to a correct spot on the same row is a wrong
-- number that the row itself now contains the means to fix, and leaving it would
-- be choosing to keep it wrong.
--
-- Only new rows are affected. Nothing is backfilled: the spot at the time of a
-- fill that has already happened is not recoverable from anything this database
-- holds, and inventing it from today's price would be worse than the dash.
--
-- ---------------------------------------------------------------------------
-- Settlement is deliberately still blank
-- ---------------------------------------------------------------------------
-- `settle_symbol` (0002) also writes a null spot and says why: it is driven by
-- the *option's* settlement price off the product, and the underlying's price at
-- the settlement instant is not in that payload. Fetching it would be another
-- HTTP hop for a row that is not a trade anybody took -- the history already
-- labels it Settlement. Left alone.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The fill writer, now told where the underlying was
--
-- Dropped rather than replaced: the signature changes, and `create or replace`
-- with new parameters creates a second function instead of replacing the first.
-- Two overloads would leave three-argument callers binding to the old one and
-- still writing nulls.
-- ---------------------------------------------------------------------------
drop function if exists public.close_position_triggered(uuid, numeric, text);

create or replace function public.close_position_triggered(
  p_position_id uuid,
  p_price       numeric,
  p_reason      text,
  -- The underlying at the moment of the close. Null only where no caller can
  -- know it, which after this file is settlement alone.
  p_spot        numeric default null
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
    -- Computable now that the spot is passed in; still 0 when it is not.
    coalesce(p_spot, 0) * pos.contract_value * abs(pos.net_qty),
    0,      -- no taker fee: the engine closed this, nobody crossed a spread for it
    v_realized, p_spot, false, p_reason
  );

  update public.accounts
  set cash_balance = cash_balance + v_realized
  where id = pos.account_id;

  delete from public.positions where id = pos.id;

  raise notice 'closed % on % at % (%)', p_position_id, pos.symbol, p_price, p_reason;
end;
$$;

revoke all on function public.close_position_triggered(uuid, numeric, text, numeric)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The auto strategy's window close
--
-- Unchanged from 0016 but for the spot: `_exit_marks` carries it out of the same
-- ticker payload the bid, ask and mark already come from, and the close passes it.
-- ---------------------------------------------------------------------------
create or replace function public.apply_auto_exit()
returns integer
language plpgsql
security definer
set search_path = public, net
as $$
declare
  r      record;
  pos    record;
  v_exit numeric;
  v_spot numeric;
  v_n    integer := 0;
begin
  -- Nothing to do on the overwhelming majority of ticks; check that before
  -- parsing a single reply.
  if not exists (
    select 1
    from public.positions p
    join public.strategy_settings s on s.account_id = p.account_id
    where s.armed and p.net_qty <> 0
      and not public.in_ist_window(s.window_start, s.window_end, s.trade_days)
  ) then
    return 0;
  end if;

  -- Freshest reply per symbol. The per-symbol ticker replies are bare objects;
  -- prefiltering on that as text keeps the (near-megabyte) chain replies from
  -- being parsed as jsonb at all, the way apply_strategy does.
  drop table if exists _exit_marks;
  create temp table _exit_marks on commit drop as
  select distinct on (sym)
         sym                                                as symbol,
         nullif(res -> 'quotes' ->> 'best_bid', '')::numeric as bid,
         nullif(res -> 'quotes' ->> 'best_ask', '')::numeric as ask,
         nullif(res ->> 'mark_price', '')::numeric           as mark,
         -- The underlying at the moment of the exit, so the fill can record it.
         nullif(res ->> 'spot_price', '')::numeric           as spot
  from (
    select content::jsonb -> 'result' ->> 'symbol' as sym,
           content::jsonb -> 'result'              as res,
           created
    from net._http_response
    where status_code = 200
      and created > now() - interval '90 seconds'
      and content like '%"result":{%'
  ) s
  where sym is not null
  order by sym, created desc;

  for r in
    select s.account_id
    from public.strategy_settings s
    where s.armed
      and not public.in_ist_window(s.window_start, s.window_end, s.trade_days)
      and exists (
        select 1 from public.positions p
        where p.account_id = s.account_id and p.net_qty <> 0
      )
  loop
    for pos in
      select id, symbol, net_qty from public.positions
      where account_id = r.account_id and net_qty <> 0
    loop
      -- A long exits on the bid, a short on the ask; the mark stands in when
      -- that side of the book is momentarily empty.
      select case when pos.net_qty > 0 then coalesce(bid, mark) else coalesce(ask, mark) end,
             spot
        into v_exit, v_spot
      from _exit_marks where symbol = pos.symbol;

      if v_exit is null or v_exit <= 0 then
        raise log 'apply_auto_exit: account % — no price for % yet, leaving it open',
          r.account_id, pos.symbol;
        continue;
      end if;

      perform public.close_position_triggered(pos.id, v_exit, 'window_close', v_spot);
      v_n := v_n + 1;
    end loop;
  end loop;

  if v_n > 0 then
    raise log 'apply_auto_exit: closed % leg(s) past the window', v_n;
  end if;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. The bracket engine
--
-- Unchanged from 0038 but for the one argument. `v_spot` is read at the top of
-- every reply already -- it is what the index-triggered brackets fire against --
-- so the close has been standing next to the number it needed all along.
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
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end, v_spot
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
-- 4. The futures book's liquidation
--
-- Unchanged from 0038 but for a second jsonb map: the spot per symbol, gathered
-- in the same sweep as the mark. Kept separate from `v_marks` rather than folded
-- into one object because the mark is what the position is *closed at* and the
-- spot is only what is *recorded* -- a missing spot must not skip a liquidation,
-- which is why only the mark is a precondition above.
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
  -- ...and the underlying beside it, so a liquidation fill records where gold was.
  v_spots  jsonb := '{}'::jsonb;
  v_spot   numeric;
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
    v_spot := nullif(res ->> 'spot_price', '')::numeric;
    if v_mark is null then continue; end if;

    v_marks := v_marks || jsonb_build_object(resp.symbol, v_mark);
    if v_spot is not null then
      v_spots := v_spots || jsonb_build_object(resp.symbol, v_spot);
    end if;

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
        pos.id, (v_marks ->> pos.symbol)::numeric, 'liquidation',
        (v_spots ->> pos.symbol)::numeric
      );
      v_n := v_n + 1;
    end loop;

    raise log 'apply_futures_maintenance: liquidated account % -- equity % under maintenance %',
      acct.id, round(v_equity, 2), round(v_maint, 2);
  end loop;

  return v_n;
end;
$$;
