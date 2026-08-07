-- ============================================================================
-- XAUT Options Paper Trading — Delta Management Strategy
-- Run this whole file in the Supabase SQL Editor after 0009_realtime.sql.
--
-- A third book, alongside the chain's 'manual' accounts and the auto strategy's
-- 'auto' ones: 'delta' accounts run the delta-band strategy from
-- Gold_Options_Delta_Strategy.docx. Same tables as the other two — an account
-- carries a kind and every position/order/fill is already scoped to an account —
-- so the three books never mix.
--
-- Unlike the auto strategy, this engine runs in the browser rather than on
-- pg_cron: every cycle needs per-strike greeks off the live ticker feed, which
-- only the client has. This table therefore holds the settings *and* the
-- session-scoped state (roll counters, which Sydney day has been entered and
-- flattened), so an armed strategy survives a reload and every open tab agrees
-- on where the session is up to.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Widen the account kinds.
-- ---------------------------------------------------------------------------
alter table public.accounts drop constraint if exists accounts_kind_chk;
alter table public.accounts
  add constraint accounts_kind_chk check (kind in ('manual', 'auto', 'delta'));

-- ---------------------------------------------------------------------------
-- Per-account settings and session state. One row per delta account.
--
-- The nine items the spec leaves OPEN are settings here rather than blockers:
-- each is a column with a default, so the strategy is runnable and the choice is
-- explicit and visible on screen instead of buried in an engine.
-- ---------------------------------------------------------------------------
create table if not exists public.delta_strategy_settings (
  account_id      uuid primary key references public.accounts (id) on delete cascade,
  armed           boolean not null default false,

  -- Session, as HH:MM on the Sydney clock (AEST/AEDT — the zone, not a fixed offset).
  session_open    text not null default '06:00',
  session_close   text not null default '22:00',

  -- Delta band [L, U] and where a correction lands inside it.
  band_low        numeric(20, 8) not null default -1,
  band_high       numeric(20, 8) not null default 1,
  -- 'edge' — the breached boundary exactly (the spec's worked example)
  -- 'buffer' — the breached boundary pulled inward by band_buffer
  -- 'mid' — the midpoint of the band
  target_landing  text not null default 'edge',
  band_buffer     numeric(20, 8) not null default 0.4,

  -- Rolls.
  itm_trigger     numeric(20, 8) not null default 5,    -- points of |spot - strike|
  max_rolls       integer not null default 3,           -- per side, per session
  roll_counts     text not null default 'pass',         -- 'pass' | 'strike'

  -- Premiums, USD per contract.
  entry_premium   numeric(20, 8) not null default 4,
  min_premium     numeric(20, 8) not null default 2,

  -- Fresh-OTM band correction picks strikes in this delta range.
  band_delta_low  numeric(20, 8) not null default 0.15,
  band_delta_high numeric(20, 8) not null default 0.25,

  -- Daily entry.
  pairs           integer not null default 1,           -- N call/put pairs at open
  tie_break       text not null default 'closest',      -- 'closest' | 'above' | 'below'
  expiry_pick     text not null default 'nearest',      -- 'nearest' | 'next'
  cycle_seconds   integer not null default 30,

  -- Session-scoped state. All three reset at each session open.
  session_day     text,                                 -- Sydney YYYY-MM-DD
  rolls_used_call integer not null default 0,
  rolls_used_put  integer not null default 0,
  entered_day     text,                                 -- day the pairs were sold
  flattened_day   text,                                 -- day the book was flattened

  updated_at      timestamptz not null default now(),

  constraint delta_target_landing_chk check (target_landing in ('edge', 'buffer', 'mid')),
  constraint delta_roll_counts_chk    check (roll_counts in ('pass', 'strike')),
  constraint delta_tie_break_chk      check (tie_break in ('closest', 'above', 'below')),
  constraint delta_expiry_pick_chk    check (expiry_pick in ('nearest', 'next')),
  constraint delta_band_chk           check (band_low < band_high),
  constraint delta_cycle_chk          check (cycle_seconds between 5 and 3600)
);

alter table public.delta_strategy_settings enable row level security;

drop policy if exists delta_strategy_settings_owner on public.delta_strategy_settings;
create policy delta_strategy_settings_owner on public.delta_strategy_settings
  using (exists (select 1 from public.accounts a where a.id = account_id and a.user_id = auth.uid()))
  with check (exists (select 1 from public.accounts a where a.id = account_id and a.user_id = auth.uid()));

grant select, insert, update, delete on public.delta_strategy_settings to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime, so a second tab sees an arm, a roll counter or a session reset at
-- once rather than on the next poll.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'delta_strategy_settings'
  ) then
    alter publication supabase_realtime add table public.delta_strategy_settings;
  end if;
end $$;
