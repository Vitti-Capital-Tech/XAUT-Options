-- 0034_delta_tpsl_remarks.sql
--
-- Run this whole file in the Supabase SQL Editor after 0033_delta_remarks.sql.
--
-- The remarks log had a hole in it, and it was the loudest kind: a leg would
-- vanish from the book with nothing in the log to say why.
--
-- Every rule in `apply_delta_strategy` writes a remark now — but the take-profit
-- and the stop are not that engine's. They are armed by it (`take_profit_mark`,
-- `stop_loss_mark`, set at fill time) and then fired by `apply_tpsl_triggers`,
-- the bracket sweep shared with the chain and the auto strategy, on its own
-- 5-second cron. So a $4 short bought back at $0.70 was a Trade History row
-- labelled `Take Profit` and a silent step in Δp that the *next* delta remark
-- would report as a fait accompli.
--
-- This closes that: when a bracket fires on a position in a `delta` account, it
-- writes its own remark — the price it watched, the level it crossed, what it
-- closed, and Δp either side of it.
--
-- ---------------------------------------------------------------------------
-- Why it is two more actions rather than reusing `exit`
-- ---------------------------------------------------------------------------
-- `exit` means one specific thing in this log: the side's roll budget was spent,
-- so a band breach was resolved by closing in full instead of rolling. A bracket
-- firing is not that. It answers to the option's own price, not to Δp — it can
-- fire with Δp dead centre in the band, on a day the engine has done nothing at
-- all. Folding the two together would make the column lie about which rule ran,
-- so `take_profit` and `stop_loss` join the vocabulary, named the way
-- `fills.close_reason` already names them.
--
-- `dp_target` is null on both, and that is the honest reading: a bracket has no
-- delta it is aiming for. `dp_before` and `dp_after` are still recorded, because
-- the *consequence* is a delta move — usually the reason the next cycle rolls or
-- corrects, and now traceable to the leg that left.

-- ---------------------------------------------------------------------------
-- 1. Two more actions
-- ---------------------------------------------------------------------------
alter table public.delta_remarks drop constraint if exists delta_remarks_action_chk;

alter table public.delta_remarks
  add constraint delta_remarks_action_chk
  check (action in ('entry', 'roll', 'exit', 'band', 'cut', 'flatten', 'hold', 'wait',
                    -- Fired by the bracket sweep below, not by the delta engine.
                    'take_profit', 'stop_loss'));

-- ---------------------------------------------------------------------------
-- 2. The bracket sweep, remarking on delta accounts
-- ---------------------------------------------------------------------------
-- Body is 0004's, unchanged in what it fires and when. The additions are three
-- lines around the close: read whether this position belongs to a delta account,
-- read Δp before the leg goes, and write the remark after it has.
--
-- Cost on the hot path is nil. Both reads sit *after* the crossing test, so a
-- sweep that fires nothing does no extra work at all — and a sweep that fires
-- something has already decided to write three tables.
--
-- The account-kind test is what keeps this out of the other two books: the chain
-- and the auto strategy have no remarks log, and a `delta_remarks` row for a
-- manual account would have no reader and a meaningless Δp.
--
-- Δp is read off `delta_chain`, which `apply_delta_strategy` refreshes at the top
-- of every cycle before it looks at whether anything is armed — so the figure is
-- at most a few seconds old even when the strategy is paused. If the chain has
-- gone stale (delta cron down), `delta_book_dp` returns null for any leg without
-- a row, and the remark says "unknown" rather than a wrong number.
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
  -- The delta book's remark, for a bracket that fires on one of its legs.
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
      v_bullish := (pos.contract_type = 'call_options') = v_long;

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

      -- Read before the close, or Δp would already have the leg missing from it.
      v_delta := exists (
        select 1 from public.accounts a where a.id = pos.account_id and a.kind = 'delta'
      );
      v_dp := case when v_delta then public.delta_book_dp(pos.account_id) end;

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end
      );

      if v_delta then
        perform public.delta_remark(
          pos.account_id, pos.user_id,
          case when v_hit_tp then 'take_profit' else 'stop_loss' end,
          format('%s on %s — the %s reached $%s against the level $%s, so all %s lot(s) were closed at $%s. This is the bracket firing on the leg''s own price, not a delta decision: net delta moves with it, and the next cycle corrects if that leaves it outside the band.',
                 case when v_hit_tp then 'Take-profit' else 'Stop-loss' end,
                 pos.symbol,
                 case when pos.tpsl_trigger = 'mark' then 'option''s own mark' else 'index' end,
                 round(v_ref, 2),
                 round(case when v_hit_tp then pos.take_profit else pos.stop_loss end, 2),
                 abs(pos.net_qty),
                 round(v_exit, 2)),
          -- The index either way, so the column means one thing down the table:
          -- on a mark-triggered bracket the level crossed is in the note instead.
          v_spot, v_dp, null, pos.symbol, abs(pos.net_qty));
      end if;

      v_n := v_n + 1;
    end loop;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_tpsl_triggers() from public, anon, authenticated;
