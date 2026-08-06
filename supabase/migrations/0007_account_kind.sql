-- ============================================================================
-- XAUT Options Paper Trading — manual vs auto accounts
-- Run this whole file in the Supabase SQL Editor after 0006_tpsl_cadence.sql.
--
-- The Auto Strategy page runs its own book, independent of the option chain:
-- its own accounts, balances, positions and trade history. Rather than a second
-- set of tables, an account carries a `kind` — 'manual' for the chain, 'auto'
-- for the strategy — and every positions/orders/fills row is already scoped to
-- an account, so the two books never mix. Existing accounts default to 'manual',
-- so nothing that exists today moves.
-- ============================================================================

alter table public.accounts
  add column if not exists kind text not null default 'manual';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'accounts_kind_chk') then
    alter table public.accounts
      add constraint accounts_kind_chk check (kind in ('manual', 'auto'));
  end if;
end $$;
