/**
 * The Delta Management Strategy's pure logic — no React, no I/O — so the band
 * maths, the strike selection and the session clock can be reasoned about on
 * their own. `planCycle` is the whole engine: hand it the book and the market,
 * and it returns the single next action, or null with a reason.
 *
 * The rules come from Gold_Options_Delta_Strategy.docx. It is sell-only: no leg
 * is ever bought to reduce delta. Every session opens flat, sells N symmetric
 * call/put pairs near the entry premium, keeps net portfolio delta inside the
 * band by rolling in-the-money shorts, falls back to fresh out-of-the-money
 * sells when nothing is left to roll, and flattens at the close.
 *
 * Units — the one thing worth being careful about. Δp here is
 *
 *     Δp = Σ (signed lots × the leg's option delta)
 *
 * with no contract-value multiplier, because that is the unit the spec's own
 * worked example is written in: exiting 2 contracts across a 0.25 delta gap
 * moves Δp by 0.5. A band of [-1, 1] is calibrated to that same unit, so the two
 * have to agree. A short call (negative lots, positive delta) pulls Δp down; a
 * short put (negative lots, negative delta) pushes it up.
 */

import type { Expiry, Product, Ticker } from './delta'
import { bestBid, markPrice, type PositionRow } from '../engine/paper'

export type OptionKind = 'call' | 'put'

/**
 * Where a correction aims to land once the band has been breached — the two
 * candidates Section 3.1 names, and only those.
 *
 * B is not a third rule: Section 3 defines it as the distance back from a
 * breached edge to correct to *when the band is used as the landing point*, so
 * it applies to 'edge'. Set B to 0 for 3.1's "land exactly on the breached
 * boundary", which is what the worked example in 5.2 does.
 */
export type TargetLanding = 'edge' | 'mid'

/** What draws down a side's roll budget: one corrective run, or each strike in it. */
export type RollCounts = 'pass' | 'strike'

/** Which strike wins when several sit near the entry premium. */
export type TieBreak = 'closest' | 'above' | 'below'

export type ExpiryPick = 'nearest' | 'next'

/**
 * The expiry the strategy trades, given the live list (nearest first). Shared
 * with the app shell, which subscribes that expiry's strikes to the feed —
 * picking a strike by premium or by delta needs quotes across the whole chain,
 * not just the legs already held.
 */
export function pickExpiry(expiries: Expiry[], pick: ExpiryPick): Expiry | null {
  if (pick === 'next') return expiries[1] ?? expiries[0] ?? null
  return expiries[0] ?? null
}

export interface DeltaConfig {
  /** Session bounds on the Sydney clock, `HH:MM`. */
  sessionOpen: string
  sessionClose: string
  bandLow: number
  bandHigh: number
  targetLanding: TargetLanding
  bandBuffer: number
  /** Points of |spot − strike| that flag a short leg as needing management. */
  itmTrigger: number
  maxRolls: number
  rollCounts: RollCounts
  entryPremium: number
  minPremium: number
  bandDeltaLow: number
  bandDeltaHigh: number
  /** N — call/put pairs sold at the open, as lots per leg. */
  pairs: number
  tieBreak: TieBreak
  expiryPick: ExpiryPick
  cycleSeconds: number
}

export const DEFAULT_DELTA_CONFIG: DeltaConfig = {
  sessionOpen: '06:00',
  sessionClose: '22:00',
  bandLow: -1,
  bandHigh: 1,
  targetLanding: 'edge',
  bandBuffer: 0.4,
  itmTrigger: 5,
  maxRolls: 3,
  rollCounts: 'pass',
  entryPremium: 4,
  minPremium: 2,
  bandDeltaLow: 0.15,
  bandDeltaHigh: 0.25,
  pairs: 1,
  tieBreak: 'closest',
  expiryPick: 'nearest',
  cycleSeconds: 30,
}

/** State that lives for one session and resets at the next open. */
export interface SessionState {
  /** Sydney `YYYY-MM-DD` the counters below belong to. */
  sessionDay: string | null
  rollsUsedCall: number
  rollsUsedPut: number
  enteredDay: string | null
  flattenedDay: string | null
}

export const EMPTY_SESSION: SessionState = {
  sessionDay: null,
  rollsUsedCall: 0,
  rollsUsedPut: 0,
  enteredDay: null,
  flattenedDay: null,
}

// ---------------------------------------------------------------------------
// The Sydney clock
// ---------------------------------------------------------------------------

export const SESSION_ZONE = 'Australia/Sydney'

/**
 * Calendar day and minutes-past-midnight on the session's own clock. Read
 * through Intl rather than a fixed offset, so AEST and AEDT are both right
 * without a daylight-saving table of ours.
 */
export function zoneNow(date: Date, timeZone = SESSION_ZONE): { day: string; minutes: number } {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone,
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

/** `HH:MM` → minutes past midnight, or null if it does not parse. */
export function parseHHMM(s: string): number | null {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s.trim())
  if (!m) return null
  const h = Number(m[1])
  const min = Number(m[2])
  if (h > 23 || min > 59) return null
  return h * 60 + min
}

export type SessionPhase = 'before' | 'open' | 'closed'

/**
 * Where the clock sits relative to the session, and which session day that is.
 *
 * A window whose close is before its open spans midnight; the day is then keyed
 * to the calendar date the session *opened* on, so the counters do not reset
 * halfway through a night.
 */
export function sessionPhase(
  now: Date,
  cfg: Pick<DeltaConfig, 'sessionOpen' | 'sessionClose'>,
): { phase: SessionPhase; day: string } {
  const { day, minutes } = zoneNow(now)
  const open = parseHHMM(cfg.sessionOpen)
  const close = parseHHMM(cfg.sessionClose)
  if (open === null || close === null) return { phase: 'closed', day }

  if (open <= close) {
    if (minutes < open) return { phase: 'before', day }
    return { phase: minutes <= close ? 'open' : 'closed', day }
  }

  // Wrapping window: after the open we are in today's session; before the close
  // we are still in the one that opened yesterday.
  if (minutes >= open) return { phase: 'open', day }
  if (minutes <= close) return { phase: 'open', day: previousDay(day) }
  return { phase: 'closed', day: previousDay(day) }
}

function previousDay(day: string): string {
  const d = new Date(`${day}T00:00:00Z`)
  d.setUTCDate(d.getUTCDate() - 1)
  return d.toISOString().slice(0, 10)
}

// ---------------------------------------------------------------------------
// Portfolio delta
// ---------------------------------------------------------------------------

/** The option delta the venue publishes for a symbol, signed as it comes. */
export function tickerDelta(t: Ticker | undefined): number | null {
  const raw = t?.greeks?.delta
  if (raw === null || raw === undefined || raw === '') return null
  const n = Number(raw)
  return Number.isFinite(n) ? n : null
}

export interface LegDelta {
  position: PositionRow
  kind: OptionKind
  strike: number
  /** The option's own delta, signed: positive for a call, negative for a put. */
  optionDelta: number
  /** signed lots × option delta — this leg's contribution to Δp. */
  contribution: number
  /** How far in the money the *short* leg is, in points. Negative when OTM. */
  itmDistance: number
}

export function legKind(pos: PositionRow): OptionKind {
  return pos.contract_type === 'put_options' ? 'put' : 'call'
}

/**
 * Every leg's delta contribution. Legs whose ticker has no published greek are
 * dropped and reported separately — guessing a delta would quietly corrupt Δp,
 * and the engine refuses to act on a partial book rather than mis-size a roll.
 */
export function bookDeltas(
  positions: PositionRow[],
  tickerFor: (symbol: string) => Ticker | undefined,
  spot: number,
): { legs: LegDelta[]; missing: PositionRow[] } {
  const legs: LegDelta[] = []
  const missing: PositionRow[] = []

  for (const pos of positions) {
    if (pos.net_qty === 0) continue
    const optionDelta = tickerDelta(tickerFor(pos.symbol))
    if (optionDelta === null) {
      missing.push(pos)
      continue
    }
    const kind = legKind(pos)
    const strike = Number(pos.strike_price)
    legs.push({
      position: pos,
      kind,
      strike,
      optionDelta,
      contribution: pos.net_qty * optionDelta,
      // A call is in the money above its strike, a put below it.
      itmDistance: kind === 'call' ? spot - strike : strike - spot,
    })
  }

  return { legs, missing }
}

export function portfolioDelta(legs: LegDelta[]): number {
  return legs.reduce((sum, l) => sum + l.contribution, 0)
}

export type Breach = 'low' | 'high' | null

export function bandBreach(dp: number, cfg: Pick<DeltaConfig, 'bandLow' | 'bandHigh'>): Breach {
  if (dp < cfg.bandLow) return 'low'
  if (dp > cfg.bandHigh) return 'high'
  return null
}

/**
 * The Δp every correction aims for. `edge` is the breached boundary itself,
 * `buffer` pulls that inward by B, `mid` is the middle of the band. Clamped so a
 * buffer wider than the band cannot land the target on the far side.
 */
export function landingTarget(cfg: DeltaConfig, breach: Exclude<Breach, null>): number {
  const mid = (cfg.bandLow + cfg.bandHigh) / 2
  if (cfg.targetLanding === 'mid') return mid
  const edge = breach === 'low' ? cfg.bandLow : cfg.bandHigh
  const pulled = breach === 'low' ? edge + cfg.bandBuffer : edge - cfg.bandBuffer
  return breach === 'low' ? Math.min(pulled, mid) : Math.max(pulled, mid)
}

/**
 * Which side carries the legs worth exiting to fix a breach.
 *
 * Δp below the band is a book that is too short-call heavy, so exiting an ITM
 * call is what lifts it; above the band it is the puts. Selling fresh premium is
 * the mirror — a short put adds delta, a short call removes it — which is why
 * `correctiveRollSide` and `correctiveSellSide` are opposites.
 */
export function correctiveRollSide(breach: Exclude<Breach, null>): OptionKind {
  return breach === 'low' ? 'call' : 'put'
}

export function correctiveSellSide(breach: Exclude<Breach, null>): OptionKind {
  return breach === 'low' ? 'put' : 'call'
}

/**
 * Step 0 — the ITM queue: every short leg at or beyond the trigger distance,
 * most in-the-money first. Rebuilt from scratch each cycle, so a strike's place
 * in it moves as the underlying does.
 */
export function itmQueue(legs: LegDelta[], cfg: Pick<DeltaConfig, 'itmTrigger'>): LegDelta[] {
  return legs
    .filter((l) => l.position.net_qty < 0 && l.itmDistance >= cfg.itmTrigger)
    .sort((a, b) => b.itmDistance - a.itmDistance)
}

// ---------------------------------------------------------------------------
// Sizing
// ---------------------------------------------------------------------------

/**
 * Round a contract count down, with a hair of tolerance first.
 *
 * The spec says round down, and a plain floor gets that wrong on its own worked
 * example: the deltas are two-decimal quantities, but 0.55 − 0.30 is
 * 0.2500000000000001 in binary, so 0.5 ÷ that is 1.9999999999999996 and floors
 * to 1 where the spec says 2. The tolerance is far smaller than any real
 * quantity here and far larger than the representation error, so it only ever
 * recovers an integer the arithmetic just missed.
 */
function floorContracts(q: number): number {
  if (!Number.isFinite(q) || q <= 0) return 0
  return Math.floor(q + 1e-9)
}

/**
 * Contracts to exit from an ITM leg, replacing them further out:
 *
 *     q = (target − Δp) ÷ (d_itm − d_replacement)        [round down]
 *
 * with both deltas taken as magnitudes. Rounding down is the spec's, and it is
 * what keeps a correction from overshooting the band: a breach worth less than
 * one contract sizes to zero and is left alone.
 */
export function rollQty(target: number, dp: number, dItm: number, dReplacement: number): number {
  const gap = Math.abs(dItm) - Math.abs(dReplacement)
  if (!(gap > 0)) return 0
  return floorContracts(Math.abs(target - dp) / gap)
}

/**
 * Contracts to sell fresh when nothing is left to roll:
 *
 *     q = (target − Δp) ÷ d_selected
 *
 * Rounded down for the same reason — the whole point of picking a lower-delta
 * strike here is that each contract moves Δp less, so overshooting would undo it.
 */
export function bandQty(target: number, dp: number, dSelected: number): number {
  const d = Math.abs(dSelected)
  if (!(d > 0)) return 0
  return floorContracts(Math.abs(target - dp) / d)
}

// ---------------------------------------------------------------------------
// Strike selection
// ---------------------------------------------------------------------------

/** The premium a sale of this contract would actually collect — the bid, or the
 *  mark when the book is momentarily empty on that side. */
export function salePremium(t: Ticker | undefined): number | null {
  return bestBid(t) ?? markPrice(t)
}

export interface StrikePick {
  product: Product
  strike: number
  premium: number
  optionDelta: number
}

function book(expiry: Expiry, kind: OptionKind): Map<number, Product> {
  return kind === 'call' ? expiry.calls : expiry.puts
}

/** Strikes strictly further out of the money than `from`, for that leg. */
function furtherOtm(strike: number, from: number, kind: OptionKind): boolean {
  return kind === 'call' ? strike > from : strike < from
}

/**
 * The strike to sell for a daily entry or a roll replacement: the one whose
 * premium sits nearest the entry premium, never below the floor.
 *
 * `beyond` restricts the search to strikes further out than a given one, which
 * is what makes a roll a roll — the replacement always sits further from the
 * money than the leg it replaces.
 */
export function pickByPremium(
  expiry: Expiry,
  kind: OptionKind,
  cfg: Pick<DeltaConfig, 'entryPremium' | 'minPremium' | 'tieBreak'>,
  tickerFor: (symbol: string) => Ticker | undefined,
  beyond?: number,
): StrikePick | null {
  const candidates: StrikePick[] = []

  for (const [strike, product] of book(expiry, kind)) {
    if (beyond !== undefined && !furtherOtm(strike, beyond, kind)) continue
    const ticker = tickerFor(product.symbol)
    const premium = salePremium(ticker)
    const optionDelta = tickerDelta(ticker)
    if (premium === null || optionDelta === null) continue
    // Section 6: nothing is ever sold below the floor.
    if (premium < cfg.minPremium) continue
    candidates.push({ product, strike, premium, optionDelta })
  }

  if (candidates.length === 0) return null

  const closest = () =>
    candidates.reduce((best, c) =>
      Math.abs(c.premium - cfg.entryPremium) < Math.abs(best.premium - cfg.entryPremium) ? c : best,
    )

  if (cfg.tieBreak === 'above') {
    const above = candidates.filter((c) => c.premium >= cfg.entryPremium)
    // Nearest from above: the cheapest of those still at or over the target.
    return above.length ? above.reduce((b, c) => (c.premium < b.premium ? c : b)) : closest()
  }
  if (cfg.tieBreak === 'below') {
    const below = candidates.filter((c) => c.premium <= cfg.entryPremium)
    return below.length ? below.reduce((b, c) => (c.premium > b.premium ? c : b)) : closest()
  }
  return closest()
}

/**
 * The strike to sell for a band correction: one inside the band-correction delta
 * range, deliberately further out than the entry strikes so each contract moves
 * Δp less. The floor still applies. Of those in range, the one nearest the
 * middle of it.
 */
export function pickByDelta(
  expiry: Expiry,
  kind: OptionKind,
  cfg: Pick<DeltaConfig, 'bandDeltaLow' | 'bandDeltaHigh' | 'minPremium'>,
  tickerFor: (symbol: string) => Ticker | undefined,
): StrikePick | null {
  const lo = Math.min(cfg.bandDeltaLow, cfg.bandDeltaHigh)
  const hi = Math.max(cfg.bandDeltaLow, cfg.bandDeltaHigh)
  const mid = (lo + hi) / 2

  let best: StrikePick | null = null
  for (const [strike, product] of book(expiry, kind)) {
    const ticker = tickerFor(product.symbol)
    const premium = salePremium(ticker)
    const optionDelta = tickerDelta(ticker)
    if (premium === null || optionDelta === null) continue
    if (premium < cfg.minPremium) continue
    const mag = Math.abs(optionDelta)
    if (mag < lo || mag > hi) continue
    if (!best || Math.abs(mag - mid) < Math.abs(Math.abs(best.optionDelta) - mid)) {
      best = { product, strike, premium, optionDelta }
    }
  }
  return best
}

// ---------------------------------------------------------------------------
// The cycle
// ---------------------------------------------------------------------------

export type Action =
  /** Daily entry — N symmetric pairs at the strikes nearest the entry premium. */
  | { type: 'entry'; legs: { product: Product; qty: number }[] }
  /** Session close — buy back everything and stand flat overnight. */
  | { type: 'flatten'; positions: PositionRow[] }
  /**
   * Partial exit and replace. `replace` is null once the side is exit-only, which
   * is what turns the same trigger into a full exit with the loss booked.
   */
  | {
      type: 'roll'
      side: OptionKind
      leg: LegDelta
      exitQty: number
      replace: { product: Product; qty: number } | null
    }
  /** Fresh OTM sell, with no ITM leg left to roll. */
  | { type: 'band'; side: OptionKind; product: Product; qty: number }

export interface CycleInput {
  now: Date
  cfg: DeltaConfig
  session: SessionState
  positions: PositionRow[]
  expiry: Expiry | null
  spot: number
  tickerFor: (symbol: string) => Ticker | undefined
  /** Strikes already acted on in this corrective pass — touched at most once. */
  touched: ReadonlySet<string>
}

export interface CyclePlan {
  action: Action | null
  /** Why, in a line, for the status readout. Always set. */
  reason: string
  /** Present whenever the book could be valued, so the UI can show it live. */
  dp: number | null
  breach: Breach
  phase: SessionPhase
  day: string
  queue: LegDelta[]
}

/**
 * One pass of the intraday loop, as a single next action.
 *
 * Priority is the spec's: flatten at the close, enter at the open, then rebuild
 * the ITM queue and resolve it, and only when that queue is exhausted correct the
 * band with fresh OTM sells. Returning one action at a time rather than a batch
 * is deliberate — Δp is recomputed off fresh marks before each step, so a
 * correction can never be sized against a book it has already changed.
 */
export function planCycle(input: CycleInput): CyclePlan {
  const { now, cfg, session, positions, expiry, spot, tickerFor, touched } = input
  const { phase, day } = sessionPhase(now, cfg)

  const live = positions.filter((p) => p.net_qty !== 0)
  const { legs, missing } = bookDeltas(live, tickerFor, spot)
  const dp = missing.length === 0 ? portfolioDelta(legs) : null
  const queue = itmQueue(legs, cfg)
  const base = { dp, breach: null as Breach, phase, day, queue }

  // ---- Session close: flatten, whatever the band says ----------------------
  if (phase !== 'open') {
    if (live.length > 0 && session.flattenedDay !== day) {
      return { ...base, action: { type: 'flatten', positions: live }, reason: 'Session closed — flattening' }
    }
    return {
      ...base,
      action: null,
      reason: phase === 'before' ? 'Before the session open' : 'Session closed — flat overnight',
    }
  }

  if (!expiry) return { ...base, action: null, reason: 'No expiry listed to trade' }
  if (!(spot > 0)) return { ...base, action: null, reason: 'Waiting for a spot price' }

  // ---- Daily entry ---------------------------------------------------------
  if (session.enteredDay !== day) {
    if (cfg.pairs <= 0) return { ...base, action: null, reason: 'N is zero — no entry to place' }
    const call = pickByPremium(expiry, 'call', cfg, tickerFor)
    const put = pickByPremium(expiry, 'put', cfg, tickerFor)
    if (!call || !put) {
      return {
        ...base,
        action: null,
        reason: `No ${!call ? 'call' : 'put'} strike at or above the $${cfg.minPremium} floor yet`,
      }
    }
    return {
      ...base,
      action: {
        type: 'entry',
        legs: [
          { product: call.product, qty: cfg.pairs },
          { product: put.product, qty: cfg.pairs },
        ],
      },
      reason: `Selling ${cfg.pairs} pair${cfg.pairs === 1 ? '' : 's'} — ${call.strike}C / ${put.strike}P`,
    }
  }

  // ---- Rebalance -----------------------------------------------------------
  if (dp === null) {
    return { ...base, action: null, reason: `Waiting on greeks for ${missing.length} leg(s)` }
  }

  const breach = bandBreach(dp, cfg)
  if (!breach) {
    return { ...base, breach, action: null, reason: `Δp ${fmt(dp)} — inside the band` }
  }

  const target = landingTarget(cfg, breach)
  const rollSide = correctiveRollSide(breach)
  const used = rollSide === 'call' ? session.rollsUsedCall : session.rollsUsedPut
  const exitOnly = used >= cfg.maxRolls

  // Step 1 — walk the ITM queue on the side whose exit lifts Δp toward target.
  for (const leg of queue) {
    if (leg.kind !== rollSide) continue
    if (touched.has(leg.position.symbol)) continue
    const open = Math.abs(leg.position.net_qty)

    // Exit-only: the trigger is still resolved, but in full and with no
    // replacement, so the loss is booked and the side stops growing. Read as
    // part of the same corrective walk — it is 5.2's step with 5.3's budget
    // spent, not a separate unconditional rule.
    if (exitOnly) {
      return {
        ...base,
        breach,
        action: { type: 'roll', side: rollSide, leg, exitQty: open, replace: null },
        reason: `${rollSide === 'call' ? 'Calls' : 'Puts'} exit-only — closing ${leg.strike} in full`,
      }
    }

    const replacement = pickByPremium(expiry, rollSide, cfg, tickerFor, leg.strike)
    if (!replacement) continue
    const q = Math.min(open, rollQty(target, dp, leg.optionDelta, replacement.optionDelta))
    if (q <= 0) continue

    return {
      ...base,
      breach,
      action: {
        type: 'roll',
        side: rollSide,
        leg,
        exitQty: q,
        replace: { product: replacement.product, qty: q },
      },
      reason: `Δp ${fmt(dp)} → ${fmt(target)} — rolling ${q} of ${leg.strike} out to ${replacement.strike}`,
    }
  }

  // Step 2 — nothing left to roll: correct the band with fresh OTM sells.
  const sellSide = correctiveSellSide(breach)
  const pick = pickByDelta(expiry, sellSide, cfg, tickerFor)
  if (!pick) {
    return {
      ...base,
      breach,
      action: null,
      reason: `Δp ${fmt(dp)} outside the band — no ${sellSide} strike in the ${cfg.bandDeltaLow}–${cfg.bandDeltaHigh} delta range`,
    }
  }
  const q = bandQty(target, dp, pick.optionDelta)
  if (q <= 0) {
    return { ...base, breach, action: null, reason: `Δp ${fmt(dp)} — breach is under one contract` }
  }

  return {
    ...base,
    breach,
    action: { type: 'band', side: sellSide, product: pick.product, qty: q },
    reason: `Δp ${fmt(dp)} → ${fmt(target)} — band correction, selling ${q} × ${pick.strike}${sellSide === 'call' ? 'C' : 'P'}`,
  }
}

function fmt(n: number): string {
  return n.toFixed(2)
}
