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

import type { Product, Ticker } from '../lib/delta'

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

export type Side = 'buy' | 'sell'
export type OrderType = 'market' | 'limit'

export interface PositionRow {
  id: string
  account_id: string
  symbol: string
  product_id: number
  contract_type: string
  strike_price: string
  expiry_label: string
  contract_value: string
  net_qty: number
  avg_entry_price: string
  realized_pnl: string
}

export interface OrderRow {
  id: string
  account_id: string
  symbol: string
  product_id: number
  contract_type: string
  strike_price: string
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
  /** price * cv * |qty| at entry — what the position cost (long) or collected (short). */
  entryValue: number
  /** Current exit value of the position. */
  currentValue: number | null
  unrealized: number | null
  /** Unrealized as a share of entry value; null when entry value is zero. */
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

  // Delta values open positions off the fair mark price, not off the touch, and
  // this follows them. The exit price is kept as the fallback for the case their
  // mark is missing, which is the only case where the book is the better guess.
  const mark = markPrice(ticker) ?? exitPrice(ticker, netQty)
  const entryValue = avgEntry * cv * lots
  const currentValue = mark === null ? null : mark * cv * lots

  // Long: gain when the mark rises above entry. Short: gain when it falls below.
  const unrealized =
    mark === null ? null : netQty > 0 ? (mark - avgEntry) * lots * cv : (avgEntry - mark) * lots * cv

  const marginBlocked =
    netQty > 0
      ? entryValue // long option risk is capped at the premium paid
      : (imRate * spot + (mark ?? avgEntry)) * cv * lots

  return {
    netQty,
    avgEntry,
    mark,
    entryValue,
    currentValue,
    unrealized,
    unrealizedPct: entryValue > 0 && unrealized !== null ? (unrealized / entryValue) * 100 : null,
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
  const { product, side, orderType, qty, limitPrice } = intent
  const cv = Number(product.contract_value)
  const tick = Number(product.tick_size)

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
    marginRequired =
      side === 'buy'
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
