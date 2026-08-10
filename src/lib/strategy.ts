/**
 * The auto-strategy's pure logic, with no React and no I/O, so the strike maths
 * and the time window can be reasoned about on their own.
 *
 * The rule is fixed: read the last closed 1h candle of the spot index and sell
 * an option — a red bar sells a call, a green bar sells a put — one order,
 * market, of the strike picked by moneyness off the current spot, fired only
 * inside a time-of-day window, with a stop at twice the entry premium. Everything
 * here computes that; the hook does the fetching, the clock and the placing.
 */

import type { Candle, Expiry, Product } from './delta'

export type OptionKind = 'call' | 'put'

/** Loss stopped at 100% of the premium — the mark reaching twice the entry. */
export const STOP_LOSS_MULTIPLE = 2

/**
 * How far the traded strike sits from the money. ITM is capped at 2 and OTM at
 * 5, as asked — the deep wings are illiquid on this book and a fill there is
 * more slippage than signal.
 */
export type Moneyness = 'ITM2' | 'ITM1' | 'ATM' | 'OTM1' | 'OTM2' | 'OTM3' | 'OTM4' | 'OTM5'

export const MONEYNESS_ORDER: Moneyness[] = [
  'ITM2',
  'ITM1',
  'ATM',
  'OTM1',
  'OTM2',
  'OTM3',
  'OTM4',
  'OTM5',
]

/** Which expiry an entry is sold in: the same IST day only, or the nearest live one. */
export type ExpiryRule = 'today' | 'nearest'

export interface StrategyConfig {
  moneyness: Moneyness
  /** Underlying units sold per fire (XAUT). Converted to lots at placement. */
  qty: number
  /** Trading window, inclusive, as `HH:MM` in IST. A window that wraps past
   *  midnight (start > end) is honoured. */
  windowStart: string
  windowEnd: string
  /**
   * Days of the week the strategy trades, as ISO weekdays — Monday 1 to Sunday 7,
   * `extract(isodow)`'s numbering, which is what the settings column stores. The
   * day is the one the *window opened on*, so a window wrapping past midnight
   * belongs to the day it started, not the one it ends in. An empty list trades
   * never.
   */
  tradeDays: number[]
  /**
   * Premium floor, in dollars on the bid. A bar whose strike is bid below this is
   * skipped rather than sold — the strike is fixed by `moneyness`, so the floor
   * vetoes the trade instead of hunting for a richer strike. Zero disables it.
   */
  minPremium: number
  /**
   * Which expiry to sell. `today` takes only the same-day contract on the IST
   * clock and skips the bar when there is none — XAUT does not list one every
   * calendar day, and the same-day contract settles at 21:30 IST, so expect no
   * trades on either. `nearest` takes the nearest unsettled expiry, whatever its
   * date, which is what the strategy did before the rule existed.
   */
  expiryRule: ExpiryRule
}

export const DEFAULT_CONFIG: StrategyConfig = {
  moneyness: 'ATM',
  qty: 1,
  // All day, every day by default, so neither filter bites until it is set.
  windowStart: '00:00',
  windowEnd: '23:59',
  tradeDays: [1, 2, 3, 4, 5, 6, 7],
  // No floor by default: the strategy sells whatever the moneyness resolves to.
  minPremium: 0,
  // Same-day only. Selling a multi-day option because today's is unlisted was the
  // behaviour this rule was added to stop, so it is not the default.
  expiryRule: 'today',
}

// ---------------------------------------------------------------------------
// Candle → which option to sell
// ---------------------------------------------------------------------------

export type CandleColor = 'green' | 'red' | 'flat'

/** Green when the hour closed above where it opened, red below, flat if equal. */
export function candleColor(c: Candle): CandleColor {
  if (c.close > c.open) return 'green'
  if (c.close < c.open) return 'red'
  return 'flat'
}

/**
 * The option a bar tells us to sell: a red (bearish) hour sells the call, a green
 * (bullish) hour sells the put — fading the move's opposite wing. Flat is no
 * signal. The side is always a sell.
 */
export function kindForColor(color: CandleColor): OptionKind | null {
  if (color === 'red') return 'call'
  if (color === 'green') return 'put'
  return null
}

/**
 * The latest *closed* 1h bar in a series sorted oldest-first. The final entry is
 * usually the hour still forming — its close keeps moving — so we take the last
 * bar whose hour has fully elapsed. `nowSec` is passed in rather than read, so
 * this stays pure and testable.
 */
export function lastClosedCandle(
  candles: Candle[],
  nowSec: number,
  resolutionSec = 3600,
): Candle | null {
  for (let i = candles.length - 1; i >= 0; i--) {
    if (candles[i].time + resolutionSec <= nowSec) return candles[i]
  }
  return null
}

// ---------------------------------------------------------------------------
// Moneyness → contract
// ---------------------------------------------------------------------------

/** Signed step from the money: negative is ITM, positive OTM, zero ATM. */
export function moneynessStep(m: Moneyness): number {
  if (m === 'ATM') return 0
  const n = Number(m.replace(/\D/g, ''))
  return m.startsWith('ITM') ? -n : n
}

export interface ResolvedContract {
  product: Product
  strike: number
  /** The at-the-money strike we stepped from, for the readout. */
  atmStrike: number
}

/**
 * Resolve the config's moneyness to a live contract in the given expiry.
 *
 * ATM is the listed strike nearest spot among strikes that actually have the
 * chosen leg. A call gains value as strike falls, so its ITM strikes sit below
 * spot and its OTM strikes above; a put is the mirror. The step walks the sorted
 * strike list in whichever direction is out-of-the-money for that leg, and
 * clamps at the ends rather than returning nothing — the nearest available wing
 * is a better answer than no trade.
 */
export function resolveContract(
  expiry: Expiry,
  kind: OptionKind,
  spot: number,
  moneyness: Moneyness,
): ResolvedContract | null {
  if (!(spot > 0)) return null
  const book = kind === 'call' ? expiry.calls : expiry.puts
  const strikes = [...book.keys()].sort((a, b) => a - b)
  if (strikes.length === 0) return null

  // Nearest listed strike to spot.
  let atmIdx = 0
  let best = Infinity
  strikes.forEach((s, i) => {
    const d = Math.abs(s - spot)
    if (d < best) {
      best = d
      atmIdx = i
    }
  })

  // Ascending index means ascending strike. For a call, OTM is up the list;
  // for a put, OTM is down it.
  const step = moneynessStep(moneyness)
  const dir = kind === 'call' ? 1 : -1
  const idx = Math.min(strikes.length - 1, Math.max(0, atmIdx + step * dir))
  const strike = strikes[idx]
  const product = book.get(strike)
  if (!product) return null
  return { product, strike, atmStrike: strikes[atmIdx] }
}

// ---------------------------------------------------------------------------
// Time-of-day window (IST)
// ---------------------------------------------------------------------------

/** Calendar date and minutes past midnight on the IST clock. */
export function istNow(date: Date): { day: string; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(date)
  const at = (t: string) => parts.find((p) => p.type === t)?.value ?? '00'
  // en-CA gives 24-hour time, but midnight can come back as '24' on some engines.
  const hour = Number(at('hour')) % 24
  return {
    day: `${at('year')}-${at('month')}-${at('day')}`,
    minutes: hour * 60 + Number(at('minute')),
  }
}

/** Minutes past midnight in IST for a given instant. */
export function istMinutes(date: Date): number {
  return istNow(date).minutes
}

/** `HH:MM` → minutes past midnight, or null if it does not parse. */
export function parseHHMM(s: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim())
  if (!m) return null
  const h = Number(m[1])
  const min = Number(m[2])
  if (h > 23 || min > 59) return null
  return h * 60 + min
}

/**
 * The IST date the window `date` sits inside opened on, or null when it sits
 * outside the window entirely.
 *
 * A window whose start is after its end is read as spanning midnight (e.g.
 * 22:00–06:00), and its tail belongs to the day it *opened* on — so the days
 * filter treats a Friday 22:00 window as Friday's right through to Saturday
 * morning. Mirrors `in_ist_window` in
 * [`0016`](../../supabase/migrations/0016_strategy_trade_days.sql).
 */
export function windowDay(date: Date, windowStart: string, windowEnd: string): string | null {
  const { day, minutes } = istNow(date)
  const start = parseHHMM(windowStart)
  const end = parseHHMM(windowEnd)
  if (start === null || end === null) return day // an unparseable window blocks nothing

  if (start <= end) return minutes >= start && minutes <= end ? day : null
  if (minutes >= start) return day
  if (minutes <= end) return previousDay(day)
  return null
}

/** `YYYY-MM-DD` → ISO weekday, Monday 1 to Sunday 7. */
export function isoDow(day: string): number {
  return ((new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7) + 1
}

function previousDay(day: string): string {
  const d = new Date(`${day}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() - 1)
  return d.toISOString().slice(0, 10)
}

/**
 * Whether the strategy may trade at `date`: inside its window, on one of its
 * days. `tradeDays` omitted means every day, so a caller that only cares about
 * the clock reads exactly as it did before the filter existed.
 */
export function inWindow(
  date: Date,
  windowStart: string,
  windowEnd: string,
  tradeDays?: number[],
): boolean {
  const day = windowDay(date, windowStart, windowEnd)
  if (day === null) return false
  return tradeDays === undefined || tradeDays.includes(isoDow(day))
}
