-- ============================================================================
-- XAUT Options Paper Trading — the delta session moves to IST
-- Run this whole file in the Supabase SQL Editor after 0021_qty_and_take_profit.sql.
--
-- delta_session read the Sydney clock because the specification writes its session
-- in Sydney terms. But a rule set is not a timezone: the hours are the desk's to
-- choose, and running the two engines on two different clocks is how a window gets
-- misread. Both are now on IST.
--
--     session_open / session_close   HH:MM, IST (was Sydney)
--     trade_days                     ISO weekdays, IST (was Sydney)
--     session_day                    IST YYYY-MM-DD (was Sydney)
--
-- READ THIS BEFORE RUNNING IT. The stored numbers do not change, so their meaning
-- does. A session of 06:00-22:00 was 01:30-17:30 IST under AEST and is now
-- 06:00-22:00 IST — four and a half hours later in real terms. Check the session
-- times against what you actually want after running this.
--
-- The migration also re-keys the session-scoped counters onto the new IST day. It
-- has to: session_day is compared against the day delta_session returns, and a
-- mismatch is what apply_delta_strategy reads as "a new session has started" —
-- which clears entered_day and sells a fresh pair. Sydney is ahead of IST, so
-- around the evening the stored Sydney date is already tomorrow's and the switch
-- would look exactly like a new session. Re-keying keeps entered_day and
-- flattened_day meaning what they meant, so no second pair is opened and no second
-- flatten is attempted.
-- ============================================================================

create or replace function public.delta_session(p_open text, p_close text,
                                                p_days smallint[] default null,
                                                out phase text, out sday text)
language plpgsql
stable
as $$
declare
  -- IST, matching the auto strategy's in_ist_window. No daylight saving to carry,
  -- but read through the zone rather than a fixed offset all the same.
  v_local timestamp := now() at time zone 'Asia/Kolkata';
  v_min   int;
  v_day   date;
  v_o     int;
  v_c     int;
begin
  v_min := extract(hour from v_local)::int * 60 + extract(minute from v_local)::int;
  v_day := v_local::date;
  v_o   := split_part(p_open,  ':', 1)::int * 60 + split_part(p_open,  ':', 2)::int;
  v_c   := split_part(p_close, ':', 1)::int * 60 + split_part(p_close, ':', 2)::int;

  if v_o <= v_c then
    sday  := v_day::text;
    phase := case when v_min < v_o then 'before'
                  when v_min <= v_c then 'open'
                  else 'closed' end;
  elsif v_min >= v_o then
    phase := 'open';  sday := v_day::text;
  elsif v_min <= v_c then
    phase := 'open';  sday := (v_day - 1)::text;
  else
    phase := 'closed'; sday := (v_day - 1)::text;
  end if;

  -- Not a trading day: closed, whatever the clock says.
  if p_days is not null
     and not (extract(isodow from sday::date)::smallint = any (p_days)) then
    phase := 'closed';
  end if;
end;
$$;

comment on function public.delta_session(text, text, smallint[]) is
  'Session phase and session day on the IST clock. A session day outside the given ISO weekdays reports closed. Null days means every day.';

revoke all on function public.delta_session(text, text, smallint[]) from public, anon, authenticated;

comment on column public.delta_strategy_settings.trade_days is
  'ISO weekdays (Mon 1 - Sun 7, IST) the delta session runs. Outside them the session reads closed. Empty trades never.';

-- ---------------------------------------------------------------------------
-- Re-key the session-scoped state onto the IST day, preserving whether each was
-- set. Runs after the function above, so delta_session already answers in IST.
-- Null stays null: an account that has not entered today must still be free to.
-- ---------------------------------------------------------------------------
do $$
declare
  r      record;
  v_ph   text;
  v_sday text;
begin
  for r in
    select account_id, session_open, session_close, trade_days,
           session_day, entered_day, flattened_day
    from public.delta_strategy_settings
  loop
    select phase, sday into v_ph, v_sday
    from public.delta_session(r.session_open, r.session_close, r.trade_days);

    update public.delta_strategy_settings
    set session_day   = v_sday,
        entered_day   = case when r.entered_day   is not null then v_sday end,
        flattened_day = case when r.flattened_day is not null then v_sday end
    where account_id = r.account_id;

    raise log 'delta session re-keyed to IST: account % now on % (phase %)',
      r.account_id, v_sday, v_ph;
  end loop;
end $$;
