-- 0063_counts_are_counted_not_fetched.sql
--
-- Run this whole file in the Supabase SQL Editor after 0062.
--
-- The admin panel prints three numbers beside each account — how many positions
-- it holds, how many trades it has made, how many orders are resting. It was
-- getting them by fetching every row and counting them in the browser:
--
--     supabase.from('positions').select('account_id')
--     supabase.from('fills').select('account_id')
--     supabase.from('orders').select('account_id').eq('status', 'open')
--
-- No filter, no limit, on tables that only ever grow. A book making a few
-- hundred fills a day was shipping the whole ledger across the wire every time
-- the panel opened, to render a number two digits wide. It was also quietly
-- fragile: PostgREST caps a response at `db-max-rows` where that is configured,
-- and a capped response would have been counted as if it were the whole table —
-- wrong numbers, silently, with nothing to show they were wrong.
--
-- Counting belongs in the database. One correlated count per account, each
-- answered by the account_id index those tables already carry
-- (`positions_account_idx`, `fills_account_idx`, `orders_open_idx`).
--
-- SECURITY INVOKER, deliberately: the function runs as the caller, so the same
-- RLS policies that gate a direct select gate this too. It can no more count
-- another user's fills than the query it replaces could read them. That is why
-- it needs no privileged role and is safe to grant to `authenticated`.
--
-- The output columns are prefixed rather than named `positions` / `fills` /
-- `orders`, because in a `language sql` body a RETURNS TABLE column shadows a
-- relation of the same name and the counts would fail to resolve.
-- ---------------------------------------------------------------------------

create or replace function public.account_counts()
returns table (
  acct_id           uuid,
  position_count    bigint,
  fill_count        bigint,
  open_order_count  bigint
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    a.id,
    (select count(*) from public.positions p where p.account_id = a.id),
    (select count(*) from public.fills     f where f.account_id = a.id),
    (select count(*) from public.orders    o where o.account_id = a.id
                                             and o.status = 'open')
  from public.accounts a
  where a.user_id = auth.uid();
$$;

grant execute on function public.account_counts() to authenticated;
