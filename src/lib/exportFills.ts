/**
 * Turning a day of fills into a spreadsheet the desk can send on.
 *
 * The columns are deliberately the same ones, in the same order, as
 * [`scripts/export_delta_day.sql`](../../scripts/export_delta_day.sql). Two
 * exports of the same day from the two routes have to agree, or the next
 * question is which of them is lying.
 *
 * CSV rather than a real `.xlsx`: Excel opens one directly, and writing a
 * genuine workbook means a zip writer and a schema for the sake of bold headers.
 * The BOM below is what makes that safe — without it Excel reads the file as the
 * system codepage and the `Δ` and `·` in every engine reason line come out as
 * mojibake.
 */

import type { FillRow } from '../hooks/useTrading'
import { DISPLAY_ZONE, dayKey } from './format'

/** The half-open UTC range covering one IST calendar day, as ISO strings. */
export function istDayRange(day: string): { start: string; end: string } {
  // `+05:30` is stated rather than derived: IST has no daylight saving, so the
  // offset is a constant, and building the boundary from the literal avoids
  // depending on the machine's own zone.
  const start = new Date(`${day}T00:00:00.000+05:30`)
  const end = new Date(start)
  end.setUTCDate(end.getUTCDate() + 1)
  return { start: start.toISOString(), end: end.toISOString() }
}

const time = (iso: string) =>
  new Date(iso).toLocaleTimeString('en-GB', { hour12: false, timeZone: DISPLAY_ZONE })

const num = (v: string | number | null | undefined, dp: number): string => {
  if (v === null || v === undefined || v === '') return ''
  const n = typeof v === 'string' ? Number(v) : v
  return Number.isFinite(n) ? n.toFixed(dp) : ''
}

/** A fill's kind, in the same words the panel and the SQL export use. */
function kindOf(f: FillRow): string {
  if (f.is_settlement) return 'Settlement'
  if (f.close_reason) {
    return f.close_reason
      .replace(/_/g, ' ')
      .replace(/\b\w/g, (c) => c.toUpperCase())
  }
  return 'Trade'
}

function typeOf(f: FillRow): string {
  if (f.contract_type === 'call_options') return 'Call'
  if (f.contract_type === 'put_options') return 'Put'
  if (f.contract_type === 'perpetual_futures') return 'Perpetual'
  return f.contract_type
}

/** Positive is premium collected on a sale, negative is premium paid to close. */
const premiumFlow = (f: FillRow) =>
  (f.side === 'sell' ? 1 : -1) * Number(f.premium)

const HEADER = [
  'date_ist',
  'time_ist',
  'symbol',
  'expiry',
  'type',
  'strike',
  'side',
  'kind',
  'lots',
  'qty_xaut',
  'exec_price',
  'index_price',
  'premium_flow_usd',
  'notional_usd',
  'fee_usd',
  'realized_usd',
  'exit_reason',
]

/** RFC 4180: quote anything holding a comma, a quote or a newline. */
function cell(v: string): string {
  return /[",\n\r]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v
}

/**
 * One day of fills as CSV, oldest first, with a TOTAL row appended.
 *
 * Oldest first is the opposite of the panel, which shows newest at the top. A
 * ledger someone is going to read down and reconcile wants the session in the
 * order it happened.
 */
export function fillsToCsv(fills: FillRow[]): string {
  const rows = [...fills].sort((a, b) => a.created_at.localeCompare(b.created_at))

  const body = rows.map((f) =>
    [
      dayKey(f.created_at),
      time(f.created_at),
      f.symbol,
      // A perpetual has no expiry, and its symbol has no hyphens to split.
      f.symbol.split('-')[3] ?? '',
      typeOf(f),
      num(f.strike_price, 2),
      f.side === 'sell' ? 'Sell' : 'Buy',
      kindOf(f),
      String(f.qty),
      num(f.qty * Number(f.contract_value), 3),
      num(f.price, 2),
      num(f.spot_at_fill, 2),
      num(premiumFlow(f), 4),
      num(f.notional, 2),
      num(f.fee, 4),
      num(f.realized_pnl, 4),
      f.reason ?? '',
    ].map(cell),
  )

  const sum = (pick: (f: FillRow) => number) => rows.reduce((t, f) => t + pick(f), 0)
  const fees = sum((f) => Number(f.fee))
  const realized = sum((f) => Number(f.realized_pnl))

  const total = [
    'TOTAL',
    `${rows.length} fills`,
    '',
    '',
    '',
    '',
    '',
    '',
    String(sum((f) => f.qty)),
    num(sum((f) => f.qty * Number(f.contract_value)), 3),
    '',
    '',
    num(sum(premiumFlow), 4),
    num(sum((f) => Number(f.notional)), 2),
    num(fees, 4),
    num(realized, 4),
    `net of fees: ${(realized - fees).toFixed(2)}`,
  ].map(cell)

  // A BOM, so Excel reads this as UTF-8 and the reason lines keep their Δ.
  return '﻿' + [HEADER.join(','), ...body.map((r) => r.join(',')), total.join(',')].join('\r\n')
}

/** Hand the file to the browser. Revoked on the next tick, not left to leak. */
export function downloadCsv(filename: string, csv: string): void {
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8;' }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}

/** `JD US` + `2026-08-19` -> `JD-US_2026-08-19_fills.csv`. */
export function fillsFilename(accountName: string, day: string): string {
  const safe = accountName.trim().replace(/[^A-Za-z0-9._-]+/g, '-') || 'account'
  return `${safe}_${day}_fills.csv`
}
