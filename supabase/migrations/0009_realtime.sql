-- ============================================================================
-- XAUT Options Paper Trading — realtime
-- Run this whole file in the Supabase SQL Editor after 0008_strategy_engine.sql.
--
-- So a change one session makes shows up in every other open session at once,
-- rather than on the next 15s poll or a manual refresh. Supabase pushes row
-- changes over its realtime channel for any table on the supabase_realtime
-- publication; the client subscribes and re-reads. RLS still applies to the
-- stream, so a session only ever receives rows it could already select.
-- ============================================================================

do $$
declare
  t text;
begin
  foreach t in array array['accounts', 'positions', 'orders', 'fills', 'strategy_settings']
  loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
