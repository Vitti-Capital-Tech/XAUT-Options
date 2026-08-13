/**
 * The Delta Management Strategy's pure logic — no React, no I/O — so the band
 * maths, the strike selection and the session clock can be reasoned about on
 * their own. `planCycle` is the whole engine: hand it the book and the market,
 * and it returns the single next action, or null with a reason.
 *
 * The rules come from Gold_Options_Delta_Strategy.docx. It is sell-only: no leg
 * is ever bought to reduce delta. Every session opens flat, sells N symmetric
 * a call/put pair near the entry premium, keeps net portfolio delta inside the
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
import { bestBid, markPrice, valuePosition, type PositionRow } from '../engine/paper'

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
 *
 * An explicit `expiryLabel` wins, and only while that expiry is still listed:
 * null once it settles, which is what stands the strategy down rather than
 * quietly moving it to a contract nobody chose. With no label the `expiryPick`
 * rule applies.
 */
export function pickExpiry(
  expiries: Expiry[],
  cfg: Pick<DeltaConfig, 'expiryPick'> & { expiryLabel?: string | null },
): Expiry | null {
  if (cfg.expiryLabel) return expiries.find((e) => e.label === cfg.expiryLabel) ?? null
  if (cfg.expiryPick === 'next') return expiries[1] ?? expiries[0] ?? null
  return expiries[0] ?? null
}

export interface DeltaConfig {
  /** Session bounds on the IST clock, `HH:MM`. */
  sessionOpen: string
  sessionClose: string
  /**
   * Days of the week the strategy trades, as ISO weekdays — Monday 1 to Sunday 7,
   * `extract(isodow)`'s numbering, which is what the settings column stores. The
   * day tested is the *session day*, so a session opening Friday 22:00 stays
   * Friday's until it closes. A day left out reads as a closed session: the book
   * is flattened and nothing new is opened.
   */
  tradeDays: number[]
  bandLow: number
  bandHigh: number
  targetLanding: TargetLanding
  bandBuffer: number
  /** Points of |spot − strike| that flag a short leg as needing management. */
  itmTrigger: number
  maxRolls: number
  rollCounts: RollCounts
  /**
   * The premium every sale aims for — the strike quoted closest to this wins.
   * It is the only price rule the strategy has: entries, roll replacements and
   * band corrections all pick against it, so a correction sits where an entry
   * would. There is no separate floor, and none is needed — asking for the
   * closest to a price already says what to sell.
   */
  entryPremium: number
  /**
   * XAUT sold per leg at the open, converted to lots by the contract's own value
   * the way the auto strategy's `qty` is: `lots = round(qty / contractValue)`.
   *
   * This is the spec's N, in XAUT rather than lots. N meant "repeat the pair sale
   * this many times", and since the strike rule gives the same answer each repeat,
   * that was only ever a lot count — so one control expresses both.
   *
   * Δp counts lots with no contract-value factor, so lots scale Δp one-for-one —
   * raising this means scaling `bandLow`/`bandHigh` by the same factor or the band
   * stops meaning anything. At the venue's 0.001 contract value the default is
   * exactly one lot.
   */
  qty: number
  tieBreak: TieBreak
  /** The rule used only while `expiryLabel` is unset. */
  expiryPick: ExpiryPick
  /**
   * The chosen expiry as `ddmmyy`, picked from the live chain the way the option
   * chain's tabs are. A date does not roll: once it settles the strategy stands
   * down until a new one is chosen, rather than falling through to another
   * contract. Null falls back to `expiryPick`.
   */
  expiryLabel: string | null
  cycleSeconds: number
  /**
   * Take-profit on every short the strategy opens, as a price on the option's
   * own mark — not a multiple of what it sold for. 0.7 buys any short leg back
   * when its mark reaches $0.70. Zero disables it.
   */
  takeProfitMark: number
  /**
   * Stop on every short, as a price on the option's own mark: the leg is bought
   * back when its mark *rises* to this. Zero disables it, which is the rules
   * document's behaviour — §5.3 makes the roll budget and exit-only mode the risk
   * control and the spec never defines a stop, so this is an addition.
   *
   * Worth setting generously if at all: a leg going against you is the leg the ITM
   * queue exists to roll, and a stop closes it outright instead, so the premium is
   * never replaced and Δp jumps by that leg's whole contribution.
   */
  stopLossMark: number
  /**
   * Blocked margin, as a percentage of equity, that puts the book into a cut.
   *
   * The strategy is sell-only, and one of its rules — the fresh OTM band
   * correction — grows the book without bound: every breach with the ITM queue
   * exhausted sells another leg nothing pairs off. Margin ratchets up while
   * unrealized losses pull equity down, and with no rule reading either number
   * the two eventually cross. This is that rule.
   *
   * Over the cap the engine stops selling and closes legs instead, most in-the-
   * money first and preferring the side whose exit pulls Δp back toward the band,
   * booking the loss rather than declining to close a leg that is down. Zero
   * disables the guard, the way `takeProfitMark` and `stopLossMark` read zero.
   */
  marginCapPct: number
  /**
   * Where a cut stops — blocked margin as a percentage of equity.
   *
   * Separate from the cap so the control cannot flap: one threshold would cut to
   * just under it, sell, and cut again. Between the two the book is held rather
   * than idle — no entry and no band correction, but rolls still run, since a roll
   * closes q and sells q further out and so cannot grow the book.
   */
  marginTargetPct: number
}

export const DEFAULT_DELTA_CONFIG: DeltaConfig = {
  sessionOpen: '06:00',
  sessionClose: '22:00',
  tradeDays: [1, 2, 3, 4, 5, 6, 7],
  bandLow: -1,
  bandHigh: 1,
  targetLanding: 'edge',
  bandBuffer: 0.4,
  itmTrigger: 5,
  maxRolls: 3,
  rollCounts: 'pass',
  entryPremium: 4,
  // One lot at the venue's 0.001 contract value.
  qty: 0.001,
  tieBreak: 'closest',
  expiryPick: 'nearest',
  // Unset until the trader picks a date, so a new account trades the nearest.
  expiryLabel: null,
  // The engine's own jobs run every 5s (0029), and this is a floor on top of
  // them, so anything higher here is what decides the cadence.
  cycleSeconds: 5,
  takeProfitMark: 0.7,
  // No stop, which is what the rules document specifies.
  stopLossMark: 0,
  // Cut once margin passes equity, and cut down to 90% of it.
  marginCapPct: 100,
  marginTargetPct: 90,
}

/** State that lives for one session and resets at the next open. */
export interface SessionState {
  /** IST `YYYY-MM-DD` the counters below belong to. */
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
// The session clock
// ---------------------------------------------------------------------------

/**
 * The zone the session, the days filter and the session day are all read on.
 *
 * IST, matching the auto strategy and the desk that runs both. The spec writes its
 * session in Sydney terms, but a rule set is not a timezone — the hours are the
 * trader's to choose, and two engines on one screen keeping two different clocks
 * is how a window gets misread.
 */
export const SESSION_ZONE = 'Asia/Kolkata'

/**
 * Calendar day and minutes-past-midnight on the session's own clock. Read
 * through Intl rather than a fixed offset — IST has no daylight saving, but the
 * zone is a parameter and reading it properly costs nothing.
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

/** `YYYY-MM-DD` → ISO weekday, Monday 1 to Sunday 7. */
export function isoDow(day: string): number {
  return ((new Date(`${day}T00:00:00Z`).getUTCDay() + 6) % 7) + 1
}

/**
 * Where the clock sits relative to the session, which session day that is, and
 * whether that day is one the strategy trades.
 *
 * A window whose close is before its open spans midnight; the day is then keyed
 * to the calendar date the session *opened* on, so the counters do not reset
 * halfway through a night — and the days filter reads a session that opened on a
 * Friday as Friday's all the way to its close.
 *
 * A day left out of `tradeDays` reports `closed`, which is what makes the
 * flatten-and-stand-flat branch cover a non-trading day without a rule of its own.
 * `tradeDays` omitted means every day.
 */
export function sessionPhase(
  now: Date,
  cfg: Pick<DeltaConfig, 'sessionOpen' | 'sessionClose'> & { tradeDays?: number[] },
): { phase: SessionPhase; day: string; tradingDay: boolean } {
  const { day, minutes } = zoneNow(now)
  const open = parseHHMM(cfg.sessionOpen)
  const close = parseHHMM(cfg.sessionClose)
  const trades = (d: string) => cfg.tradeDays === undefined || cfg.tradeDays.includes(isoDow(d))
  // A non-trading day is reported closed, whatever the clock says.
  const at = (phase: SessionPhase, d: string) => ({
    phase: trades(d) ? phase : ('closed' as SessionPhase),
    day: d,
    tradingDay: trades(d),
  })

  if (open === null || close === null) return at('closed', day)

  if (open <= close) {
    if (minutes < open) return at('before', day)
    return at(minutes <= close ? 'open' : 'closed', day)
  }

  // Wrapping window: after the open we are in today's session; before the close
  // we are still in the one that opened yesterday.
  if (minutes >= open) return at('open', day)
  if (minutes <= close) return at('open', previousDay(day))
  return at('closed', previousDay(day))
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

/** How far in the money a leg is, in points. Negative when out of the money.
 *  A call is in the money above its strike, a put below it. */
export function itmDistanceOf(kind: OptionKind, strike: number, spot: number): number {
  return kind === 'call' ? spot - strike : strike - spot
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
      itmDistance: itmDistanceOf(kind, strike, spot),
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
 * Lots an entry leg is worth: the XAUT size over that contract's own value.
 * Mirrors `delta_sell_entry` in
 * [`0021`](../../supabase/migrations/0021_qty_and_take_profit.sql) — a missing or
 * zero contract value falls back to one lot rather than sizing off a guess.
 */
export function entryLots(product: Product, cfg: Pick<DeltaConfig, 'qty'>): number {
  const cv = Number(product.contract_value)
  return cv > 0 ? Math.max(1, Math.round(cfg.qty / cv)) : 1
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
// The margin guard
// ---------------------------------------------------------------------------

/**
 * Where an account sits against its two margin thresholds.
 *
 * `cut` is the emergency: blocked margin has passed the cap, so the only thing
 * the engine may do is close legs. `hold` is the wider zone above the target,
 * where the book is frozen against new premium but rolls carry on.
 *
 * Both read false when `marginCapPct` is zero, which is how the guard is turned
 * off. Negative equity lands in `cut` on its own arithmetic — every threshold is
 * then at or below zero, so any open short is over it.
 */
export interface MarginState {
  cut: boolean
  hold: boolean
  /** Blocked margin the cut triggers at. */
  cap: number
  /** Blocked margin a cut works down to. */
  goal: number
  marginBlocked: number
  equity: number
  /** Margin as a percentage of equity, or null when equity is zero. */
  pct: number | null
}

export function marginState(
  cfg: Pick<DeltaConfig, 'marginCapPct' | 'marginTargetPct'>,
  marginBlocked: number,
  equity: number,
): MarginState {
  const cap = (equity * cfg.marginCapPct) / 100
  const goal = (equity * cfg.marginTargetPct) / 100
  const on = cfg.marginCapPct > 0
  return {
    // `marginBlocked > 0` is not redundant with the cap: on a wiped account every
    // threshold is negative, so a flat book would read as cutting with nothing to
    // cut. Nothing with zero blocked margin has anything to close.
    cut: on && marginBlocked > cap && marginBlocked > 0,
    hold: on && marginBlocked > goal,
    cap,
    goal,
    marginBlocked,
    equity,
    // A ratio against equity that is zero or negative says nothing, so it is not
    // reported as a number — callers show "over" instead of a nonsense percentage.
    pct: equity <= 0 ? null : (marginBlocked / equity) * 100,
  }
}

/**
 * Lots to close from one leg to bring margin down to the target.
 *
 * Rounded *up*, unlike every other size in this file: a roll rounds down so a
 * correction cannot overshoot the band, but a cut that lands a hair above the
 * target has not resolved anything and would simply fire again next cycle.
 * Capped at what the leg holds, so the remainder falls to the next cycle and the
 * next leg — which is what keeps the realized loss to the smallest one that
 * clears the breach.
 */
export function cutLots(shortfall: number, marginPerLot: number, openLots: number): number {
  if (!(shortfall > 0) || !(marginPerLot > 0)) return 0
  return Math.min(Math.ceil(shortfall / marginPerLot), openLots)
}

/**
 * A short leg the guard could close. Deliberately *not* a `LegDelta`: that type
 * only exists for legs with a published greek, and `bookDeltas` drops the rest
 * into `missing`. A cut needs the strike, the side and the size — never the delta
 * — so building candidates straight off the positions is what lets the guard
 * close a leg whose greek has not arrived. Standing down on a margin breach to
 * wait for a greek is the one failure this control exists to prevent.
 */
export interface CutCandidate {
  position: PositionRow
  kind: OptionKind
  strike: number
  itmDistance: number
}

/** Every short in the book, as cut candidates. Longs are excluded: their margin
 *  is the premium already paid and closing one frees nothing. */
export function cutCandidates(positions: PositionRow[], spot: number): CutCandidate[] {
  const out: CutCandidate[] = []
  for (const pos of positions) {
    if (pos.net_qty >= 0) continue
    const kind = legKind(pos)
    const strike = Number(pos.strike_price)
    out.push({ position: pos, kind, strike, itmDistance: itmDistanceOf(kind, strike, spot) })
  }
  return out
}

/**
 * The leg to cut: most in-the-money first, on the side whose exit moves Δp
 * toward the band.
 *
 * Most-ITM first is where both the margin and the risk are concentrated, so it
 * frees the most per lot closed. The side preference is what makes this a delta
 * control rather than plain deleveraging — Δp below the band is a book too heavy
 * in short calls, so closing a call is what lifts it, the same reading
 * `correctiveRollSide` uses for the roll queue.
 *
 * The preference sorts, it does not filter. With the corrective side empty the
 * walk falls through to the other one, because a margin breach has to resolve
 * whether or not the tidy version of it is on offer — and with Δp unknown there
 * is no preference to apply, so ITM distance decides alone.
 */
export function pickCutLeg(candidates: CutCandidate[], breach: Breach): CutCandidate | null {
  if (candidates.length === 0) return null
  const preferred = breach ? correctiveRollSide(breach) : null
  const rank = (c: CutCandidate) => (preferred && c.kind === preferred ? 0 : 1)
  return candidates.reduce((best, c) => {
    if (rank(c) !== rank(best)) return rank(c) < rank(best) ? c : best
    return c.itmDistance > best.itmDistance ? c : best
  })
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
  cfg: Pick<DeltaConfig, 'entryPremium' | 'tieBreak'>,
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

// ---------------------------------------------------------------------------
// The cycle
// ---------------------------------------------------------------------------

export type Action =
  /** Daily entry — a symmetric pair at the strikes nearest the entry premium. */
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
  /**
   * Margin over the cap: close lots outright, loss booked, no replacement. Not a
   * roll with `replace: null` — that is the roll budget running out on one side,
   * which is a delta rule. This one answers to equity and outranks every rule
   * below the session-close flatten.
   */
  | { type: 'cut'; leg: CutCandidate; exitQty: number }

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
  /**
   * The account's blocked margin and equity, from `summarizeAccount`. Omit both
   * and the margin guard sits out — the readout still prices the book, which is
   * what lets the panel render before the account summary has loaded.
   */
  marginBlocked?: number
  equity?: number
  /** Per-symbol initial-margin rate, as `summarizeAccount` takes it. */
  imRateFor?: (symbol: string) => number | undefined
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
  /** Whether `day` is one of the configured trading days. */
  tradingDay: boolean
  queue: LegDelta[]
  /** Where the book sits against its margin thresholds; null when not supplied. */
  margin: MarginState | null
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
  const { phase, day, tradingDay } = sessionPhase(now, cfg)

  const live = positions.filter((p) => p.net_qty !== 0)
  const { legs, missing } = bookDeltas(live, tickerFor, spot)
  // Δp in qty (underlying) units, the same unit the band is set in: net_qty counts
  // venue lots, so each leg's lot-sized delta is scaled by the contract value to
  // read as the book's own delta. `dpLots` keeps the unscaled sum, because sizing a
  // correction still counts in lots — see the roll and band-correction steps below.
  const cv = bookContractValue(legs, expiry)
  const dpLots = missing.length === 0 ? portfolioDelta(legs) : null
  const dp = dpLots === null ? null : dpLots * cv
  const queue = itmQueue(legs, cfg)
  const margin =
    input.marginBlocked === undefined || input.equity === undefined
      ? null
      : marginState(cfg, input.marginBlocked, input.equity)
  const base = { dp, breach: null as Breach, phase, day, tradingDay, queue, margin }

  // ---- Session close: flatten, whatever the band says ----------------------
  if (phase !== 'open') {
    if (live.length > 0 && session.flattenedDay !== day) {
      return {
        ...base,
        action: { type: 'flatten', positions: live },
        reason: tradingDay ? 'Session closed — flattening' : 'Not a trading day — flattening',
      }
    }
    return {
      ...base,
      action: null,
      reason: !tradingDay
        ? 'Not a trading day — flat'
        : phase === 'before'
          ? 'Before the session open'
          : 'Session closed — flat overnight',
    }
  }

  // The spot check comes before the expiry one because the cut below needs a
  // price and does not need a contract to trade.
  if (!(spot > 0)) return { ...base, action: null, reason: 'Waiting for a spot price' }

  // ---- Margin guard: over the cap, cutting outranks every rule below --------
  //
  // Ahead of the expiry check deliberately. Closing a leg needs the leg's own
  // quote, not the expiry the strategy trades, and an unlisted or settled expiry
  // standing the strategy down while the book is past its equity is precisely the
  // failure this control exists to prevent. Only the session-close flatten
  // outranks it, and that is a strictly larger cut.
  if (margin?.cut) {
    // Off `live`, not `legs`: a leg still waiting on its greek is missing from
    // `legs` but is every bit as much of a margin problem, and cutting it needs
    // no delta. Δp only decides which side to prefer, so a null one just leaves
    // ITM distance to decide alone.
    const leg = pickCutLeg(cutCandidates(live, spot), dp === null ? null : bandBreach(dp, cfg))
    if (!leg) {
      return {
        ...base,
        action: null,
        reason: `Margin ${pctOf(margin)} of equity — no short left to cut`,
      }
    }
    const open = Math.abs(leg.position.net_qty)
    const perLot =
      valuePosition(
        leg.position,
        tickerFor(leg.position.symbol),
        spot,
        input.imRateFor?.(leg.position.symbol),
      ).marginBlocked / open
    const q = cutLots(margin.marginBlocked - margin.goal, perLot, open)
    if (q <= 0) {
      return {
        ...base,
        action: null,
        reason: `Margin ${pctOf(margin)} of equity — cannot price a cut on ${leg.strike}`,
      }
    }
    return {
      ...base,
      action: { type: 'cut', leg, exitQty: q },
      reason: `Margin ${pctOf(margin)} of equity — cutting ${q} of ${leg.strike}${leg.kind === 'call' ? 'C' : 'P'}`,
    }
  }

  if (!expiry) return { ...base, action: null, reason: 'No expiry listed to trade' }

  // ---- Daily entry ---------------------------------------------------------
  if (session.enteredDay !== day) {
    // Two fresh shorts is the last thing a book already near its cap should add.
    // `enteredDay` stays unset, so the entry is retried once margin allows.
    if (margin?.hold) {
      return {
        ...base,
        action: null,
        reason: `Margin ${pctOf(margin)} of equity — entry held back`,
      }
    }
    const call = pickByPremium(expiry, 'call', cfg, tickerFor)
    const put = pickByPremium(expiry, 'put', cfg, tickerFor)
    if (!call || !put) {
      return {
        ...base,
        action: null,
        reason: `No ${!call ? 'call' : 'put'} strike quoted yet`,
      }
    }
    const callLots = entryLots(call.product, cfg)
    const putLots = entryLots(put.product, cfg)
    return {
      ...base,
      action: {
        type: 'entry',
        legs: [
          { product: call.product, qty: callLots },
          { product: put.product, qty: putLots },
        ],
      },
      reason: `Selling ${callLots} × ${call.strike}C / ${putLots} × ${put.strike}P`,
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

  // Sizing counts in lots, so it works from the unscaled Δp and a target scaled
  // back the same way — `target` is a band figure, in qty units, so `target / cv`
  // brings it into the lot space `dpLots` lives in.
  const dpl = dpLots as number
  const target = landingTarget(cfg, breach)
  const targetLots = target / cv
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
    const q = Math.min(open, rollQty(targetLots, dpl, leg.optionDelta, replacement.optionDelta))
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

  // Step 2 — nothing left to roll: correct the band with fresh sells, picked at
  // the entry premium like every other sale. The spec sized these off a separate
  // delta range, but a price rule already says which strike that is, and one rule
  // the trader can see beats two that have to agree.
  //
  // This is the one rule here that grows the book with nothing to pair it off, so
  // it is the rule the hold zone exists to stop. Δp stays outside the band for
  // now; the cut above is what brings it back once margin passes the cap, and it
  // prefers exactly the side this sell would have corrected.
  if (margin?.hold) {
    return {
      ...base,
      breach,
      action: null,
      reason: `Δp ${fmt(dp)} outside the band — margin ${pctOf(margin)} of equity, correction held back`,
    }
  }

  const sellSide = correctiveSellSide(breach)
  const pick = pickByPremium(expiry, sellSide, cfg, tickerFor)
  if (!pick) {
    return {
      ...base,
      breach,
      action: null,
      reason: `Δp ${fmt(dp)} outside the band — no ${sellSide} strike quoted to correct with`,
    }
  }
  const q = bandQty(targetLots, dpl, pick.optionDelta)
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

/** Margin as a percentage of equity, for the status line. Equity at or below
 *  zero has no meaningful ratio, and saying so beats printing a huge number. */
function pctOf(m: MarginState): string {
  return m.pct === null ? 'over' : `${m.pct.toFixed(0)}%`
}

/**
 * The book's contract value, for scaling lot-sized delta into the qty units the
 * band is set in. It is uniform across a XAUT expiry, so any open leg answers, and
 * a listed strike stands in before the book has any. Falls back to 1 — leaving Δp
 * in lot units — rather than zeroing the reading if no value is to be had.
 */
function bookContractValue(legs: LegDelta[], expiry: Expiry | null): number {
  const fromLeg = legs.length > 0 ? Number(legs[0].position.contract_value) : NaN
  if (fromLeg > 0) return fromLeg
  const product = expiry?.calls.values().next().value ?? expiry?.puts.values().next().value
  const cv = product ? Number(product.contract_value) : NaN
  return cv > 0 ? cv : 1
}
