/**
 * The auto-strategy's pure logic, with no React and no I/O, so the strike maths
 * and the time window can be reasoned about on their own.
 *
 * The rule is small: read the last closed 1h candle of the spot index; a green
 * bar takes one side and a red bar the other, per the chosen bias. The order is
 * one lot, market, of a call or a put picked by moneyness off the current spot,
 * fired only inside a time-of-day window. Everything here computes that; the
 * hook does the fetching, the clock and the placing.
 */

import type { Candle, Expiry, Product } from './delta'
import type { Side } from '../engine/paper'

export type OptionKind = 'call' | 'put'

/** Which way a green candle leans. `sell-on-green` is the spec's first reading;
 *  `buy-on-green` is the "or vice-versa". Red always takes the other side. */
export type Bias = 'sell-on-green' | 'buy-on-green'

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

export interface StrategyConfig {
  kind: OptionKind
  bias: Bias
  moneyness: Moneyness
  /** Lots per fire. One, per the spec; kept a number so it can be raised later. */
  qty: number
  /** Trading window, inclusive, as `HH:MM` in IST. A window that wraps past
   *  midnight (start > end) is honoured. */
  windowStart: string
  windowEnd: string
}

export const DEFAULT_CONFIG: StrategyConfig = {
  kind: 'call',
  bias: 'sell-on-green',
  moneyness: 'ATM',
  qty: 1,
  // All day by default, so the window filters nothing until the trader sets it.
  windowStart: '00:00',
  windowEnd: '23:59',
}

// ---------------------------------------------------------------------------
// Candle → side
// ---------------------------------------------------------------------------

export type CandleColor = 'green' | 'red' | 'flat'

/** Green when the hour closed above where it opened, red below, flat if equal. */
export function candleColor(c: Candle): CandleColor {
  if (c.close > c.open) return 'green'
  if (c.close < c.open) return 'red'
  return 'flat'
}

/** The order side a bar implies, or null for a flat bar — a doji is no signal. */
export function sideFor(color: CandleColor, bias: Bias): Side | null {
  if (color === 'flat') return null
  const greenSide: Side = bias === 'sell-on-green' ? 'sell' : 'buy'
  return color === 'green' ? greenSide : greenSide === 'buy' ? 'sell' : 'buy'
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

/** Minutes past midnight in IST for a given instant. */
export function istMinutes(date: Date): number {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Kolkata',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(date)
  const h = Number(parts.find((p) => p.type === 'hour')?.value ?? '0')
  const m = Number(parts.find((p) => p.type === 'minute')?.value ?? '0')
  return h * 60 + m
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
 * Whether `date`'s IST clock falls in `[start, end]`. A window whose start is
 * after its end is read as spanning midnight (e.g. 22:00–06:00).
 */
export function inWindow(date: Date, windowStart: string, windowEnd: string): boolean {
  const now = istMinutes(date)
  const start = parseHHMM(windowStart)
  const end = parseHHMM(windowEnd)
  if (start === null || end === null) return true // an unparseable window blocks nothing
  return start <= end ? now >= start && now <= end : now >= start || now <= end
}
