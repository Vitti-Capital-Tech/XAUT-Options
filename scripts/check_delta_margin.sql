-- check_delta_margin.sql
--
-- Paste into the Supabase SQL Editor and run. Read-only: three selects, no writes.
--
-- The SQL Editor connects as the project owner, so RLS does not apply there and
-- this sees every delta account. The app's anon key cannot — every policy on
-- accounts, positions and delta_strategy_settings is scoped to the owning user
-- (0001_init), which is why this has to be run by hand rather than from a script.

-- ---------------------------------------------------------------------------
-- 1. Is the margin guard actually live, and where does the book stand?
-- ---------------------------------------------------------------------------
-- If 0031 has NOT been applied this errors with "column s.margin_cap_pct does not
-- exist" or "function public.delta_account_margin does not exist" — which is
-- itself the answer, and the only reliable way to tell from outside.
--
-- pct_of_equity is the number the guard tests. Over margin_cap_pct it cuts; over
-- margin_target_pct it holds and stops selling.
select a.name,
       s.armed,
       (select count(*) from public.positions p
         where p.account_id = a.id and p.net_qty <> 0)              as open_legs,
       s.qty,
       s.entry_premium,
       s.margin_cap_pct                                             as cut_at_pct,
       s.margin_target_pct                                          as cut_to_pct,
       round(a.cash_balance, 2)                                     as balance,
       round(m.unrealized, 2)                                       as unrealized,
       round(m.equity, 2)                                           as equity,
       round(m.margin, 2)                                           as margin,
       round(100 * m.margin / nullif(m.equity, 0), 1)               as pct_of_equity
from public.accounts a
join public.delta_strategy_settings s on s.account_id = a.id
cross join lateral public.delta_account_margin(
             a.id, (select max(spot_price) from public.delta_chain)) m
where a.kind = 'delta' and not a.is_archived;

-- ---------------------------------------------------------------------------
-- 2. What is actually open, worst-first
-- ---------------------------------------------------------------------------
-- itm_distance is the order the guard cuts in: most in-the-money first. A short
-- leg deep in the money is where both the margin and the loss are concentrated.
select a.name,
       p.symbol,
       p.net_qty,
       round(p.avg_entry_price, 2)                                  as avg_entry,
       round(c.mark_price, 2)                                       as mark,
       round(case when p.contract_type = 'call_options'
                  then c.spot_price - p.strike_price
                  else p.strike_price - c.spot_price end, 1)        as itm_distance,
       round((p.avg_entry_price - coalesce(c.mark_price, p.avg_entry_price))
             * abs(p.net_qty) * p.contract_value, 2)                as unrealized
from public.positions p
join public.accounts a on a.id = p.account_id
left join public.delta_chain c on c.symbol = p.symbol
where a.kind = 'delta' and p.net_qty <> 0
order by a.name, itm_distance desc;

-- ---------------------------------------------------------------------------
-- 3. What the engine has been doing — has a cut ever fired?
-- ---------------------------------------------------------------------------
-- A guard cut shows up as a `buy` with no close_reason: delta_close_leg places a
-- plain order, so it is not tagged the way a take-profit or stop is. A run of
-- those with no matching sell right after is the cut walking the book down.
select f.created_at at time zone 'Asia/Kolkata'                     as ist,
       a.name,
       f.symbol,
       f.side,
       f.qty,
       round(f.price, 2)                                            as price,
       round(f.realized_pnl, 2)                                     as realized,
       f.close_reason
from public.fills f
join public.accounts a on a.id = f.account_id
where a.kind = 'delta'
order by f.created_at desc
limit 40;
