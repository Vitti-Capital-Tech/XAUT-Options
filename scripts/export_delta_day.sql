-- export_delta_day.sql
--
-- One delta account, one day, one expiry. Paste into the Supabase SQL Editor
-- (Dashboard > SQL Editor > New query), run it, download the result as CSV —
-- Excel opens that directly.
--
-- Read-only: one select, no writes.
--
-- ---------------------------------------------------------------------------
-- The three literals at the top of the query
-- ---------------------------------------------------------------------------
--   account   the account name, matched case-insensitively.
--   expiry    the `ddmmyy` tail of the symbol. 20 Aug 2026 is '200826'.
--   day_ist   which IST calendar day of fills to return. Defaults to yesterday,
--             computed at run time. Pin it to a date — '2026-08-19' — to get the
--             same rows however long from now this is run, or set it to null for
--             every day on that expiry.
--
-- Only accounts of kind 'delta' are considered, so a name shared with a manual or
-- futures book cannot pull the wrong rows in.
--
-- ---------------------------------------------------------------------------
-- Two blanks that are expected rather than missing
-- ---------------------------------------------------------------------------
--   * Exit Reason is empty on opening fills. Why a leg was opened is written to
--     `positions.entry_reason`, and a position row is deleted the moment it goes
--     flat (docs/LLD.md, invariant 2) — so for a leg already closed only the
--     closing fill's reason survives, which is this column.
--   * Index Price is empty on take-profit, stop and margin-cut rows written
--     before 0040 was applied. That migration records it going forward and cannot
--     backfill: the spot at a fill that has already happened is not recoverable.
--
-- Premium Flow is signed — positive is premium collected on a sale, negative is
-- premium paid to buy a leg back — so the TOTAL row reads as the day's actual
-- cash flow rather than adding the two together. Times are IST.
--
-- ---------------------------------------------------------------------------
-- If it comes back with only the TOTAL row, reading 0 fills
-- ---------------------------------------------------------------------------
-- One of the three filters excluded everything. Run this to see what actually
-- exists, then set the literals to a combination that is really there. The usual
-- culprit is the expiry: the strategy trades whichever expiry is pinned on its
-- own bar, so a given day's fills are not necessarily on the expiry that day's
-- date suggests.
--
--     select a.name, a.kind, split_part(f.symbol,'-',4) as expiry,
--            (f.created_at at time zone 'Asia/Kolkata')::date as day_ist,
--            count(*) as fills
--     from public.fills f join public.accounts a on a.id = f.account_id
--     group by 1,2,3,4 order by day_ist desc, a.name, expiry;
-- ============================================================================

with params as (
  select 'jd_us'::text  as account,
         '200826'::text as expiry,
         ((now() at time zone 'Asia/Kolkata')::date - 1)::date as day_ist
),
rows_ as (
  select f.created_at,
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
    and lower(a.name) = lower(p.account)
    -- Both filters accept null as "every one of these", so the same query answers
    -- "yesterday, whatever expiry" and "that expiry, whatever day". Setting both
    -- to null returns the account's whole history.
    and (p.expiry is null or split_part(f.symbol, '-', 4) = p.expiry)
    and (p.day_ist is null
         or (f.created_at at time zone 'Asia/Kolkata')::date = p.day_ist)
),
detail as (
  select row_number() over (order by created_at)                       as seq,
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
         'TOTAL'::text                                                 as date_ist,
         count(*)::text || ' fills'                                    as time_ist,
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
