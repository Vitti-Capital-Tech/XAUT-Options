-- export_delta_day.sql
--
-- One query. Paste into the Supabase SQL Editor (Dashboard > SQL Editor > New
-- query), run it, and download the result as CSV — Excel opens that directly.
--
-- Read-only: one select, no writes.
--
-- Edit the ONE literal on the next line if you want a different expiry. It is the
-- `ddmmyy` tail of the symbol, so 20 Aug 2026 is '200826'.
--
-- Every delta account is included, with a column saying which — so there is no
-- name to get wrong, and Jigar's rows can be filtered in the spreadsheet if there
-- is more than one book. A TOTAL row is appended at the bottom.
--
-- The SQL Editor connects as the project owner, so RLS does not apply there and
-- this sees every account. The app's anon key cannot — every policy on accounts
-- and fills is scoped to the owning user (0001_init) — which is why this is run
-- by hand rather than from a script.
--
-- Two things the ledger cannot answer, so nobody goes looking for them:
--
--   * Entry Reason is missing on closed legs. It lives on the position row, and a
--     position is deleted the moment it goes flat (docs/LLD.md, invariant 2), so
--     only the closing fill's reason survives — the Exit Reason column here.
--   * Index Price is blank on take-profit, stop and margin-cut rows from before
--     0040 was applied. That migration records it going forward and cannot
--     backfill: the spot at a fill that already happened is not recoverable.
--
-- Money conventions: Premium Flow is signed — positive is premium collected on a
-- sale, negative is premium paid to buy a leg back — so the TOTAL row reads as
-- the session's actual cash flow. Times are IST, the zone the app pins to.
-- ============================================================================

with params as (
  select '200826'::text as expiry            -- <<< the only thing to edit
),
rows_ as (
  select a.name                                                        as account,
         f.created_at,
         f.symbol,
         f.contract_type,
         f.strike_price::numeric                                       as strike,
         f.side,
         case when f.is_settlement then 'Settlement'
              when f.close_reason is not null
                then initcap(replace(f.close_reason, '_', ' '))
              else 'Trade' end                                         as kind,
         f.qty::bigint                                                 as lots,
         f.qty * f.contract_value                                      as qty_xaut,
         f.price,
         f.spot_at_fill,
         case when f.side = 'sell' then f.premium else -f.premium end   as premium_flow,
         f.notional,
         f.fee,
         f.realized_pnl,
         f.reason
  from public.fills f
  join public.accounts a on a.id = f.account_id
  join params p on true
  where a.kind = 'delta'
    and split_part(f.symbol, '-', 4) = p.expiry
),
detail as (
  select row_number() over (order by account, created_at)              as seq,
         account,
         to_char(created_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD') as date_ist,
         to_char(created_at at time zone 'Asia/Kolkata', 'HH24:MI:SS') as time_ist,
         symbol,
         case contract_type when 'call_options' then 'Call'
                            when 'put_options'  then 'Put'
                            else contract_type end                     as type,
         strike,
         initcap(side)                                                 as side,
         kind,
         lots,
         round(qty_xaut, 3)                                            as qty_xaut,
         round(price, 2)                                               as exec_price,
         round(spot_at_fill, 2)                                        as index_price,
         round(premium_flow, 4)                                        as premium_flow_usd,
         round(notional, 2)                                            as notional_usd,
         round(fee, 4)                                                 as fee_usd,
         round(realized_pnl, 4)                                        as realized_usd,
         reason                                                        as exit_reason
  from rows_
),
total as (
  select 9223372036854775807::bigint                                   as seq,
         'TOTAL'::text                                                 as account,
         count(*)::text || ' fills'                                    as date_ist,
         null::text                                                    as time_ist,
         null::text                                                    as symbol,
         null::text                                                    as type,
         null::numeric                                                 as strike,
         null::text                                                    as side,
         null::text                                                    as kind,
         sum(lots)::bigint                                             as lots,
         round(sum(qty_xaut), 3)                                       as qty_xaut,
         null::numeric                                                 as exec_price,
         null::numeric                                                 as index_price,
         round(sum(premium_flow), 4)                                   as premium_flow_usd,
         round(sum(notional), 2)                                       as notional_usd,
         round(sum(fee), 4)                                            as fee_usd,
         round(sum(realized_pnl), 4)                                   as realized_usd,
         'net of fees: ' || round(sum(realized_pnl) - sum(fee), 2)::text as exit_reason
  from rows_
)
select * from detail
union all
select * from total
order by seq;
