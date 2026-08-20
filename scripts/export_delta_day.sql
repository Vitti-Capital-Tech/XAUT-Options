-- export_delta_day.sql
--
-- Everything a delta account did on one expiry, as five result sets to hand over
-- in a spreadsheet.
--
-- Paste into the Supabase SQL Editor (Dashboard > SQL Editor > New query) and run
-- ONE query at a time, then use the result grid's download button to save each as
-- CSV. Excel opens those directly; one file per sheet.
--
-- Read-only throughout: five selects, no writes.
--
-- The SQL Editor connects as the project owner, so RLS does not apply there and
-- this sees every account. The app's anon key cannot — every policy on accounts,
-- fills and positions is scoped to the owning user (0001_init) — which is why
-- this has to be run by hand rather than from a script with the anon key.
--
-- ---------------------------------------------------------------------------
-- Set these two, in every query you run
-- ---------------------------------------------------------------------------
--   expiry        the `ddmmyy` tail of the symbol. 20 Aug 2026 is '200826'.
--   account_name  as it reads in the account switcher. Query 0 lists them.
--
-- ---------------------------------------------------------------------------
-- One thing the ledger cannot tell you, so nobody hunts for it
-- ---------------------------------------------------------------------------
-- Why a leg was *opened* is written to `positions.entry_reason`, and a position
-- row is deleted the moment it goes flat (invariant 2, see docs/LLD.md). So for
-- any leg that has already been closed, the entry reason is gone — only the
-- closing fill's `reason` survives, in the Exit Reason column below. Open legs
-- still carry theirs, and query 4 shows them.
--
-- Times are rendered in IST, the zone the whole app pins its clocks to.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 0. Which accounts exist, so the name below is the right one
-- ---------------------------------------------------------------------------
select a.name           as account_name,
       a.kind,
       a.is_archived,
       round(a.starting_balance, 2) as starting_balance,
       round(a.cash_balance, 2)     as cash_balance,
       round(a.cash_balance - a.starting_balance, 2) as realized_pnl_all_time
from public.accounts a
where a.kind = 'delta'
order by a.is_archived, a.name;


-- ---------------------------------------------------------------------------
-- 1. Every fill on that expiry — the detail sheet
--
-- One row per execution, oldest first so it reads as the session did. `qty_xaut`
-- is the size in the underlying, which is the unit the terminal shows; `lots` is
-- what was actually traded, kept beside it because the two differ by 1000x.
-- ---------------------------------------------------------------------------
with params as (select '200826'::text as expiry, 'Jigar'::text as account_name)
select to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') as date_ist,
       to_char(f.created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time_ist,
       f.symbol,
       case f.contract_type when 'call_options' then 'Call'
                            when 'put_options'  then 'Put'
                            else f.contract_type end                   as type,
       f.strike_price::numeric                                          as strike,
       initcap(f.side)                                                  as side,
       case when f.is_settlement then 'Settlement'
            when f.close_reason is not null then initcap(replace(f.close_reason, '_', ' '))
            else 'Trade' end                                           as kind,
       f.qty                                                            as lots,
       round(f.qty * f.contract_value, 3)                               as qty_xaut,
       round(f.price, 2)                                                as exec_price,
       round(f.spot_at_fill, 2)                                         as index_price,
       round(f.premium, 4)                                              as premium_usd,
       round(f.notional, 2)                                             as notional_usd,
       round(f.fee, 4)                                                  as fee_usd,
       round(f.realized_pnl, 4)                                         as realized_usd,
       f.reason                                                         as exit_reason
from public.fills f
join public.accounts a on a.id = f.account_id
join params p on true
where a.name = p.account_name
  and a.kind = 'delta'
  and split_part(f.symbol, '-', 4) = p.expiry
order by f.created_at;


-- ---------------------------------------------------------------------------
-- 2. Per-strike summary — what was sold where, and what it made
--
-- `net_lots` is signed: negative is still short at the end of the period. It
-- lands on zero for anything opened and closed within it.
-- ---------------------------------------------------------------------------
with params as (select '200826'::text as expiry, 'Jigar'::text as account_name)
select f.symbol,
       case f.contract_type when 'call_options' then 'Call' else 'Put' end as type,
       f.strike_price::numeric                                             as strike,
       count(*)                                                            as fills,
       sum(case when f.side = 'sell' then f.qty else 0 end)                as lots_sold,
       sum(case when f.side = 'buy'  then f.qty else 0 end)                as lots_bought,
       sum(case when f.side = 'sell' then -f.qty else f.qty end)           as net_lots,
       round(sum(case when f.side = 'sell' then -f.qty else f.qty end)
             * max(f.contract_value), 3)                                   as net_qty_xaut,
       round(sum(case when f.side = 'sell' then f.premium else 0 end), 2)   as premium_collected_usd,
       round(sum(case when f.side = 'buy'  then f.premium else 0 end), 2)   as premium_paid_usd,
       round(sum(f.fee), 4)                                                as fees_usd,
       round(sum(f.realized_pnl), 2)                                       as realized_usd,
       round(sum(f.realized_pnl) - sum(f.fee), 2)                          as net_of_fees_usd
from public.fills f
join public.accounts a on a.id = f.account_id
join params p on true
where a.name = p.account_name
  and a.kind = 'delta'
  and split_part(f.symbol, '-', 4) = p.expiry
group by f.symbol, f.contract_type, f.strike_price
order by f.contract_type, f.strike_price;


-- ---------------------------------------------------------------------------
-- 3. Totals — one row per day, plus a grand total
--
-- Split by day because a delta session can span midnight (the session opening
-- 01:30 IST closes the same afternoon, but the setting allows otherwise), and by
-- kind so the spread paid on engine round-trips is visible rather than netted
-- into one number.
-- ---------------------------------------------------------------------------
with params as (select '200826'::text as expiry, 'Jigar'::text as account_name),
rows_ as (
  select to_char(f.created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') as date_ist,
         case when f.is_settlement then 'Settlement'
              when f.close_reason is not null then initcap(replace(f.close_reason, '_', ' '))
              else 'Trade' end                                             as kind,
         f.side, f.qty, f.contract_value, f.premium, f.fee, f.realized_pnl
  from public.fills f
  join public.accounts a on a.id = f.account_id
  join params p on true
  where a.name = p.account_name
    and a.kind = 'delta'
    and split_part(f.symbol, '-', 4) = p.expiry
)
select coalesce(date_ist, 'TOTAL')                                     as date_ist,
       coalesce(kind, 'all')                                           as kind,
       count(*)                                                        as fills,
       round(sum(qty * contract_value), 3)                             as qty_xaut,
       round(sum(case when side = 'sell' then premium else 0 end), 2)   as premium_collected_usd,
       round(sum(case when side = 'buy'  then premium else 0 end), 2)   as premium_paid_usd,
       round(sum(fee), 4)                                              as fees_usd,
       round(sum(realized_pnl), 2)                                     as realized_usd,
       round(sum(realized_pnl) - sum(fee), 2)                          as net_of_fees_usd
from rows_
group by rollup (date_ist, kind)
order by date_ist nulls last, kind nulls last;


-- ---------------------------------------------------------------------------
-- 4. Anything still open on that expiry
--
-- Empty once the expiry has settled — the settlement cron closes every position
-- on a settled symbol (0002), and those closes appear in query 1 with kind
-- `Settlement`. Entry Reason is only readable here, on legs that are still open.
-- ---------------------------------------------------------------------------
with params as (select '200826'::text as expiry, 'Jigar'::text as account_name)
select pos.symbol,
       case pos.contract_type when 'call_options' then 'Call' else 'Put' end as type,
       pos.strike_price::numeric                                            as strike,
       pos.net_qty                                                          as net_lots,
       round(pos.net_qty * pos.contract_value, 3)                           as net_qty_xaut,
       round(pos.avg_entry_price, 2)                                        as avg_entry,
       round(pos.take_profit, 2)                                            as take_profit,
       round(pos.stop_loss, 2)                                              as stop_loss,
       to_char(pos.opened_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD HH24:MI:SS') as opened_ist,
       pos.entry_reason
from public.positions pos
join public.accounts a on a.id = pos.account_id
join params p on true
where a.name = p.account_name
  and a.kind = 'delta'
  and split_part(pos.symbol, '-', 4) = p.expiry
  and pos.net_qty <> 0
order by pos.contract_type, pos.strike_price;
