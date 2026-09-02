-- 0066_the_newest_window_governs.sql
--
-- Run this whole file in the Supabase SQL Editor after 0065.
--
-- Two schedule windows that touch — 08:00-10:00 followed by 10:00-12:00 — are
-- both open on the boundary minute, because 0051 wrote both ends inclusive:
--
--     v_open := (v_mins >= v_s_min and v_mins <= v_e_min);
--
-- and the loop returns on the first match, so array order decided which one
-- governed. In practice that is the window *expiring*, since it is listed first.
-- For that minute the account ran on the settings of a window that was over:
-- its band, its premium, its size, its pairs count and its shift budget.
--
-- The window opening should govern from its start time. That is what its start
-- time means, and it is what the window editor reads as. So when several windows
-- match, the one that started most recently wins.
--
-- Measured as elapsed-since-start, not by comparing start times, because a
-- wrapping window's start belongs to yesterday. At 01:00 a 22:00-02:00 window
-- has been running 180 minutes and a 00:00-06:00 window 60 — the second is the
-- newer, which comparing 1320 against 0 would get backwards. Ties keep array
-- order, so nothing changes for windows that share a start time.
--
-- What this does NOT change, deliberately: adjacent windows still produce no
-- `closed` cycle between them, so there is no flatten at the handover and the
-- first window's legs carry into the second, which then opens its own pairs on
-- top. That is a separate decision about what a window boundary means for an
-- open book, and it is not this migration's to make. Windows with a gap between
-- them are unaffected either way — the gap is a closed cycle and it flattens.
--
-- The browser's `findActiveScheduleWindow` is changed in step, in the same
-- commit. The two are the readout and the engine of one rule, and they were
-- already agreeing on the wrong answer here; they now agree on this one.
--
-- ---------------------------------------------------------------------------
-- Second fix, in the same function: a window with no id gets a unique one.
-- ---------------------------------------------------------------------------
-- apply_delta_strategy resolves the governing window's id as
--
--     v_win_id := coalesce(v_win ->> 'id', 'win_1')
--
-- and that fallback is the *same string for every window*. Entry is gated on
-- `v_win_id = any(entered_window_ids)`, so a book whose windows carry no ids
-- would stamp 'win_1' on the first entry of the day and then read every later
-- window as already entered — one window would trade and the rest would sit
-- flat, reporting nothing wrong. Not a readout bug; the engine would genuinely
-- not open those books.
--
-- The *Add window* button has always written `win_<timestamp>`, so this cannot
-- arise from the UI, and it is being fixed as the latent fault it is rather than
-- an observed one. Hand-written `schedule_windows` and rows predating the id are
-- what it protects.
--
-- Fixed here rather than in the engine because this function is where the window
-- is chosen: it stamps `win_<n>` into the returned `active_win` when the window
-- carries no id, so `v_win ->> 'id'` is never null and the engine's coalesce
-- becomes unreachable. One function changes, the engine is untouched, and
-- anything else reading `active_win` gets the same id.
--
-- `n` is the 1-based position in the array, which is exactly what the browser
-- synthesises in `rowToConfig` (`win_${idx + 1}`). The two sides have to agree
-- on the fallback or the readout's entry gate disagrees with the engine's for
-- precisely the books this protects.
-- ---------------------------------------------------------------------------

create or replace function public.delta_session_window(
  p_windows     jsonb,
  p_trade_days  smallint[],
  out phase     text,
  out sday      text,
  out active_win jsonb
)
language plpgsql
-- 0054: was `immutable`, which let the planner freeze the answer. Still stable.
stable
as $$
declare
  v_now_ist  timestamp;
  v_dow      int;
  v_mins     int;
  v_win      jsonb;
  v_start    text;
  v_end      text;
  v_s_min    int;
  v_e_min    int;
  v_open     boolean;
  v_today    text;
  v_sday     text;
  v_elapsed  int;
  v_best     int;
  v_item     record;
  v_idx      int;
begin
  v_now_ist := now() at time zone 'Asia/Kolkata';
  v_dow     := extract(isodow from v_now_ist)::int;
  v_mins    := extract(hour from v_now_ist)::int * 60 + extract(minute from v_now_ist)::int;
  v_today   := to_char(v_now_ist, 'YYYY-MM-DD');

  phase      := 'closed';
  sday       := v_today;
  active_win := null;
  v_best     := null;

  if p_trade_days is not null and not (v_dow = any(p_trade_days)) then
    return;
  end if;

  if p_windows is null or jsonb_array_length(p_windows) = 0 then
    return;
  end if;

  -- `with ordinality` so a window with no id can be named by its position, which
  -- is the one thing about it that is stable and unique.
  for v_item in
    select elem, ord from jsonb_array_elements(p_windows) with ordinality as w(elem, ord)
  loop
    v_win   := v_item.elem;
    v_idx   := v_item.ord::int;
    v_start := coalesce(v_win ->> 'startTime', v_win ->> 'start_time', '01:30');
    v_end   := coalesce(v_win ->> 'endTime', v_win ->> 'end_time', '17:00');

    v_s_min := split_part(v_start, ':', 1)::int * 60 + split_part(v_start, ':', 2)::int;
    v_e_min := split_part(v_end, ':', 1)::int * 60 + split_part(v_end, ':', 2)::int;

    v_open    := false;
    v_elapsed := null;
    v_sday    := v_today;

    if v_s_min <= v_e_min then
      if v_mins >= v_s_min and v_mins <= v_e_min then
        v_open    := true;
        v_elapsed := v_mins - v_s_min;
      end if;
    else
      -- Midnight-wrapping window. After the open we are in today's session;
      -- before the close we are still in the one that opened yesterday, so its
      -- elapsed time carries the day it crossed.
      if v_mins >= v_s_min then
        v_open    := true;
        v_elapsed := v_mins - v_s_min;
      elsif v_mins <= v_e_min then
        v_open    := true;
        v_elapsed := v_mins + 1440 - v_s_min;
        v_sday    := to_char(v_now_ist - interval '1 day', 'YYYY-MM-DD');
      end if;
    end if;

    -- Strictly less, so windows sharing a start time keep array order.
    if v_open and (v_best is null or v_elapsed < v_best) then
      v_best     := v_elapsed;
      phase      := 'open';
      -- Stamped here so the caller never has to invent one, and so two id-less
      -- windows cannot collide on a single entry stamp. Empty string counts as
      -- absent: `"id": ""` is what an editor writing a blank field leaves.
      active_win := case
                      when coalesce(v_win ->> 'id', '') = ''
                        then jsonb_set(v_win, '{id}', to_jsonb('win_' || v_idx))
                      else v_win
                    end;
      sday       := v_sday;
    end if;
  end loop;
end;
$$;

revoke all on function public.delta_session_window(jsonb, smallint[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Resolve every name at apply time, and check the rule actually changed.
-- ---------------------------------------------------------------------------
-- The convention since 0056: plpgsql resolves names on first *execution*, so a
-- migration that applies cleanly can still die hours later on a branch that had
-- not run yet.
do $$
declare
  v_src  text;
  v_win  jsonb;
  v_res  record;
begin
  select pr.prosrc into v_src from pg_proc pr join pg_namespace ns on ns.oid = pr.pronamespace
  where ns.nspname = 'public' and pr.proname = 'delta_session_window';

  -- The early `return` inside the loop is what made array order decide the tie.
  -- If it is back, the newest-window rule is not in force whatever else is.
  if v_src ~ 'if v_open then[[:space:]]+phase' then
    raise exception 'delta_session_window still returns on the first matching window';
  end if;
  if v_src not like '%v_elapsed%' then
    raise exception 'delta_session_window does not rank windows by elapsed time';
  end if;

  -- The engine calls it with these exact argument types; resolve that now.
  perform public.delta_session_window('[]'::jsonb, array[1,2,3,4,5,6,7]::smallint[]);

  -- And prove the tie-break, rather than trusting the source read above. Two
  -- windows covering the whole day, the second starting later: whatever the
  -- clock says when this runs, the later-starting one is the newer of the two
  -- and must be the one returned.
  v_win := jsonb_build_array(
    jsonb_build_object('id', 'older', 'startTime', '00:00', 'endTime', '23:59'),
    jsonb_build_object('id', 'newer', 'startTime', '00:01', 'endTime', '23:59')
  );
  select * into v_res
  from public.delta_session_window(v_win, array[1,2,3,4,5,6,7]::smallint[]);

  -- Between 00:00 and 00:00 the second window has not started, so only the first
  -- matches and 'older' is the correct answer. Every other minute of the day the
  -- newer one is running and must win.
  if v_res.phase <> 'open' then
    raise exception 'delta_session_window reports closed on an all-day window';
  end if;
  if (extract(hour from now() at time zone 'Asia/Kolkata')::int * 60
      + extract(minute from now() at time zone 'Asia/Kolkata')::int) >= 1
     and (v_res.active_win ->> 'id') <> 'newer' then
    raise exception 'delta_session_window picked % — the later-starting window must govern',
      v_res.active_win ->> 'id';
  end if;

  -- And that an id-less window comes back named by its position rather than by
  -- the shared 'win_1' the engine would otherwise coalesce to. Two of them, so a
  -- collision would show as both answering 'win_1'.
  v_win := jsonb_build_array(
    jsonb_build_object('startTime', '00:00', 'endTime', '23:59'),
    jsonb_build_object('startTime', '00:01', 'endTime', '23:59')
  );
  select * into v_res
  from public.delta_session_window(v_win, array[1,2,3,4,5,6,7]::smallint[]);

  if coalesce(v_res.active_win ->> 'id', '') = '' then
    raise exception 'delta_session_window returned a window with no id';
  end if;
  if (extract(hour from now() at time zone 'Asia/Kolkata')::int * 60
      + extract(minute from now() at time zone 'Asia/Kolkata')::int) >= 1
     and (v_res.active_win ->> 'id') <> 'win_2' then
    raise exception 'id-less windows collide: the second answered %, expected win_2',
      v_res.active_win ->> 'id';
  end if;

  raise log '0066: the most recently started schedule window governs, and id-less windows are named by position';
end;
$$;
