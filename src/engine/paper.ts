/**
 * Paper trading maths: pricing, fees, margin and P&L.
 *
 * Money conventions, all USD:
 *   premium per lot  = price * contract_value        (contract_value = 0.001 XAUT)
 *   notional per lot = spot  * contract_value
 *
 * So one lot of a 4040 call quoted at 24.05 costs 24.05 * 0.001 = $0.02405,
 * and carries $4.03 of underlying exposure. That is genuinely how Delta sizes
 * XAUT options — the small per-lot value is why quoted sizes run to five figures.
 */

import { isPerp, type Product, type Ticker } from '../lib/delta'

/**
 * Fallback initial-margin rate for a short option, used only when the contract
 * itself is not to hand — an expired position whose product no longer loads.
 *
 * Prefer `shortImRate(product)`. Delta publishes the rate per contract and we
 * had been ignoring it in favour of a hardcoded 10%, which was ten times what
 * they ask for an XAUT option. 1% is what they publish for those, so it is the
 * least surprising thing to fall back to.
 */
export const FALLBACK_SHORT_IM_RATE = 0.01

/**
 * The venue's own initial-margin rate for a contract, as a fraction.
 *
 * `initial_margin` is a percentage: BTCUSD reads '0.5' at a default leverage of
 * 200, and 200x is 0.5% margin, which settles the unit. Delta also raises the
 * rate with order size via `initial_margin_scaling_factor`, which we do not
 * model — so a large short is margined slightly more cheaply here than there.
 */
export function shortImRate(product: Product): number {
  const pct = Number(product.initial_margin)
  return Number.isFinite(pct) && pct > 0 ? pct / 100 : FALLBACK_SHORT_IM_RATE
}

// A maintenance rate and a liquidation price used to live here, for the page that
// traded the perpetual by hand. Both are gone with it: no book in this app is
// liquidated now. The two that can hold a perpetual are option strangles carrying
// a hedge, and `apply_futures_maintenance` skips any account holding a leg with no
// perpetual mark — which every option leg is — so its liquidation branch cannot
// fire on either. What bounds them is the delta strategy's own margin guard: over
// the cap it closes option shorts, deepest in the money first. The server-side
// rate is still a constant in
// [`0038`](../../supabase/migrations/0038_futures.sql) if that ever changes.

/**
 * Highest leverage the contract may be opened at. Delta publishes it directly,
 * and it is also exactly the reciprocal of the initial-margin rate — 1% margin
 * is 100x — so the published figure is only ever a cross-check on the maths.
 * The rate wins if they ever disagree, since it is the number margin is actually
 * computed from.
 */
export function maxLeverage(product: Product): number {
  const rate = shortImRate(product)
  const published = Number(product.default_leverage)
  const implied = 1 / rate
  return Number.isFinite(published) && published > 0 ? Math.min(published, implied) : implied
}

/**
 * Margin for one lot-block of a perpetual: notional over leverage, floored at
 * the venue's initial-margin rate. Both directions pay it — that is the whole
 * difference from an option, where a long's risk is capped at the premium it
 * already paid and the venue asks for nothing further.
 */
export function perpMargin(price: number, cv: number, lots: number, imRate: number, leverage: number | null): number {
  const notional = price * cv * lots
  const capped = leverage && leverage > 0 ? Math.min(leverage, 1 / imRate) : 1 / imRate
  return notional / capped
}

/**
 * One funding period's payment, signed in the account's favour: negative is paid
 * away, positive received. `ratePct` is the venue's own quote — a percentage for
 * the eight-hour period — and a positive one means longs pay shorts.
 *
 * Mirrors `apply_futures_maintenance` in
 * [`0038`](../../supabase/migrations/0038_futures.sql), which is what actually
 * moves the cash. This is here so the page can show the next payment before it
 * lands rather than only the ledger of ones that have.
 */
export function fundingPayment(mark: number, cv: number, netQty: number, ratePct: number): number {
  return -Math.sign(netQty) * (ratePct / 100) * mark * cv * Math.abs(netQty)
}

export type Side = 'buy' | 'sell'
export type OrderType = 'market' | 'limit'
/** Which price a bracket's levels watch: the underlying index or the option mark. */
export type TriggerSource = 'index' | 'mark'

export interface PositionRow {
  id: string
  account_id: string
  symbol: string
  product_id: number
  contract_type: string
  /** Null on a perpetual, which has no strike — see [`0038`](../../supabase/migrations/0038_futures.sql). */
  strike_price: string | null
  /** 'PERP' on a perpetual, which never expires. */
  expiry_label: string
  contract_value: string
  net_qty: number
  avg_entry_price: string
  realized_pnl: string
  /** The leverage a perpetual was opened at. Null on every option. */
  leverage?: string | null
  /** Exit levels, armed server-side. Null when unset. Watched against the
   *  index or the mark, per `tpsl_trigger`. */
  take_profit: string | null
  stop_loss: string | null
  tpsl_trigger: TriggerSource
  /**
   * Why the delta engine opened this leg — the rule, the spot and net delta
   * either side of it ([`0035`](../../supabase/migrations/0035_reason_on_the_row.sql)).
   * Null on a leg nobody's engine opened, and on anything predating the column.
   */
  entry_reason?: string | null
}

export interface OrderRow {
  id: string
  account_id: string
  symbol: string
  product_id: number
  contract_type: string
  strike_price: string | null
  expiry_label: string
  contract_value: string
  side: Side
  order_type: OrderType
  qty: number
  limit_price: string | null
  status: 'open' | 'filled' | 'cancelled'
  avg_fill_price: string | null
  filled_qty: number
  reduce_only: boolean
  created_at: string
}

// ---------------------------------------------------------------------------
// Quote access
// ---------------------------------------------------------------------------

const num = (v: string | number | null | undefined): number | null => {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

export const bestBid = (t: Ticker | undefined) => num(t?.quotes?.best_bid ?? null)
export const bestAsk = (t: Ticker | undefined) => num(t?.quotes?.best_ask ?? null)
export const markPrice = (t: Ticker | undefined) => num(t?.mark_price ?? null)

/**
 * The price you would actually transact at, right now, for a market order.
 * Buys lift the ask, sells hit the bid. Null when that side of the book is empty,
 * which is the signal to block the order rather than invent a price.
 */
export function marketFillPrice(t: Ticker | undefined, side: Side): number | null {
  return side === 'buy' ? bestAsk(t) : bestBid(t)
}

/**
 * The price used to value an open position — the price you would exit at.
 * A long exits by selling into the bid; a short exits by buying the ask.
 * This is the bid/ask-based marking asked for, and it is deliberately
 * pessimistic: opening a position and doing nothing shows the spread as a loss,
 * exactly as it does on a real book.
 */
export function exitPrice(t: Ticker | undefined, netQty: number): number | null {
  if (netQty === 0) return null
  return netQty > 0 ? bestBid(t) : bestAsk(t)
}

// ---------------------------------------------------------------------------
// Fees
// ---------------------------------------------------------------------------

/**
 * Delta's option fee: a rate on the underlying notional, capped at a
 * percentage of the premium. Both inputs come off the product itself
 * (0.01% of notional, capped at 3.5% of premium for XAUT) rather than
 * being hardcoded, so the numbers track the venue.
 */
export function computeFee(product: Product, price: number, qty: number, spot: number): number {
  const cv = Number(product.contract_value)
  const notionalRate = Number(product.taker_commission_rate) || 0

  // A perpetual has no premium, so there is no premium cap to take the lesser
  // of — the fee is the flat rate on the notional it traded at. Its own price is
  // the notional, which is why this reads `price` where the option arm reads
  // `spot`; on a perpetual the two are the same number to within the basis.
  if (isPerp(product.contract_type)) return notionalRate * price * cv * qty

  const premiumCapRate = product.product_specs?.premium_commission_rate ?? 0.1
  const onNotional = notionalRate * spot * cv * qty
  const cap = premiumCapRate * price * cv * qty
  return Math.min(onNotional, cap)
}

// ---------------------------------------------------------------------------
// Position valuation
// ---------------------------------------------------------------------------

export interface PositionValue {
  netQty: number
  /** Signed lots as displayed; positive long, negative short. */
  avgEntry: number
  /** Delta's fair mark price; the exit-side price if they have not published one. */
  mark: number | null
  /**
   * The price the position is valued at: the side of the book it would exit
   * into — bid for a long, ask for a short. Falls back to the mark only when
   * that side is empty, which is the one case the touch cannot answer.
   */
  exit: number | null
  /** price * cv * |qty| at entry — what the position cost (long) or collected (short). */
  entryValue: number
  /** Current exit value of the position. */
  currentValue: number | null
  unrealized: number | null
  /**
   * On an option, unrealized as a share of entry value. On a perpetual, as a
   * share of the margin it blocks — return on equity, which is what the venue
   * shows and the only one of the two that means anything at leverage: a 1% move
   * against 100x is the whole position, and reading it as "1%" would be a lie
   * the size of the account.
   */
  unrealizedPct: number | null
  marginBlocked: number
}

export function valuePosition(
  pos: PositionRow,
  ticker: Ticker | undefined,
  spot: number,
  /** The contract's own rate; falls back only when the product is not loaded. */
  imRate: number = FALLBACK_SHORT_IM_RATE,
): PositionValue {
  const cv = Number(pos.contract_value)
  const netQty = pos.net_qty
  const avgEntry = Number(pos.avg_entry_price)
  const lots = Math.abs(netQty)

  // Two prices, and they are not interchangeable.
  //
  // `mark` is Delta's fair value. It is what the venue margins against, so it is
  // what the margin figures below use and what the Mark Price column shows.
  //
  // `exit` is the side of the book the position would actually leave through — a
  // long sells into the bid, a short buys the ask — and it is what P&L is valued
  // at, because that is the money the position is worth right now. Marking at the
  // mid or the mark flatters a position by half the spread each way, which on an
  // illiquid strike is most of what the row shows; a book that pays the spread on
  // the way out should carry it on the screen too.
  //
  // Each falls back to the other when its own source is missing: an empty side of
  // the book leaves only the mark to go on, and vice versa.
  const mark = markPrice(ticker) ?? exitPrice(ticker, netQty)
  const exit = exitPrice(ticker, netQty) ?? mark
  const entryValue = avgEntry * cv * lots
  const currentValue = exit === null ? null : exit * cv * lots

  // Long: gain when the exit price is above entry. Short: gain when it is below.
  const unrealized =
    exit === null ? null : netQty > 0 ? (exit - avgEntry) * lots * cv : (avgEntry - exit) * lots * cv

  // A perpetual margins off its own notional, both ways round, at whatever
  // leverage it was opened at. An option keeps the two-sided rule it has always
  // had: a long has already paid its maximum loss, a short has not.
  const perp = isPerp(pos.contract_type)
  const marginBlocked = perp
    ? perpMargin(mark ?? avgEntry, cv, lots, imRate, Number(pos.leverage) || null)
    : netQty > 0
      ? entryValue // long option risk is capped at the premium paid
      : (imRate * spot + (mark ?? avgEntry)) * cv * lots

  const pctBase = perp ? marginBlocked : entryValue

  return {
    netQty,
    avgEntry,
    mark,
    exit,
    entryValue,
    currentValue,
    unrealized,
    unrealizedPct: pctBase > 0 && unrealized !== null ? (unrealized / pctBase) * 100 : null,
    marginBlocked,
  }
}

export interface AccountSummary {
  /** starting_balance + realized P&L - fees. Open positions are excluded. */
  balance: number
  /** balance - starting_balance: booked P&L, net of fees. */
  realized: number
  unrealized: number
  /** realized + unrealized: everything the account has made since it opened. */
  totalPnl: number
  /** balance + unrealized */
  equity: number
  marginBlocked: number
  /** equity - marginBlocked; what is left to open new risk with. */
  available: number
}

export function summarizeAccount(
  cashBalance: number,
  startingBalance: number,
  positions: PositionRow[],
  tickerFor: (symbol: string) => Ticker | undefined,
  spot: number,
  /** The contract's published margin rate, per symbol. Omit and every short
   *  falls back to the constant, which is only right for XAUT options. */
  imRateFor?: (symbol: string) => number | undefined,
): AccountSummary {
  let unrealized = 0
  let marginBlocked = 0
  for (const pos of positions) {
    const v = valuePosition(pos, tickerFor(pos.symbol), spot, imRateFor?.(pos.symbol))
    unrealized += v.unrealized ?? 0
    marginBlocked += v.marginBlocked
  }
  const equity = cashBalance + unrealized
  const realized = cashBalance - startingBalance
  return {
    balance: cashBalance,
    realized,
    unrealized,
    totalPnl: realized + unrealized,
    equity,
    marginBlocked,
    available: equity - marginBlocked,
  }
}

// ---------------------------------------------------------------------------
// Order validation and limit-order crossing
// ---------------------------------------------------------------------------

export interface OrderIntent {
  product: Product
  side: Side
  orderType: OrderType
  qty: number
  limitPrice: number | null
  /** Perpetuals only: the leverage to open at. Ignored on an option. */
  leverage?: number | null
}

export interface OrderPreview {
  /** Price the order would fill at now; null if it would rest (limit) or cannot fill. */
  fillPrice: number | null
  premium: number
  notional: number
  fee: number
  /** Margin this order would newly block. Zero when it only reduces exposure. */
  marginRequired: number
  /** Set when the order must be blocked. */
  error: string | null
  /** Set when the order is allowed but the user should know something. */
  warning: string | null
}

export function previewOrder(
  intent: OrderIntent,
  ticker: Ticker | undefined,
  spot: number,
  existing: PositionRow | undefined,
  available: number,
): OrderPreview {
  const { product, side, orderType, qty, limitPrice, leverage = null } = intent
  const cv = Number(product.contract_value)
  const tick = Number(product.tick_size)
  const perp = isPerp(product.contract_type)

  const empty: OrderPreview = {
    fillPrice: null,
    premium: 0,
    notional: 0,
    fee: 0,
    marginRequired: 0,
    error: null,
    warning: null,
  }

  if (!Number.isInteger(qty) || qty <= 0) return { ...empty, error: 'Quantity must be a whole number of lots' }

  const touch = marketFillPrice(ticker, side)

  let fillPrice: number | null
  if (orderType === 'market') {
    if (touch === null) {
      return { ...empty, error: `No ${side === 'buy' ? 'asks' : 'bids'} available — market order cannot fill` }
    }
    fillPrice = touch
  } else {
    if (limitPrice === null || !(limitPrice > 0)) return { ...empty, error: 'Enter a limit price' }
    // Reject prices the venue itself would reject.
    if (tick > 0 && Math.abs(limitPrice / tick - Math.round(limitPrice / tick)) > 1e-6) {
      return { ...empty, error: `Limit price must be a multiple of ${tick}` }
    }
    fillPrice = crossesNow(side, limitPrice, ticker)
  }

  // Value the order at its fill price, or at the resting limit price if it will wait.
  const valuationPrice = fillPrice ?? limitPrice ?? 0
  const premium = valuationPrice * cv * qty
  const notional = spot * cv * qty
  const fee = computeFee(product, valuationPrice, qty, spot)

  // Only the portion that increases exposure needs new margin.
  const net = existing?.net_qty ?? 0
  const signed = side === 'buy' ? qty : -qty
  const opensExposure = net === 0 || Math.sign(net) === Math.sign(signed)
  const closingQty = opensExposure ? 0 : Math.min(Math.abs(net), qty)
  const openingQty = qty - closingQty

  let marginRequired = 0
  if (openingQty > 0) {
    marginRequired = perp
      ? // Direction does not enter into it on a perpetual: both sides post the
        // same notional-over-leverage, since both can lose without limit.
        perpMargin(valuationPrice, cv, openingQty, shortImRate(product), leverage)
      : side === 'buy'
        ? valuationPrice * cv * openingQty
        : (shortImRate(product) * spot + valuationPrice) * cv * openingQty
    marginRequired += fee
  }

  const preview: OrderPreview = {
    fillPrice,
    premium,
    notional,
    fee,
    marginRequired,
    error: null,
    warning: null,
  }

  if (marginRequired > available) {
    preview.error = `Insufficient margin — needs $${marginRequired.toFixed(2)}, available $${available.toFixed(2)}`
    return preview
  }

  // No wide-spread warning: Delta's ticket does not carry one, and the bid and
  // the ask are quoted directly above the quantity, so the spread is on screen
  // for anyone who looks. The ticket no longer renders warnings at all.
  if (orderType === 'limit' && fillPrice === null) {
    preview.warning = 'Price is away from the market — this order will rest until it crosses'
  }

  return preview
}

/**
 * Does a resting limit order cross the current book? Returns the fill price if so.
 *
 * The fill happens at the touch, not at the limit — a buy limit at 30 against a
 * 24.9 offer fills at 24.9, the better price, which is what a real book gives you.
 */
export function crossesNow(side: Side, limitPrice: number, ticker: Ticker | undefined): number | null {
  if (side === 'buy') {
    const ask = bestAsk(ticker)
    return ask !== null && ask <= limitPrice ? ask : null
  }
  const bid = bestBid(ticker)
  return bid !== null && bid >= limitPrice ? bid : null
}
