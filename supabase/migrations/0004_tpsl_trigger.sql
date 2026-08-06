-- ============================================================================
-- XAUT Options Paper Trading — TP/SL trigger source (index or mark)
-- Run this whole file in the Supabase SQL Editor after 0003_tpsl.sql.
--
-- A bracket can now watch either the underlying index or the option's own mark
-- price. The two are not interchangeable — they carry different units (an index
-- level is ~4,200; a mark level is a few dollars of premium) and, crucially,
-- different direction logic:
--
--   * On the INDEX, a bullish exposure (long call / short put) profits as the
--     underlying rises. So the "profit side" is bullishness.
--   * On the MARK, the level tracks the option's own premium, and a LONG
--     position profits as that premium rises regardless of call or put. So the
--     "profit side" is simply long/short.
--
-- One selector per bracket, covering both TP and SL, the way Delta's trigger
-- price type does.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Which price the levels watch. Defaults to 'index', the prior behaviour, so
-- every existing bracket keeps firing exactly as it did.
-- ---------------------------------------------------------------------------
alter table public.positions
  add column if not exists tpsl_trigger text not null default 'index';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'positions_tpsl_trigger_chk'
  ) then
    alter table public.positions
      add constraint positions_tpsl_trigger_chk check (tpsl_trigger in ('index', 'mark'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Set or clear the levels, now taking the trigger source. Replaces the 3-arg
-- form from 0003; drop that so the client only ever sees the new one.
-- ---------------------------------------------------------------------------
drop function if exists public.set_position_tpsl(uuid, numeric, numeric);

create or replace function public.set_position_tpsl(
  p_position_id uuid,
  p_take_profit numeric default null,
  p_stop_loss   numeric default null,
  p_trigger     text    default 'index'
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
  if p_trigger not in ('index', 'mark') then
    raise exception 'trigger must be index or mark';
  end if;

  update public.positions
  set take_profit = p_take_profit,
      stop_loss = p_stop_loss,
      tpsl_trigger = p_trigger
  where id = p_position_id;
end;
$$;

grant execute on function public.set_position_tpsl(uuid, numeric, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Read the fresh ticker replies and fire whatever has crossed — now against the
-- reference each position chose. The reply already carries both the index
-- (spot_price) and the option mark (mark_price), so no extra fetch is needed;
-- queue_tpsl_checks from 0003 is unchanged.
--
-- v_ref is the watched price; v_up is whether that reference rising is the
-- profitable direction. Take-profit fires on the profit side, stop-loss on the
-- losing side, exactly as before — only the reference and its direction change.
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

      perform public.close_position_triggered(
        pos.id, v_exit, case when v_hit_tp then 'take_profit' else 'stop_loss' end
      );
      v_n := v_n + 1;
    end loop;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_tpsl_triggers() from public, anon, authenticated;
