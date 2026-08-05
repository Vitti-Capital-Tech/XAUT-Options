/** Display helpers. All money is USD. */

export function usd(v: number | null | undefined, dp = 2): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—'
  const sign = v < 0 ? '-' : ''
  return `${sign}$${Math.abs(v).toLocaleString('en-US', {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  })}`
}

/** Signed money, for P&L columns where the leading + matters. */
export function signedUsd(v: number | null | undefined, dp = 2): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—'
  return `${v > 0 ? '+' : v < 0 ? '-' : ''}$${Math.abs(v).toLocaleString('en-US', {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  })}`
}

export function price(v: number | string | null | undefined, dp = 2): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  return n.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp })
}

/**
 * Price with a leading `$`, as Delta renders every price in the chain.
 * Missing values become a bare dash, which inherits the column's colour there.
 */
export function usdPrice(v: number | string | null | undefined, dp = 2): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '-'
  return `$${n.toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp })}`
}

/** Fractional IV (0.3459) -> '34.6%' — one decimal, matching Delta's chain. */
export function ivShort(v: string | number | null | undefined): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '-'
  return `${(n * 100).toFixed(1)}%`
}

/** Delta's countdown format, e.g. '0d:20h:33m'. */
export function timeToExpiry(settlementTime: string): string {
  const ms = new Date(settlementTime).getTime() - Date.now()
  if (!Number.isFinite(ms)) return '—'
  if (ms <= 0) return 'Expired'
  const d = Math.floor(ms / 86_400_000)
  const h = Math.floor((ms % 86_400_000) / 3_600_000)
  const m = Math.floor((ms % 3_600_000) / 60_000)
  return `${d}d:${String(h).padStart(2, '0')}h:${String(m).padStart(2, '0')}m`
}

export function greek(v: string | number | null | undefined, dp = 3): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  return n.toFixed(dp)
}

/** 35398 -> '35.4K'. Used for book sizes and open interest. */
export function compact(v: number | string | null | undefined): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '—'
  const abs = Math.abs(n)
  if (abs >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (abs >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (abs >= 1e3) return `${(n / 1e3).toFixed(1)}K`
  return n.toLocaleString('en-US', { maximumFractionDigits: 2 })
}

export function pct(v: number | null | undefined, dp = 2): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—'
  return `${v > 0 ? '+' : ''}${v.toFixed(dp)}%`
}

export function timeOfDay(iso: string): string {
  return new Date(iso).toLocaleTimeString('en-GB', { hour12: false })
}

export function dateTime(iso: string): string {
  const d = new Date(iso)
  return `${d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })} ${d.toLocaleTimeString('en-GB', { hour12: false })}`
}

/**
 * The same stamp in the two lines Delta stacks in a Time column — `05 Aug` over
 * `5:30:01 PM`. Twelve-hour, as theirs is, because that is what an Indian desk
 * reads the clock in.
 */
export function dateTimeParts(iso: string): { date: string; time: string } {
  const d = new Date(iso)
  return {
    date: d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' }),
    time: d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', second: '2-digit' }),
  }
}

/** Tailwind text colour for a signed number. */
export function pnlClass(v: number | null | undefined): string {
  if (v === null || v === undefined || !Number.isFinite(v) || v === 0) return 'text-zinc-400'
  return v > 0 ? 'text-emerald-400' : 'text-rose-400'
}
