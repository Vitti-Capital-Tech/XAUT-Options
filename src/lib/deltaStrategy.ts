/**
 * The Delta Management Strategy's pure logic — no React, no I/O — so the band
 * maths, the strike selection and the session clock can be reasoned about on
 * their own. `planCycle` is the whole engine: hand it the book and the market,
 * and it returns the single next action, or null with a reason.
 *
 * The rules come from Gold_Options_Delta_Strategy.docx. Every session opens flat,
 * sells one symmetric call/put pair near the entry premium, keeps net portfolio
 * delta inside the band, and flattens at the close.
 *
 * How the band is defended is the one thing that differs between the two books
 * this drives — `mode` on `CycleInput`, read off the account's kind:
 *
 *   options   the document's own rule, and sell-only: roll an in-the-money short
 *             further out, fall back to a fresh out-of-the-money sell, and never
 *             buy an option to reduce delta
 *   futures   one trade in the XAUT perpetual, bought or sold, and no option is
 *             touched to move Δp at all
 *
 * Everything else — the session clock, the entry, the band and its gamma
 * derivation, the brackets, the margin guard, the close — is shared by both.
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

import {
  isPerp,
  resolveTargetExpiry,
  type Expiry,
  type ExpiryRule,
  type Product,
  type Ticker,
} from './delta'
import {
  FALLBACK_SHORT_IM_RATE,
  bestBid,
  markPrice,
  valuePosition,
  type PositionRow,
  type Side,
} from '../engine/paper'

export type OptionKind = 'call' | 'put'

/**
 * What a leg is, for the purpose of measuring Δp — the two option kinds plus the
 * perpetual a futures-hedged book carries.
 *
 * Kept apart from `OptionKind` on purpose: a perpetual is a leg of the book and
 * has to be in Δp, but it is never a thing the strike picker may choose, never a
 * side a roll can be taken on, and never a candidate for a margin cut. The type
 * is what stops it being passed to any of them.
 */
export type LegKind = OptionKind | 'perp'

/**
 * How a book brings Δp back inside its band.
 *
 * `options` is the strategy as the rules document writes it: roll an in-the-money
 * short further out, and fall back to a fresh out-of-the-money sell. `futures`
 * replaces both with one trade in the XAUT perpetual, bought or sold.
 *
 * Not a setting — it is read off the account's kind, so the page a trader is
 * looking at and the rule the engine runs cannot disagree. See
 * [`0044`](../../supabase/migrations/0044_futures_delta_hedge.sql).
 */
export type HedgeMode = 'options' | 'futures'

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

/**
 * An expiry picker fallback when no explicit date is chosen.
 *
 *   nearest   take the nearest listed expiry
 *   next      take the second listed expiry
 */
export type ExpiryPick = 'nearest' | 'next'

/**
 * An explicit `expiryLabel` wins, and only while that expiry is still listed:
 * null once it settles, which is what stands the strategy down rather than
 * quietly moving it to a contract nobody chose. Dynamic rule labels (rule:today,
 * rule:tomorrow, rule:friday) or expiryRule dynamically resolve the live date.
 */
export function pickExpiry(
  expiries: Expiry[],
  cfg: Pick<DeltaConfig, 'expiryPick'> & { expiryLabel?: string | null; expiryRule?: ExpiryRule },
  now: Date = new Date(),
): Expiry | null {
  if (cfg.expiryLabel && cfg.expiryLabel.startsWith('rule:')) {
    const rule = cfg.expiryLabel.replace('rule:', '') as ExpiryRule
    return resolveTargetExpiry(expiries, rule, null, now)
  }
  if (cfg.expiryRule && cfg.expiryRule !== 'fixed') {
    return resolveTargetExpiry(expiries, cfg.expiryRule, cfg.expiryLabel, now)
  }
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
  /**
   * The band, as typed in. In force whenever `gammaMultiplier` is zero, and the
   * fallback whenever a gamma-derived band cannot be computed — see
   * `effectiveBand`.
   */
  bandLow: number
  bandHigh: number
  /**
   * Ties the band's width to the book's own gamma instead of holding it fixed:
   * the band becomes `±|Γp| × gammaMultiplier`, recomputed every cycle, so it
   * moves as gamma does. At `Γp = 0.5` a multiplier of 2 gives `[-1, +1]`.
   *
   * Zero switches it off and `bandLow`/`bandHigh` stand instead. The default is
   * 2, so the band is gamma-derived out of the box and the stored pair is only
   * the fallback — set this to 0 to go back to a band that is typed in.
   *
   * Note what this does to a book that is losing: gamma is largest where the
   * strikes are nearest the money, so a book being run over gets a *wider*
   * tolerance at exactly the moment Δp is moving fastest. That is the intended
   * reading — the band is meant to scale with how fast the book breaches — but it
   * is the opposite of a risk limit, and the margin guard, not this, is what
   * bounds the book.
   */
  gammaMultiplier: number
  targetLanding: TargetLanding
  bandBuffer: number
  /** Points of |spot − strike| that flag a short leg as needing management.
   *  Options-hedged books only — a futures hedge reads Δp, not distance. */
  itmTrigger: number
  maxRolls: number
  rollCounts: RollCounts
  /**
   * Leverage the futures hedge is opened at, on a futures-hedged book. Margin is
   * `notional / leverage`, floored at the contract's own 1% — so 100, the
   * default and the venue's maximum, is the cheapest a hedge can be carried.
   *
   * Worth being clear about what it does and does not change: the hedge's P&L is
   * the perpetual's move against its size, whatever this says. Leverage sets the
   * margin the position blocks, and nothing else. Ignored on an options-hedged
   * book, which never opens one.
   */
  hedgeLeverage: number
  /**
   * The premium every sale aims for — the strike quoted closest to this wins.
   * It is the only price rule the strategy has: entries, roll replacements and
   * band corrections all pick against it, so a correction sits where an entry
   * would. There is no separate floor, and none is needed — asking for the
   * closest to a price already says what to sell.
   */
  entryPremium: number
  /** Minimum premium floor for entry pairs; 0 means no floor. */
  entryPremiumMin: number
  /** Maximum premium ceiling for entry pairs; 0 means no ceiling. */
  entryPremiumMax: number
  /** Number of symmetric pairs to short at the session open (default 1). */
  pairsCount: number
  /** Shift percentage of ATM exit price to sell the replacement position at (default 50%). */
  shiftPct: number
  /** Maximum ATM shifts allowed per side per session (default 1). */
  maxShifts: number
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
  /**
   * USD notional ceiling per contract. A sale that would take a strike past it
   * is not stacked there — the pick moves to the next-nearest premium with room,
   * and the size is trimmed to whatever that strike can still take.
   *
   *     notional at a strike = spot × contract_value × |net_qty|
   *
   * At a spot of 4,341 one lot is $4.34 of notional, so 95,000 is about 21,880
   * lots — 21.9 XAUT — per contract.
   *
   * Per *contract*, not per strike price: a call and a put at 4,400 get the cap
   * each, being unrelated exposures on opposite sides of spot.
   *
   * Zero switches it off. It governs where new sales go and nothing else — a
   * strike drifting past the cap because spot moved is not closed, it just stops
   * receiving.
   */
  maxNotionalPerStrike: number
  tieBreak: TieBreak
  /** The rule used only while `expiryLabel` is unset. */
  expiryPick: ExpiryPick
  /** Dynamic expiry rule filter for Futures strategy: today (0 DTE), tomorrow (1 DTE), friday (weekly), fixed */
  expiryRule?: ExpiryRule
  /**
   * The chosen expiry as `ddmmyy`, picked from the live chain the way the option
   * chain's tabs are. A date does not roll: once it settles the strategy stands
   * down until a new one is chosen, rather than falling through to another
   * contract. Null falls back to `expiryPick` / `expiryRule`.
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
   * just under it, sell, and cut again. The gap between the two is pure
   * hysteresis — a cut leaves `cap - goal` of headroom before the next one can
   * fire, which is what keeps the cut and the band correction from trading
   * against each other every cycle.
   *
   * It is only a depth. Nothing is gated on it: every rule runs at every margin
   * below the cap.
   */
  marginTargetPct: number
  /** Multi-window schedule configurations for Futures Strategy */
  scheduleWindows?: ScheduleWindow[]
}

/** A single schedule window with window-specific parameters in Futures Strategy. */
export interface ScheduleWindow {
  id: string
  name?: string
  startTime: string // "HH:MM" (IST)
  endTime: string // "HH:MM" (IST)
  entryPremium: number
  entryPremiumMin: number
  entryPremiumMax: number
  pairsCount: number
  qty: number
  maxNotionalPerStrike: number
  tieBreak: TieBreak
  bandLow: number
  bandHigh: number
  targetLanding: TargetLanding
  bandBuffer: number
  hedgeLeverage: number
  shiftPct: number
  maxShifts: number
  takeProfitMark: number
  stopLossMark: number
  marginCapPct: number
  marginTargetPct: number
}

export function defaultScheduleWindow(id = 'win_1', cfg?: Partial<DeltaConfig>): ScheduleWindow {
  return {
    id,
    name: 'Window 1',
    startTime: cfg?.sessionOpen ?? '01:30',
    endTime: cfg?.sessionClose ?? '17:00',
    entryPremium: cfg?.entryPremium ?? 4,
    entryPremiumMin: cfg?.entryPremiumMin ?? 2,
    entryPremiumMax: cfg?.entryPremiumMax ?? 4,
    pairsCount: cfg?.pairsCount ?? 3,
    qty: cfg?.qty ?? 0.001,
    maxNotionalPerStrike: cfg?.maxNotionalPerStrike ?? 95000,
    tieBreak: cfg?.tieBreak ?? 'closest',
    bandLow: cfg?.bandLow ?? -1.5,
    bandHigh: cfg?.bandHigh ?? 1.5,
    targetLanding: cfg?.targetLanding ?? 'edge',
    bandBuffer: cfg?.bandBuffer ?? 0.2,
    hedgeLeverage: cfg?.hedgeLeverage ?? 100,
    shiftPct: cfg?.shiftPct ?? 50,
    maxShifts: cfg?.maxShifts ?? 1,
    takeProfitMark: cfg?.takeProfitMark ?? 0.7,
    stopLossMark: cfg?.stopLossMark ?? 0,
    marginCapPct: cfg?.marginCapPct ?? 100,
    marginTargetPct: cfg?.marginTargetPct ?? 90,
  }
}

/**
 * Finds the currently active schedule window given the current IST timestamp.
 */
export function findActiveScheduleWindow(
  windows: ScheduleWindow[],
  now: Date = new Date(),
  tradeDays: number[] = [1, 2, 3, 4, 5, 6, 7],
): { activeWindow: ScheduleWindow | null; phase: 'open' | 'closed'; sessionDay: string } {
  const istDate = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Kolkata' }))
  const istMinutes = istDate.getHours() * 60 + istDate.getMinutes()
  const istDay = istDate.getDay() // 0=Sun, 1=Mon, ..., 6=Sat
  const isoDay = istDay === 0 ? 7 : istDay
  const todayStr = istDate.toISOString().slice(0, 10)

  if (!tradeDays.includes(isoDay)) {
    return { activeWindow: null, phase: 'closed', sessionDay: todayStr }
  }

  if (!windows || windows.length === 0) {
    return { activeWindow: null, phase: 'closed', sessionDay: todayStr }
  }

  for (const win of windows) {
    const [oH, oM] = win.startTime.split(':').map(Number)
    const [cH, cM] = win.endTime.split(':').map(Number)
    const oMin = (oH || 0) * 60 + (oM || 0)
    const cMin = (cH || 0) * 60 + (cM || 0)

    let isOpen = false
    let sessionDay = todayStr

    if (oMin <= cMin) {
      isOpen = istMinutes >= oMin && istMinutes <= cMin
      sessionDay = todayStr
    } else {
      // Midnight wrap
      if (istMinutes >= oMin) {
        isOpen = true
        sessionDay = todayStr
      } else if (istMinutes <= cMin) {
        isOpen = true
        const prevDay = new Date(istDate.getTime() - 24 * 60 * 60 * 1000)
        sessionDay = prevDay.toISOString().slice(0, 10)
      }
    }

    if (isOpen) {
      return { activeWindow: win, phase: 'open', sessionDay }
    }
  }

  return { activeWindow: null, phase: 'closed', sessionDay: todayStr }
}

export const DEFAULT_DELTA_CONFIG: DeltaConfig = {
  sessionOpen: '06:00',
  sessionClose: '22:00',
  tradeDays: [1, 2, 3, 4, 5, 6, 7],
  bandLow: -1,
  bandHigh: 1,
  // On by default: the band is derived from the book's gamma, and the pair above
  // is only what stands in while there is no gamma to derive it from.
  gammaMultiplier: 2,
  targetLanding: 'edge',
  bandBuffer: 0.4,
  itmTrigger: 5,
  maxRolls: 3,
  rollCounts: 'pass',
  entryPremium: 4,
  entryPremiumMin: 0,
  entryPremiumMax: 0,
  pairsCount: 1,
  shiftPct: 50,
  maxShifts: 1,
  // One lot at the venue's 0.001 contract value.
  qty: 0.001,
  maxNotionalPerStrike: 95_000,
  tieBreak: 'closest',
  expiryPick: 'nearest',
  expiryRule: 'today',
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
  // The venue's maximum, which on a hedge is the right end of the range: it
  // blocks the least margin for the same position, and the position's risk is
  // its size either way.
  hedgeLeverage: 100,
  scheduleWindows: [],
}

/** State that lives for one session and resets at the next open. */
export interface SessionState {
  /** IST `YYYY-MM-DD` the counters below belong to. */
  sessionDay: string | null
  rollsUsedCall: number
  rollsUsedPut: number
  shiftsUsedCall: number
  shiftsUsedPut: number
  enteredDay: string | null
  flattenedDay: string | null
}

export const EMPTY_SESSION: SessionState = {
  sessionDay: null,
  rollsUsedCall: 0,
  rollsUsedPut: 0,
  shiftsUsedCall: 0,
  shiftsUsedPut: 0,
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

/**
 * The option's gamma, or null where the venue has not published one.
 *
 * Read on the same terms as delta and treated the same way: a leg missing it is
 * a leg the book cannot be measured through. Gamma is always quoted positive —
 * an option gains delta as the underlying rises whichever kind it is — so the
 * sign of a leg's contribution comes entirely from `net_qty`, which makes a short
 * book's total gamma negative.
 */
export function tickerGamma(t: Ticker | undefined): number | null {
  const raw = t?.greeks?.gamma
  if (raw === null || raw === undefined || raw === '') return null
  const n = Number(raw)
  return Number.isFinite(n) ? n : null
}

export interface LegDelta {
  position: PositionRow
  kind: LegKind
  /** NaN on the perpetual, which has no strike. */
  strike: number
  /** The contract's own delta, signed: positive for a call, negative for a put,
   *  and exactly 1 on the perpetual — one lot of it is one lot of the underlying. */
  optionDelta: number
  /** signed lots × delta — this leg's contribution to Δp. */
  contribution: number
  /** The option's own gamma, always positive as the venue quotes it. Zero on the
   *  perpetual, whose delta does not move with spot. */
  optionGamma: number
  /** signed lots × gamma — this leg's contribution to Γp. Negative on a short. */
  gammaContribution: number
  /** How far in the money the *short* leg is, in points. Negative when OTM, and
   *  −∞ on the perpetual, which is never in the money and never queued. */
  itmDistance: number
}

export function legKind(pos: PositionRow): LegKind {
  if (isPerp(pos.contract_type)) return 'perp'
  return pos.contract_type === 'put_options' ? 'put' : 'call'
}

/** How far in the money a leg is, in points. Negative when out of the money.
 *  A call is in the money above its strike, a put below it. */
export function itmDistanceOf(kind: OptionKind, strike: number, spot: number): number {
  return kind === 'call' ? spot - strike : strike - spot
}

/**
 * Every leg's delta and gamma contribution. Legs whose ticker has no published
 * greek are dropped and reported separately — guessing one would quietly corrupt
 * Δp, and the engine refuses to act on a partial book rather than mis-size a roll.
 *
 * Gamma is required on the same terms as delta, not opportunistically: with a
 * gamma multiplier set it decides the band itself, so a leg silently missing from
 * Γp would widen or narrow the band by that leg's whole share and the breach test
 * would be answering a different question than the trader asked.
 *
 * `requireGamma` is what a futures-hedged book turns off. Gamma is only ever read
 * to derive the band, and that book does not derive it — so a leg whose gamma the
 * venue has not published is no reason to stop measuring Δp and stop hedging. With
 * it false, such a leg counts at gamma 0 and is reported in `gammaMissing`, so Γp
 * is known to be unreliable and simply is not used
 * ([`0045`](../../supabase/migrations/0045_futures_band_without_gamma.sql)).
 *
 * The perpetual is the one leg whose greeks are not read from the feed, because
 * the venue publishes none for it — `"greeks": null` on the ticker. It does not
 * need them: a linear contract has delta 1 per lot and gamma 0 by definition, and
 * those are constants rather than quotes. Mirrors the chain row
 * [`0044`](../../supabase/migrations/0044_futures_delta_hedge.sql) writes for it,
 * so the readout and the engine measure the same book.
 *
 * The consequence worth stating: a futures hedge is *inside* Δp. So the gap
 * between Δp and the target is always the size the hedge still needs, and a hedge
 * that has grown too big for the option deltas it was answering shows up as a
 * breach on the other edge — one that the same rule sells back down.
 */
export function bookDeltas(
  positions: PositionRow[],
  tickerFor: (symbol: string) => Ticker | undefined,
  spot: number,
  /** False on a futures-hedged book, which never derives a band from Γp. */
  requireGamma = true,
): { legs: LegDelta[]; missing: PositionRow[]; gammaMissing: PositionRow[] } {
  const legs: LegDelta[] = []
  const missing: PositionRow[] = []
  const gammaMissing: PositionRow[] = []

  for (const pos of positions) {
    if (pos.net_qty === 0) continue
    const kind = legKind(pos)
    const perp = kind === 'perp'
    const ticker = tickerFor(pos.symbol)
    const optionDelta = perp ? 1 : tickerDelta(ticker)
    const rawGamma = perp ? 0 : tickerGamma(ticker)
    if (rawGamma === null) gammaMissing.push(pos)
    if (optionDelta === null || (requireGamma && rawGamma === null)) {
      missing.push(pos)
      continue
    }
    const optionGamma = rawGamma ?? 0
    const strike = perp ? NaN : Number(pos.strike_price)
    legs.push({
      position: pos,
      kind,
      strike,
      optionDelta,
      contribution: pos.net_qty * optionDelta,
      optionGamma,
      gammaContribution: pos.net_qty * optionGamma,
      itmDistance:
        kind === 'perp' ? Number.NEGATIVE_INFINITY : itmDistanceOf(kind, strike, spot),
    })
  }

  return { legs, missing, gammaMissing }
}

export function portfolioDelta(legs: LegDelta[]): number {
  return legs.reduce((sum, l) => sum + l.contribution, 0)
}

/**
 * The book's net gamma, in the same lot units `portfolioDelta` returns — scale it
 * by the contract value to read it in the trader's own unit, exactly as Δp is.
 *
 * Negative on a short book, which is the normal case here: this strategy only
 * ever sells. The band derived from it uses the magnitude.
 */
export function portfolioGamma(legs: LegDelta[]): number {
  return legs.reduce((sum, l) => sum + l.gammaContribution, 0)
}

/** `95000` -> `$95,000`, for the one reason line that names the cap. */
const usd0 = (v: number) => `$${Math.round(v).toLocaleString('en-US')}`

/** `12.5` -> `$12.50`. Premiums are small enough that the cents matter. */
const usd2 = (v: number) => `$${v.toFixed(2)}`

export type Breach = 'low' | 'high' | null

/** The band actually in force this cycle, and whether gamma is what set it. */
export interface Band {
  low: number
  high: number
  /** True when `gammaMultiplier` derived it, false when it is the typed-in pair. */
  derived: boolean
  /**
   * The band is meant to be derived and Γp is not known *yet* — legs are held but
   * their greeks have not arrived. `low`/`high` carry the fallback, because that
   * is what the rule gives for an unknown Γp, but they are about to change and a
   * reader should not be shown them as though they were settled.
   *
   * Distinct from a plain `derived: false`, which is a *settled* answer: a flat
   * book, or gamma rounded away, where the typed pair really is the band and will
   * stay it. Only `planCycle` can tell the two apart, since it is the only thing
   * that knows whether there are positions whose greeks are still outstanding.
   *
   * Nothing acts in this window regardless — Δp is null for the same reason, and
   * every branch that reads the band is behind a non-null Δp.
   */
  pending: boolean
}

/**
 * The band the breach test is run against.
 *
 * With `gammaMultiplier` at zero the stored `bandLow`/`bandHigh` are the band,
 * which is how every account behaves until the number is moved. Set it and the
 * band becomes symmetric around zero, half-width `|Γp| × multiplier`:
 *
 *     Γp = 0.5, multiplier = 2   ->   [-1, +1]
 *     Γp = 0.8, multiplier = 2   ->   [-1.6, +1.6]
 *
 * So the band widens exactly as the book's gamma grows. The reasoning is that
 * gamma is the rate Δp itself moves at: a book with twice the gamma runs through
 * the same delta in half the move, and holding it to the same fixed band means
 * correcting twice as often for the same underlying behaviour. Tying the two puts
 * the tolerance in units of "how fast is this book going to breach" rather than
 * in absolute delta.
 *
 * `Γp` is taken as a magnitude. A short book's gamma is negative and a signed
 * band would come out inverted, with `low` above `high` — the sign says which way
 * the book is convex, which is not what the width is asking.
 *
 * Zero falls back to the stored band, which covers the two cases where a derived
 * band would be nonsense: a flat book, and a book whose legs are far enough out
 * that gamma has rounded away. Either would give a band of `[0, 0]` that every
 * non-zero Δp breaches, and the engine would correct on a book it cannot measure.
 */
export function effectiveBand(
  cfg: Pick<DeltaConfig, 'bandLow' | 'bandHigh' | 'gammaMultiplier'>,
  /** Γp in the same unit the band is set in, or null when the book cannot be valued. */
  gp: number | null,
): Band {
  const stored = { low: cfg.bandLow, high: cfg.bandHigh, derived: false, pending: false }
  if (!(cfg.gammaMultiplier > 0) || gp === null) return stored
  const width = Math.abs(gp) * cfg.gammaMultiplier
  if (!(width > 0)) return stored
  return { low: -width, high: width, derived: true, pending: false }
}

export function bandBreach(dp: number, band: Band): Breach {
  if (dp < band.low) return 'low'
  if (dp > band.high) return 'high'
  return null
}

/**
 * The Δp every correction aims for. `edge` is the breached boundary itself,
 * `buffer` pulls that inward by B, `mid` is the middle of the band. Clamped so a
 * buffer wider than the band cannot land the target on the far side.
 *
 * Reads the band it is given rather than the config, so a gamma-derived band
 * lands its corrections on its own edges — a target computed off the typed-in
 * pair while the breach was judged against a derived one could sit outside the
 * band that is actually in force.
 */
export function landingTarget(
  cfg: Pick<DeltaConfig, 'targetLanding' | 'bandBuffer'>,
  band: Band,
  breach: Exclude<Breach, null>,
): number {
  const mid = (band.low + band.high) / 2
  if (cfg.targetLanding === 'mid') return mid
  const edge = breach === 'low' ? band.low : band.high
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

/**
 * Perpetual lots to trade to land Δp on its target, **signed**: positive buys,
 * negative sells.
 *
 *     lots = (target − Δp) ÷ contract_value
 *
 * No delta divisor, because a perpetual's delta is 1: one lot of it carries one
 * lot of the underlying, so the only conversion is out of the band's own qty
 * units and into venue lots. And no side to choose — the same instrument adds
 * delta when bought and removes it when sold, which is the whole reason this
 * replaces two option rules with one trade.
 *
 * Rounded down in magnitude like every other size here, so a hedge cannot
 * overshoot the landing point: a breach worth less than one lot sizes to zero and
 * is left alone. Mirrors the futures branch of `apply_delta_strategy` in
 * [`0044`](../../supabase/migrations/0044_futures_delta_hedge.sql).
 */
export function hedgeLots(target: number, dp: number, contractValue: number): number {
  if (!(contractValue > 0)) return 0
  const need = (target - dp) / contractValue
  const lots = floorContracts(Math.abs(need))
  return need < 0 ? -lots : lots
}

// ---------------------------------------------------------------------------
// The margin guard
// ---------------------------------------------------------------------------

/**
 * Where an account sits against its two margin thresholds.
 *
 * `cut` is the only state that stops anything: blocked margin has passed the cap,
 * so the only thing the engine may do is close legs. Below the cap every rule
 * runs — entries, rolls and band corrections alike.
 *
 * There used to be a third state between the target and the cap, in which the
 * book was frozen against new premium while rolls carried on. It is gone. The
 * zone left Δp outside its band with no rule able to act on it, which for a
 * strategy whose entire job is holding Δp inside a band is the one failure that
 * cannot be traded through. Delta is now managed at every margin level up to the
 * cap, and the cap is where risk is answered.
 *
 * The hysteresis that zone was also providing is not lost: a cut works the book
 * down to `goal`, so there is `cap - goal` of headroom before the next one. That
 * gap is what stops the cut and the correction trading against each other every
 * cycle, and it is the reason `marginTargetPct` still exists.
 *
 * `cut` reads false when `marginCapPct` is zero, which is how the guard is turned
 * off entirely. Negative equity lands in `cut` on its own arithmetic — every
 * threshold is then at or below zero, so any open short is over it.
 */
export interface MarginState {
  cut: boolean
  /** Blocked margin the cut triggers at. */
  cap: number
  /** Blocked margin a cut works down to. Not a gate — only a depth. */
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

/**
 * Every short **option** in the book, as cut candidates.
 *
 * Two exclusions, for two different reasons. Longs: their margin is the premium
 * already paid, so closing one frees nothing. The perpetual hedge: closing it
 * would take off the one position that is *reducing* the book's directional
 * risk, and it has no strike for the most-in-the-money ordering to read. The cut
 * takes lots off the option shorts instead, and the rebalance re-sizes the hedge
 * against whatever Δp the cut left behind.
 */
export function cutCandidates(positions: PositionRow[], spot: number): CutCandidate[] {
  const out: CutCandidate[] = []
  for (const pos of positions) {
    if (pos.net_qty >= 0) continue
    const kind = legKind(pos)
    if (kind === 'perp') continue
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
/**
 * Which side a cut should take lots off, given where Δp sits.
 *
 * Measured against the band's **midpoint**, not against whether Δp has breached.
 * That distinction is the whole of this function, and the reason it exists:
 * `bandBreach` is null while Δp is inside the band, and a cut that reads it got
 * no preference at all and fell through to "deepest in the money" — which on a
 * short strangle is whichever leg spot has drifted nearest, with no regard for
 * what closing it does to Δp.
 *
 * That is not a cosmetic gap. Closing a short put removes positive delta, so a
 * cut taken on the put side with Δp already below the midpoint drives Δp *out*
 * of the band — and the band correction then answers by re-selling the very
 * strike the cut just bought back. The two rules trade against each other every
 * cycle, each paying the spread, until someone notices.
 *
 * Below the midpoint, closing a call raises Δp; above it, closing a put lowers
 * Δp. Either way the cut moves Δp toward the middle of the band while it frees
 * the margin, so the two goals are served by one action instead of fighting.
 *
 * On a genuine breach this returns exactly what `correctiveRollSide(breach)` did,
 * so nothing changes on the path that was already working.
 */
export function cutPreferredSide(dp: number | null, band: Band): OptionKind | null {
  if (dp === null) return null
  const mid = (band.low + band.high) / 2
  if (dp === mid) return null
  return dp < mid ? 'call' : 'put'
}

export function pickCutLeg(
  candidates: CutCandidate[],
  /** From `cutPreferredSide`. Null only when Δp is unknown or exactly at the mid. */
  preferred: OptionKind | null,
): CutCandidate | null {
  if (candidates.length === 0) return null
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
  /** Lots this contract can still take under the notional cap; null when off. */
  roomLots: number | null
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
/**
 * How many more lots a contract can take before it hits the notional cap, or
 * null when there is no cap to apply.
 *
 *     room = floor(cap / (spot × contract_value)) − |lots already held|
 *
 * Null rather than Infinity so callers can pass it straight to `Math.min` with a
 * `?? q` fallback, and so the SQL mirror — where `least` ignores nulls — reads
 * the same way.
 */
export function strikeRoomLots(
  cfg: Pick<DeltaConfig, 'maxNotionalPerStrike'>,
  heldLots: number,
  contractValue: number,
  spot: number,
): number | null {
  const cap = cfg.maxNotionalPerStrike
  if (!(cap > 0) || !(spot > 0) || !(contractValue > 0)) return null
  return Math.max(0, Math.floor(cap / (spot * contractValue)) - Math.abs(heldLots))
}

export function pickByPremium(
  expiry: Expiry,
  kind: OptionKind,
  cfg: Pick<DeltaConfig, 'entryPremium' | 'tieBreak'>,
  tickerFor: (symbol: string) => Ticker | undefined,
  beyond?: number,
  /** Lots a contract can still take; null means uncapped. Omit for no cap. */
  roomFor?: (product: Product) => number | null,
  targetPremium?: number,
): StrikePick | null {
  const target = targetPremium ?? cfg.entryPremium
  const candidates: StrikePick[] = []

  for (const [strike, product] of book(expiry, kind)) {
    if (beyond !== undefined && !furtherOtm(strike, beyond, kind)) continue
    const ticker = tickerFor(product.symbol)
    const premium = salePremium(ticker)
    const optionDelta = tickerDelta(ticker)
    if (premium === null || optionDelta === null) continue
    // A strike with no room left is not a candidate at all. That is the whole
    // mechanism: dropping it here is what makes the rules below land on the
    // next-nearest premium without any of them knowing a cap exists.
    const roomLots = roomFor ? roomFor(product) : null
    if (roomLots !== null && roomLots <= 0) continue
    candidates.push({ product, strike, premium, optionDelta, roomLots })
  }

  if (candidates.length === 0) return null

  const closest = () =>
    candidates.reduce((best, c) =>
      Math.abs(c.premium - target) < Math.abs(best.premium - target) ? c : best,
    )

  if (cfg.tieBreak === 'above') {
    const above = candidates.filter((c) => c.premium >= target)
    // Nearest from above: the cheapest of those still at or over the target.
    return above.length ? above.reduce((b, c) => (c.premium < b.premium ? c : b)) : closest()
  }
  if (cfg.tieBreak === 'below') {
    const below = candidates.filter((c) => c.premium <= target)
    return below.length ? below.reduce((b, c) => (c.premium > b.premium ? c : b)) : closest()
  }
  return closest()
}

/**
 * Pick multiple strikes for an entry pair, respecting premium bounds [entryPremiumMin, entryPremiumMax]
 * and sorted according to the entry premium and tie-break rule.
 */
export function pickMultipleByPremium(
  expiry: Expiry,
  kind: OptionKind,
  cfg: Pick<DeltaConfig, 'entryPremium' | 'tieBreak' | 'entryPremiumMin' | 'entryPremiumMax'>,
  tickerFor: (symbol: string) => Ticker | undefined,
  count: number,
  roomFor?: (product: Product) => number | null,
): StrikePick[] {
  if (count <= 0) return []
  const allCandidates: StrikePick[] = []

  for (const [strike, product] of book(expiry, kind)) {
    const ticker = tickerFor(product.symbol)
    const premium = salePremium(ticker)
    const optionDelta = tickerDelta(ticker)
    if (premium === null || optionDelta === null) continue
    const roomLots = roomFor ? roomFor(product) : null
    if (roomLots !== null && roomLots <= 0) continue
    allCandidates.push({ product, strike, premium, optionDelta, roomLots })
  }

  if (allCandidates.length === 0) return []

  // The two bounds are not symmetric, and the asymmetry is deliberate.
  //
  //   min  a hard floor. A strike quoted below it is dropped, and if that empties
  //        the side there is no entry — no fallback to the unfiltered list, which
  //        would have the readout promise an entry the engine declines.
  //   max  approximate. It does not exclude a richer strike; it only supplies the
  //        target to rank against when entryPremium is unset. So a range of 3–5
  //        can and will open a leg at 7.30 if that is the nearest to the target.
  //
  // `delta_pick_premium_ranked` reads them exactly this way — floor_val and
  // target_val, no ceiling test — so the two stay in step. Change one and the
  // readout starts describing an entry the engine does not make.
  const rawMin = cfg.entryPremiumMin ?? 0
  const rawMax = cfg.entryPremiumMax ?? 0
  const hasMin = rawMin > 0
  const hasMax = rawMax > 0
  const minFloor = hasMin && hasMax ? Math.min(rawMin, rawMax) : hasMin ? rawMin : 0
  const target = cfg.entryPremium > 0 ? cfg.entryPremium : (hasMin && hasMax ? Math.max(rawMin, rawMax) : 0)

  // Hard floor: strictly at or above the min premium (e.g. >= $2)
  const eligible = minFloor > 0 ? allCandidates.filter((c) => c.premium >= minFloor) : allCandidates
  if (eligible.length === 0) return []

  const sorted = [...eligible].sort((a, b) => {
    if (cfg.tieBreak === 'above') {
      const aAbove = a.premium >= target
      const bAbove = b.premium >= target
      if (aAbove && !bAbove) return -1
      if (!aAbove && bAbove) return 1
      if (aAbove && bAbove) return a.premium - b.premium
    } else if (cfg.tieBreak === 'below') {
      const aBelow = a.premium <= target
      const bBelow = b.premium <= target
      if (aBelow && !bBelow) return -1
      if (!aBelow && bBelow) return 1
      if (aBelow && bBelow) return b.premium - a.premium
    }
    return Math.abs(a.premium - target) - Math.abs(b.premium - target)
  })

  return sorted.slice(0, count)
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
   * The whole of a futures-hedged book's delta management: one trade in the
   * perpetual, `lots` of it, bought or sold. It replaces `roll` and `band`
   * rather than joining them — a book that hedges with futures never touches an
   * option to move Δp.
   */
  | { type: 'hedge'; side: Side; lots: number }
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
  /**
   * How this book corrects Δp — options or futures. Defaults to `options`, which
   * is the delta account's rule and the one the rules document describes.
   */
  mode?: HedgeMode
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
  /** Γp in the band's own unit, on the same terms as `dp`. Always null on a
   *  futures-hedged book, which has no use for it. */
  gp: number | null
  /** The band this pass judged `dp` against — derived from Γp, or the stored pair. */
  band: Band
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
 * Priority is the spec's: flatten at the close, cut over the margin cap, enter at
 * the open, then answer a breach. Returning one action at a time rather than a
 * batch is deliberate — Δp is recomputed off fresh marks before each step, so a
 * correction can never be sized against a book it has already changed.
 *
 * How a breach is answered is the one thing `mode` changes. An options-hedged
 * book rebuilds the ITM queue and resolves it, and only when that queue is
 * exhausted corrects the band with fresh OTM sells. A futures-hedged book trades
 * the perpetual instead — one order, either direction, and neither the queue nor
 * the roll budget is consulted. Every other rule above is shared verbatim.
 */
export function planCycle(input: CycleInput): CyclePlan {
  const { now, cfg: rawCfg, session, positions, expiry, spot, tickerFor, touched } = input
  const mode = input.mode ?? 'options'
  const rawSession = sessionPhase(now, rawCfg)

  let cfg = rawCfg
  let phase = rawSession.phase
  let day = rawSession.day
  let tradingDay = rawSession.tradingDay

  if (mode === 'futures' && rawCfg.scheduleWindows && rawCfg.scheduleWindows.length > 0) {
    const { activeWindow, phase: winPhase, sessionDay: winDay } = findActiveScheduleWindow(
      rawCfg.scheduleWindows,
      now,
      rawCfg.tradeDays,
    )
    phase = winPhase
    day = winDay
    const istDate = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Kolkata' }))
    const istDay = istDate.getDay()
    tradingDay = rawCfg.tradeDays.includes(istDay === 0 ? 7 : istDay)

    if (activeWindow) {
      cfg = {
        ...rawCfg,
        sessionOpen: activeWindow.startTime,
        sessionClose: activeWindow.endTime,
        entryPremium: activeWindow.entryPremium,
        entryPremiumMin: activeWindow.entryPremiumMin,
        entryPremiumMax: activeWindow.entryPremiumMax,
        pairsCount: activeWindow.pairsCount,
        qty: activeWindow.qty,
        maxNotionalPerStrike: activeWindow.maxNotionalPerStrike,
        tieBreak: activeWindow.tieBreak,
        bandLow: activeWindow.bandLow,
        bandHigh: activeWindow.bandHigh,
        targetLanding: activeWindow.targetLanding,
        bandBuffer: activeWindow.bandBuffer,
        hedgeLeverage: activeWindow.hedgeLeverage,
        shiftPct: activeWindow.shiftPct,
        maxShifts: activeWindow.maxShifts,
        takeProfitMark: activeWindow.takeProfitMark,
        stopLossMark: activeWindow.stopLossMark,
        marginCapPct: activeWindow.marginCapPct,
        marginTargetPct: activeWindow.marginTargetPct,
      }
    }
  }

  // Gamma is read for one purpose only — deriving the band — and a futures-hedged
  // book does not derive it. So that book neither computes Γp nor waits for one:
  // a leg the venue has published no gamma for still counts toward Δp and is
  // still hedged, where an options-hedged book stands the whole cycle down for it
  // ([`0045`](../../supabase/migrations/0045_futures_band_without_gamma.sql)).
  const usesGamma = mode === 'options'
  const live = positions.filter((p) => p.net_qty !== 0)
  const { legs, missing } = bookDeltas(live, tickerFor, spot, usesGamma)
  // Δp in qty (underlying) units, the same unit the band is set in: net_qty counts
  // venue lots, so each leg's lot-sized delta is scaled by the contract value to
  // read as the book's own delta. `dpLots` keeps the unscaled sum, because sizing a
  // correction still counts in lots — see the roll and band-correction steps below.
  const cv = bookContractValue(legs, expiry)
  const dpLots = missing.length === 0 ? portfolioDelta(legs) : null
  const dp = dpLots === null ? null : dpLots * cv
  // Γp in the band's unit, scaled the same way Δp is — the multiplier is applied
  // to a figure in the unit the band is read in, or the two would not compare.
  const gp = usesGamma && missing.length === 0 ? portfolioGamma(legs) * cv : null
  // `pending` separates "Γp is not in yet" from "there is no Γp". Both hand back
  // the stored pair, but only the second is an answer: the first is a band about
  // to be replaced the moment the greeks land, and printing it as settled is what
  // makes the bar appear to show a wrong band for a second after a reload.
  // The stored pair is the band outright on a futures book — `gammaMultiplier` is
  // an options-only control there, and forcing it to zero here is what makes that
  // true of the readout as well as of the engine. Nothing is ever `pending`
  // either: there is no derivation to wait on.
  const band: Band = {
    ...effectiveBand(usesGamma ? cfg : { ...cfg, gammaMultiplier: 0 }, gp),
    pending: usesGamma && cfg.gammaMultiplier > 0 && gp === null && live.length > 0,
  }
  const queue = itmQueue(legs, cfg)
  // Lots already short per contract, for the notional cap. Off `live` rather than
  // `legs`: a leg whose greek has not arrived still occupies room at its strike.
  const heldLots = new Map<string, number>()
  for (const pos of live) heldLots.set(pos.symbol, Math.abs(pos.net_qty))
  const roomFor = (product: Product) =>
    strikeRoomLots(cfg, heldLots.get(product.symbol) ?? 0, Number(product.contract_value), spot)
  const margin =
    input.marginBlocked === undefined || input.equity === undefined
      ? null
      : marginState(cfg, input.marginBlocked, input.equity)
  const base = { dp, gp, band, breach: null as Breach, phase, day, tradingDay, queue, margin }

  // ---- Session close: flatten, whatever the band says ----------------------
  if (phase !== 'open') {
    if (live.length > 0 && session.flattenedDay !== day) {
      return {
        ...base,
        action: { type: 'flatten', positions: live },
        reason: tradingDay ? 'Schedule window closed — flattening' : 'Not a trading day — flattening',
      }
    }
    return {
      ...base,
      action: null,
      reason: !tradingDay
        ? 'Not a trading day — flat'
        : phase === 'before'
          ? 'Before schedule window open'
          : 'Schedule window closed — flat',
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
    const leg = pickCutLeg(cutCandidates(live, spot), cutPreferredSide(dp, band))
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
    // No margin gate here. The entry only runs on a book that has just been
    // flattened at the previous close, so blocked margin is at or near zero when
    // it fires; a gate on it was guarding a state the session clock already makes
    // unreachable. Above the cap the cut branch has returned long before this.
    const pairsCount = mode === 'futures' && (cfg.pairsCount ?? 1) > 0 ? (cfg.pairsCount ?? 1) : 1
    const calls = pickMultipleByPremium(expiry, 'call', cfg, tickerFor, pairsCount, roomFor)
    const puts = pickMultipleByPremium(expiry, 'put', cfg, tickerFor, pairsCount, roomFor)
    if (calls.length === 0 || puts.length === 0) {
      // Which side came back empty, and whether a setting on this panel is what
      // emptied it. "No call strike quoted yet" reads as a venue problem and
      // sends you looking at the chain; a floor nothing clears is a number on
      // this very panel, and the engine will decline the entry until it moves.
      //
      // Only the floor is named, because only the floor can empty the list. The
      // upper bound is approximate — it steers the target, it does not exclude a
      // richer strike — so printing it here would blame a control that did not
      // do this. Both bounds set means the lower of the two is the floor.
      const side = calls.length === 0 ? 'call' : 'put'
      const rawMin = cfg.entryPremiumMin ?? 0
      const rawMax = cfg.entryPremiumMax ?? 0
      const hasMin = rawMin > 0
      const hasMax = rawMax > 0
      const floorVal = hasMin && hasMax ? Math.min(rawMin, rawMax) : hasMin ? rawMin : 0
      return {
        ...base,
        action: null,
        reason:
          floorVal > 0
            ? `No ${side} strike quoted at or above ${usd2(floorVal)}`
            : `No ${side} strike quoted yet`,
      }
    }
    const count = Math.min(calls.length, puts.length)
    const legsToEnter: { product: Product; qty: number }[] = []

    for (let i = 0; i < count; i++) {
      const c = calls[i]
      const p = puts[i]
      const room = Math.min(c.roomLots ?? Infinity, p.roomLots ?? Infinity)
      const callLots = Math.min(entryLots(c.product, cfg), room)
      const putLots = Math.min(entryLots(p.product, cfg), room)
      if (callLots > 0 && putLots > 0) {
        legsToEnter.push({ product: c.product, qty: callLots })
        legsToEnter.push({ product: p.product, qty: putLots })
      }
    }

    if (legsToEnter.length === 0) {
      return {
        ...base,
        action: null,
        reason: `No strike under the ${usd0(cfg.maxNotionalPerStrike)} cap has room for an entry`,
      }
    }

    const desc =
      count === 1
        ? `Selling ${legsToEnter[0].qty} × ${calls[0].strike}C / ${legsToEnter[1].qty} × ${puts[0].strike}P`
        : `Selling ${count} pairs (${legsToEnter.map((l) => `${l.qty} × ${l.product.symbol}`).join(', ')})`

    return {
      ...base,
      action: {
        type: 'entry',
        legs: legsToEnter,
      },
      reason: desc,
    }
  }

  // ---- Empty side check (Futures strategy) ---------------------------------
  // If there is no position on either side (Call or Put), close all remaining positions.
  if (mode === 'futures' && session.enteredDay === day && live.length > 0) {
    const callShorts = live.filter((p) => p.contract_type === 'call_options' && p.net_qty < 0)
    const putShorts = live.filter((p) => p.contract_type === 'put_options' && p.net_qty < 0)
    if (callShorts.length === 0 || putShorts.length === 0) {
      return {
        ...base,
        action: { type: 'flatten', positions: live },
        reason: `No ${callShorts.length === 0 ? 'call' : 'put'} positions remaining — closing all positions`,
      }
    }
  }

  // ---- ATM Exit & Shift (Futures strategy) ---------------------------------
  // Exit at ATM (spot >= strike for Call, spot <= strike for Put).
  // At the exit price, sell another position on the same side at shiftPct (default 50%).
  // Limit maxShifts (default 1) per side.
  if (mode === 'futures') {
    const atmLeg = legs.find(
      (leg) =>
        leg.kind !== 'perp' &&
        leg.position.net_qty < 0 &&
        leg.itmDistance >= 0 &&
        !touched.has(leg.position.symbol),
    )
    if (atmLeg) {
      const open = Math.abs(atmLeg.position.net_qty)
      const ticker = tickerFor(atmLeg.position.symbol)
      const pExit = Number(
        ticker?.quotes?.best_ask ??
          ticker?.mark_price ??
          ticker?.quotes?.best_bid ??
          atmLeg.position.avg_entry_price ??
          0,
      )
      const used =
        atmLeg.kind === 'call' ? (session.shiftsUsedCall ?? 0) : (session.shiftsUsedPut ?? 0)
      const maxShifts = cfg.maxShifts ?? 1
      const shiftAllowed = used < maxShifts

      if (shiftAllowed && expiry) {
        const shiftPct = cfg.shiftPct > 0 ? cfg.shiftPct : 50
        const targetShiftPrice = pExit * (shiftPct / 100)
        const replacement = pickByPremium(
          expiry,
          atmLeg.kind as OptionKind,
          cfg,
          tickerFor,
          atmLeg.strike,
          roomFor,
          targetShiftPrice,
        )
        if (replacement) {
          const q = Math.min(open, replacement.roomLots ?? Infinity)
          if (q > 0) {
            return {
              ...base,
              action: {
                type: 'roll',
                side: atmLeg.kind as OptionKind,
                leg: atmLeg,
                exitQty: q,
                replace: { product: replacement.product, qty: q },
              },
              reason: `ATM reached on ${atmLeg.strike}${atmLeg.kind === 'call' ? 'C' : 'P'} (exit $${pExit.toFixed(2)}) — shifted to ${replacement.strike} at ${shiftPct}% ($${targetShiftPrice.toFixed(2)})`,
            }
          }
        }
      }

      return {
        ...base,
        action: {
          type: 'roll',
          side: atmLeg.kind as OptionKind,
          leg: atmLeg,
          exitQty: open,
          replace: null,
        },
        reason: shiftAllowed
          ? `ATM reached on ${atmLeg.strike}${atmLeg.kind === 'call' ? 'C' : 'P'} — exiting at $${pExit.toFixed(2)}`
          : `ATM reached on ${atmLeg.strike}${atmLeg.kind === 'call' ? 'C' : 'P'} — shift limit (${maxShifts}) reached, closing in full`,
      }
    }
  }

  // ---- Rebalance -----------------------------------------------------------
  if (dp === null) {
    return {
      ...base,
      action: null,
      reason: `Waiting on ${usesGamma ? 'greeks' : 'a delta'} for ${missing.length} leg(s)`,
    }
  }

  const breach = bandBreach(dp, band)
  if (!breach) {
    return { ...base, breach, action: null, reason: `Δp ${fmt(dp)} — inside the band` }
  }

  // Sizing counts in lots, so it works from the unscaled Δp and a target scaled
  // back the same way — `target` is a band figure, in qty units, so `target / cv`
  // brings it into the lot space `dpLots` lives in.
  const dpl = dpLots as number
  const target = landingTarget(cfg, band, breach)
  const targetLots = target / cv

  // ---- The breach, answered with futures -----------------------------------
  if (mode === 'futures') {
    const lots = hedgeLots(target, dp, cv)
    if (lots === 0) {
      return { ...base, breach, action: null, reason: `Δp ${fmt(dp)} — breach is under one contract` }
    }
    const side: Side = lots > 0 ? 'buy' : 'sell'
    return {
      ...base,
      breach,
      action: { type: 'hedge', side, lots: Math.abs(lots) },
      reason: `Δp ${fmt(dp)} → ${fmt(target)} — ${side === 'buy' ? 'buying' : 'selling'} ${Math.abs(lots)} futures lot${Math.abs(lots) === 1 ? '' : 's'}`,
    }
  }

  const sellSide = correctiveSellSide(breach)
  const rollSide = correctiveRollSide(breach)

  // Options mode Step 1: Check if margin is available to sell a fresh position on corrective side
  const pick = pickByPremium(expiry, sellSide, cfg, tickerFor, undefined, roomFor)

  const marginRoomLots = (() => {
    if (!margin || !(cfg.marginCapPct > 0)) return null
    if (!pick) return 0
    const imRate = input.imRateFor?.(pick.product.symbol) ?? FALLBACK_SHORT_IM_RATE
    const perLot = (imRate * spot + pick.premium) * Number(pick.product.contract_value)
    if (!(perLot > 0)) return null
    return Math.max(0, Math.floor((margin.cap - margin.marginBlocked) / perLot))
  })()

  const hasMargin = marginRoomLots === null || marginRoomLots > 0

  if (hasMargin && pick) {
    const q = Math.min(
      bandQty(targetLots, dpl, pick.optionDelta),
      pick.roomLots ?? Infinity,
      marginRoomLots ?? Infinity,
    )
    if (q > 0) {
      return {
        ...base,
        breach,
        action: { type: 'band', side: sellSide, product: pick.product, qty: q },
        reason: `Δp ${fmt(dp)} → ${fmt(target)} — selling ${q} × ${pick.strike}${sellSide === 'call' ? 'C' : 'P'}`,
      }
    }
  }

  // Options mode Step 2: No margin available — exit the open position causing delta to breach and book loss
  const offendingLeg = legs
    .filter((l) => l.kind === rollSide && l.position.net_qty < 0 && !touched.has(l.position.symbol))
    .sort((a, b) => b.itmDistance - a.itmDistance)[0]

  if (offendingLeg) {
    const open = Math.abs(offendingLeg.position.net_qty)
    const legDelta = Math.abs(offendingLeg.optionDelta || 0.5)
    const cutQ = Math.max(1, Math.min(open, Math.ceil(Math.abs(target - dp) / (cv * legDelta))))

    return {
      ...base,
      breach,
      action: { type: 'roll', side: rollSide, leg: offendingLeg, exitQty: cutQ, replace: null },
      reason: `Δp ${fmt(dp)} out of range (no margin) — exiting ${cutQ} × ${offendingLeg.strike}${rollSide === 'call' ? 'C' : 'P'} (booked loss)`,
    }
  }

  return {
    ...base,
    breach,
    action: null,
    reason: `Δp ${fmt(dp)} outside the band — no position or room to correct with`,
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
