-- 0047_futures_exit_reason.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0046_auto_strategy_buys.sql.
--
-- The futures book's Trade History shows no Exit Reason. One function changes --
-- `apply_tpsl_triggers` -- and only where it decides which books get a reason
-- written.
--
-- ---------------------------------------------------------------------------
-- What was wrong
-- ---------------------------------------------------------------------------
-- Every branch of the engine that trades calls `delta_reason` unconditionally, so
-- a futures flatten, cut, entry and hedge all label their fills. The brackets do
-- not: `0034` gated that call on `accounts.kind = 'delta'`, which was the only
-- engine book that existed at the time, and `0038` through `0045` carried the
-- test forward untouched while adding `futures` beside it.
--
-- So on a futures account the take-profit and the stop-loss -- which are how that
-- book leaves most of its option legs, since a hedged strangle is held to its
-- marks rather than rolled -- closed the position, booked the P&L, wrote
-- `close_reason`, and left `fills.reason` null. The panel had nothing to print
-- and printed a dash, on precisely the rows a trader most wants the sentence for.
--
-- ---------------------------------------------------------------------------
-- The fix, and why it is only a widening
-- ---------------------------------------------------------------------------
-- `kind in ('delta', 'futures')`. Nothing else about the path changes: the same
-- Dp read before the close, the same two actions passed to `delta_reason`, the
-- same null target because a bracket answers to the option's own mark and not to
-- the band.
--
-- `delta_reason` already handles the futures book -- `0044` taught it that a
-- perpetual fill is an exit when it realized something -- and `delta_book_dp`
-- was never kind-scoped, so it reads a futures book's delta including the
-- hedge's. The manual and auto books stay out of it: they have brackets but no
-- engine writing sentences, and a null reason there is correct rather than
-- missing.
--
-- Existing rows are not backfilled. The Dp either side of a close that happened
-- days ago is not recoverable, and a sentence assembled from today's book would
-- be a fabrication on a real trade. Those rows keep their dash; every bracket
-- from here on carries its reason.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- The bracket sweep
-- ---------------------------------------------------------------------------
-- Line for line 0040's, but for the kind test and the flag's name -- `v_engine`
-- rather than `v_delta`, since the question it answers is no longer whether this
-- is the delta book but whether this book's engine has something to say.
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
  -- Whether this leg's book has an engine that writes reason lines, and the
  -- book's net delta read before the close.
  v_engine  boolean;
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
      -- Both engine books, not just the options one: a futures account runs the
      -- same strategy through the same settings row and arms the same brackets,
      -- so a bracket firing on one of its legs has the same reason to give.
      v_engine := exists (
        select 1 from public.accounts a
        where a.id = pos.account_id and a.kind in ('delta', 'futures')
      );
      v_dp := case when v_engine then public.delta_book_dp(pos.account_id) end;

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end, v_spot
      );

      -- No target: a bracket answers to the option's own price, not to the band.
      if v_engine then
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

revoke all on function public.apply_tpsl_triggers() from public, anon, authenticated;
