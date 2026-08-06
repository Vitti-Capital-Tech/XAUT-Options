-- ============================================================================
-- XAUT Options Paper Trading — tighten the TP/SL cadence
-- Run this whole file in the Supabase SQL Editor after 0003_tpsl.sql.
--
-- The stop engine polled and fired every 15 seconds, so a hit took ~15-30s to
-- close (one poll to fetch Delta's price, one apply to act on it). This drops
-- both to 5 seconds, for ~5-10s.
--
-- Safe to tighten: apply already acts on the freshest reply per symbol, so a
-- faster poll only makes that price newer; and close_position_triggered locks
-- and deletes the row, so overlapping passes cannot double-close. cron.schedule
-- updates a job in place when the name already exists, so this just re-times the
-- two jobs 0003 created — no unschedule needed.
-- ============================================================================

select cron.schedule('tpsl-poll',  '5 seconds', $$select public.queue_tpsl_checks()$$);
select cron.schedule('tpsl-apply', '5 seconds', $$select public.apply_tpsl_triggers()$$);
