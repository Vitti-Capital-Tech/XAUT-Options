-- 0029_delta_five_second_cadence.sql
--
-- Run this whole file in the Supabase SQL Editor after
-- 0028_delta_drop_min_premium_and_band_delta.sql.
--
-- The delta engine polled and acted once a minute, so a band breach took up to
-- ~60-120s to correct (one poll to fetch the chain, one apply to act on it).
-- Both drop to 5 seconds, for ~5-10s — the cadence the TP/SL engine has run at
-- since 0006, on this same pg_cron.
--
-- Both jobs have to move together. apply_delta_strategy reads whatever ticker
-- reply landed in the last 180 seconds, so a faster apply against a once-a-minute
-- poll would only re-read the same stale chain and take the same decision twice.
-- Freshness is the poll's to give.
--
-- Safe to tighten:
--   * apply takes pg_try_advisory_xact_lock and returns at once if it is already
--     held, so overlapping passes cannot double-correct.
--   * the per-account last_cycle gate still spaces each account by its own
--     Refresh setting — this only stops that gate being the thing that is never
--     reached.
--   * queue_delta_checks returns early unless some account is armed, so an idle
--     install still costs one index lookup, now twelve times a minute.
--
-- cron.schedule updates a job in place when the name already exists, so this
-- re-times the two jobs 0012 created — no unschedule needed.

select cron.schedule('delta-poll',  '5 seconds', $$select public.queue_delta_checks()$$);
select cron.schedule('delta-apply', '5 seconds', $$select public.apply_delta_strategy()$$);

-- Refresh is a floor on how often one account may act, so leaving it at 30 would
-- hold every existing account to 30s no matter how fast the jobs run. Move the
-- default, and move the accounts still sitting on that old default — an account
-- whose Refresh was deliberately set to something else keeps it.
alter table public.delta_strategy_settings alter column cycle_seconds set default 5;

update public.delta_strategy_settings set cycle_seconds = 5 where cycle_seconds = 30;
