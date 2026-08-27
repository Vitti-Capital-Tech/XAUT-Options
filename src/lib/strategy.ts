/**
 * The auto-strategy's pure logic, with no React and no I/O, so the strike maths
 * and the time window can be reasoned about on their own.
 *
 * The rule is fixed: read the last closed 1h candle of the spot index and buy
 * an option — a red bar buys a call, a green bar buys a put — one order, market,
 * of the strike picked by moneyness off the current spot, fired only inside a
 * time-of-day window, with a bracket set as a share of the premium paid.
 * Everything here computes that; the hook does the fetching, the clock and the
 * placing.
 *
 * It buys, as of [`0046`](../../supabase/migrations/0046_auto_strategy_buys.sql).
 * Every level below therefore points the way a long reads it — the stop under the
 * entry, the target above it — which is the mirror of what these three functions
 * returned when the book was sold.
 */

import type { Candle, Expiry, Product } from './delta'

export type OptionKind = 'call' | 'put'

/**
 * The multiple of the entry premium a stop percentage lands on, which is the
 * form the level is easiest to sanity-check in:
 *
 *      50% → 0.50x entry — a $4 long stops at $2, half the premium lost
 *      25% → 0.75x entry — a $4 long stops at $3
 *
 * The engine arms `avg_entry_price × stopMultiple(pct)` on the mark. Zero means
 * no stop at all, so this returns null rather than 1x — a stop *at* the entry.
 *
 * **100 or more also returns null**, and that is arithmetic rather than
 * validation: the level would land at zero or below, which is not a price an
 * option ever marks at. A long cannot lose more than the premium it paid, so
 * there is nothing for a stop beyond 100% to protect.
 */
export function stopMultiple(stopLossPct: number): number | null {
  if (!(stopLossPct > 0) || stopLossPct >= 100) return null
  return 1 - stopLossPct / 100
}

/**
 * The trailing stop's level for a given premium — the same multiple, applied to
 * the last closed minute's close instead of to the entry:
 *
 *      50% → 0.50x that close — a premium trading at $8 stops at $4
 *      25% → 0.75x that close — the same premium stops at $6
 *
 * Null at zero, meaning no trailing half. The engine takes the **greater** of this
 * and the entry stop, which on a long is the tighter of the two — so this is the
 * level that ratchets up behind a winning position.
 */
export function trailStopLevel(trailStopPct: number, premium: number): number | null {
  if (!(trailStopPct > 0) || trailStopPct >= 100 || !(premium > 0)) return null
  return premium * (1 - trailStopPct / 100)
}

/**
 * The same, for the take-profit — a percent of the premium *made* rather than
 * lost, so the multiple sits above 1x:
 *
 *      70% → 1.70x entry — a $4 long is sold at $6.80
 *     150% → 2.50x entry — the same long is sold at $10.00
 *
 * Null at zero: no take-profit armed. There is no ceiling any more — a long can
 * make several times what it paid, where the short this replaced could never make
 * more than the premium it collected
 * ([`0046`](../../supabase/migrations/0046_auto_strategy_buys.sql)).
 */
export function takeProfitMultiple(takeProfitPct: number): number | null {
  if (!(takeProfitPct > 0)) return null
  return 1 + takeProfitPct / 100
}

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

/** Which expiry an entry is bought in: the same IST day only, or the nearest live one. */
export type ExpiryRule = 'today' | 'nearest'

export interface StrategyConfig {
  moneyness: Moneyness
  /** Underlying units bought per fire (XAUT). Converted to lots at placement. */
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
   * Premium ceiling, in dollars on the ask. A bar whose strike is offered above
   * this is skipped rather than bought — the strike is fixed by `moneyness`, so
   * the cap vetoes the trade instead of hunting for a cheaper strike. Zero
   * disables it.
   *
   * It was a floor on the bid while the strategy sold: a seller's version of "this
   * trade does not pay" is too little collected, a buyer's is too much paid
   * ([`0046`](../../supabase/migrations/0046_auto_strategy_buys.sql)).
   */
  maxPremium: number
  /**
   * Which expiry to buy. `today` takes only the same-day contract on the IST
   * clock and skips the bar when there is none — XAUT does not list one every
   * calendar day, and the same-day contract settles at 21:30 IST, so expect no
   * trades on either. `nearest` takes the nearest unsettled expiry, whatever its
   * date, which is what the strategy did before the rule existed.
   */
  /** The rule used only while `expiryLabel` is unset. */
  expiryRule: ExpiryRule
  /**
   * The chosen expiry as `ddmmyy`, picked from the live chain the way the option
   * chain's tabs are. A date does not roll: once it settles the strategy skips its
   * bars until a new one is chosen, rather than buying a contract nobody chose.
   * Null falls back to `expiryRule`.
   */
  expiryLabel: string | null
  /**
   * Stop-loss as a percent of the premium **paid**, watched on the option's own
   * mark — see `stopMultiple`. 50 stops a $4 long at $2, half the premium lost.
   * Zero arms no stop at all, leaving only the window flatten and expiry
   * settlement to close the position, and so does 100 or more: that level lands at
   * or below zero, and a long's loss is already bounded by what it paid.
   */
  stopLossPct: number
  /**
   * The trailing half of the stop, as the same percent of the premium — but
   * measured against the option's **last closed 1-minute candle** rather than
   * against the entry, and re-read every minute
   * ([`0037`](../../supabase/migrations/0037_auto_trailing_stop.sql)):
   *
   *     trail = close × (1 − trailStopPct / 100)
   *
   * The armed stop is the **greater** of this and the entry stop, which on a long
   * is the tighter of the two — so as the option gains the level follows the
   * premium up and locks the gain in. It follows the premium back *down* too —
   * `greatest` is taken of the two as they stand this minute, not against where the
   * stop has already been — so the level can loosen again, though never past the
   * entry stop.
   *
   * Zero switches trailing off, leaving the fixed entry stop alone.
   */
  trailStopPct: number
  /**
   * Take-profit as a percent of the premium **paid** that you make, watched on the
   * option's own mark — see `takeProfitMultiple`. 70 sells a $4 long at $6.80.
   * Zero arms no take-profit. There is no ceiling: a long can make several times
   * what it paid, so 150 and 300 are ordinary targets where the short this
   * replaced could never clear 100.
   */
  takeProfitPct: number
}

export const DEFAULT_CONFIG: StrategyConfig = {
  moneyness: 'ATM',
  qty: 1,
  // All day, every day by default, so neither filter bites until it is set.
  windowStart: '00:00',
  windowEnd: '23:59',
  tradeDays: [1, 2, 3, 4, 5, 6, 7],
  // No cap by default: the strategy buys whatever the moneyness resolves to.
  maxPremium: 0,
  // Same-day only. Selling a multi-day option because today's is unlisted was the
  // behaviour this rule was added to stop, so it is not the default.
  expiryRule: 'today',
  // Unset until the trader picks a date, so a new account uses the rule above.
  expiryLabel: null,
  // 100% is the 2x-entry stop the strategy was hardcoded to before it was a setting.
  stopLossPct: 100,
  // Off, so an existing account behaves exactly as it did until the number is moved.
  trailStopPct: 0,
  // No take-profit by default: the strategy had none, and the window flatten already
  // closes the day.
  takeProfitPct: 0,
}

// ---------------------------------------------------------------------------
// Candle → which option to buy
// ---------------------------------------------------------------------------

export type CandleColor = 'green' | 'red' | 'flat'

/** Green when the hour closed above where it opened, red below, flat if equal. */
export function candleColor(c: Candle): CandleColor {
  if (c.close > c.open) return 'green'
  if (c.close < c.open) return 'red'
  return 'flat'
}

/**
 * The option a bar tells us to buy: a red (bearish) hour buys the call, a green
 * (bullish) hour buys the put. Flat is no signal, and the side is always a buy
 * ([`0046`](../../supabase/migrations/0046_auto_strategy_buys.sql)).
 *
 * The pairing is the one the strategy has always used; buying rather than selling
 * it inverts what it means. Selling a call into a red hour was a bet the fall
 * would hold — the wing was being faded. Buying one is a bet on the bounce. Same
 * bars, opposite view, and worth being clear-eyed about before reading a run of
 * results.
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
