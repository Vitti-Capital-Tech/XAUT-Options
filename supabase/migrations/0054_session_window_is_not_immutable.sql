-- 0054_session_window_is_not_immutable.sql
--
-- Run this whole file in the Supabase SQL Editor after 0053.
--
-- delta_session_window has been marked `immutable` since 0051, and it reads
-- now(). Those two cannot both be true.
--
-- `immutable` is a promise to the planner: same arguments, same answer, forever.
-- On the strength of it PostgreSQL is allowed to evaluate the call once and reuse
-- the value — folding it to a constant at plan time when the arguments are
-- constants, which is exactly what a custom plan makes them. apply_delta_strategy
-- calls this once per armed account through a cached plpgsql plan, inside a
-- pg_cron worker whose backend lives for hours, so the window the engine thinks
-- it is in can be decided once and then never re-read.
--
-- Everything downstream hangs off that one answer:
--
--     if v_phase <> 'open' then ... flatten ...; continue; end if;
--
-- A stale 'closed' means the engine flattens and skips the rest of the cycle —
-- no ATM check, no hedge, no band correction — so delta stops being managed while
-- the tab still shows the strategy armed and the row still shows last_cycle
-- ticking. A stale 'open' is the mirror image: it keeps trading a window that
-- closed. Which one you get depends on when the backend first built the plan,
-- which is why this reads as intermittent rather than broken.
--
-- delta_session, the single-window function this was modelled on, has been
-- `stable` since 0022 for the same reason ([`0022`](0022_delta_session_ist.sql)).
-- `stable` is the correct marker for anything reading now(): fixed within one
-- statement, re-read on the next.
--
-- The body is byte-for-byte 0051's. Only the volatility marker changes.
-- ============================================================================

create or replace function public.delta_session_window(
  p_windows     jsonb,
  p_trade_days  smallint[],
  out phase     text,
  out sday      text,
  out active_win jsonb
)
language plpgsql
-- 0054: was `immutable`, which let the planner freeze the answer. See the header.
stable
as $$
declare
  v_now_ist timestamp;
  v_dow     int;
  v_mins    int;
  v_win     jsonb;
  v_start   text;
  v_end     text;
  v_s_min   int;
  v_e_min   int;
  v_open    boolean;
  v_today   text;
begin
  v_now_ist := now() at time zone 'Asia/Kolkata';
  v_dow     := extract(isodow from v_now_ist)::int;
  v_mins    := extract(hour from v_now_ist)::int * 60 + extract(minute from v_now_ist)::int;
  v_today   := to_char(v_now_ist, 'YYYY-MM-DD');

  phase      := 'closed';
  sday       := v_today;
  active_win := null;

  if p_trade_days is not null and not (v_dow = any(p_trade_days)) then
    return;
  end if;

  if p_windows is null or jsonb_array_length(p_windows) = 0 then
    return;
  end if;

  for v_win in select * from jsonb_array_elements(p_windows)
  loop
    v_start := coalesce(v_win ->> 'startTime', v_win ->> 'start_time', '01:30');
    v_end   := coalesce(v_win ->> 'endTime', v_win ->> 'end_time', '17:00');

    v_s_min := split_part(v_start, ':', 1)::int * 60 + split_part(v_start, ':', 2)::int;
    v_e_min := split_part(v_end, ':', 1)::int * 60 + split_part(v_end, ':', 2)::int;

    if v_s_min <= v_e_min then
      v_open := (v_mins >= v_s_min and v_mins <= v_e_min);
      sday   := v_today;
    else
      -- Midnight-wrapping window
      if v_mins >= v_s_min then
        v_open := true;
        sday   := v_today;
      elsif v_mins <= v_e_min then
        v_open := true;
        sday   := to_char(v_now_ist - interval '1 day', 'YYYY-MM-DD');
      else
        v_open := false;
      end if;
    end if;

    if v_open then
      phase      := 'open';
      active_win := v_win;
      return;
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Sanity check
-- ---------------------------------------------------------------------------
-- Catches the same mistake in any sibling: a function that reads the clock and
-- claims to be immutable is always wrong, and it always fails intermittently,
-- which is the worst way for it to fail.
do $$
declare
  v_bad text;
begin
  select string_agg(pr.proname, ', ')
    into v_bad
  from pg_proc pr
  join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public'
    and pr.provolatile = 'i'
    and pr.prosrc ~ '\mnow\s*\(';

  if v_bad is not null then
    raise exception 'immutable function(s) reading now(): % — must be stable', v_bad;
  end if;

  if (select provolatile from pg_proc pr
      join pg_namespace ns on ns.oid = pr.pronamespace
      where ns.nspname = 'public' and pr.proname = 'delta_session_window') <> 's' then
    raise exception 'delta_session_window is still not stable';
  end if;

  raise log '0054: delta_session_window is stable; no immutable function reads the clock';
end;
$$;
