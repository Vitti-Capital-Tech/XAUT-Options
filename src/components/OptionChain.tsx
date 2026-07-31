import { useEffect, useMemo, useRef } from 'react'
import type { Expiry, Product, Ticker } from '../lib/delta'
import { UNDERLYING } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import type { PositionRow, Side } from '../engine/paper'
import { compact, greek, ivShort, price, timeToExpiry, usdPrice } from '../lib/format'

interface Props {
  expiry: Expiry
  positions: PositionRow[]
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
}

// ---------------------------------------------------------------------------
// Column definitions, transcribed from Delta's rendered chain: 18 per side.
//
// The two sides are not a clean mirror. OI sits against the strike on both
// sides, and the quote block reads Bid Qty → Bid → Mark → Ask → Ask Qty
// left-to-right on both sides. Only the outer block (Delta, Volume, greeks,
// OHLC) is mirrored. Both orders are therefore written out literally rather
// than derived, because a derivation would be wrong.
//
// Delta renders the two sides as two independently scrolling books rather than
// one wide table, with the strike column heading up the puts book. That is why
// their at-the-money rule draws as two boxes and their vertical scrollbar sits
// between the calls' Ask and the strike rather than out at the window edge.
// ---------------------------------------------------------------------------

type ColKey =
  | 'oi' | 'bidQty' | 'bid' | 'mark' | 'ask' | 'askQty' | 'delta' | 'volume'
  | 'oiChg' | 'pos' | 'gamma' | 'vega' | 'theta' | 'chg24' | 'last'
  | 'open' | 'high' | 'low'

interface ColSpec {
  label: string
  sub?: string
  /** Widths are Delta's own. */
  w: number
}

const COLS: Record<ColKey, ColSpec> = {
  oi: { label: 'OI', w: 83 },
  bidQty: { label: 'Bid Qty', sub: UNDERLYING, w: 80 },
  bid: { label: 'Bid', sub: '(Price / IV)', w: 80 },
  mark: { label: 'Mark', sub: '(Price / IV)', w: 80 },
  ask: { label: 'Ask', sub: '(Price / IV)', w: 80 },
  askQty: { label: 'Ask Qty', sub: UNDERLYING, w: 80 },
  delta: { label: 'Delta', w: 80 },
  volume: { label: 'Volume', w: 83 },
  oiChg: { label: '6H OI Chg.', w: 91 },
  pos: { label: 'POS', sub: UNDERLYING, w: 80 },
  gamma: { label: 'Gamma', w: 80 },
  vega: { label: 'Vega', w: 80 },
  theta: { label: 'Theta', w: 80 },
  chg24: { label: '24hr Chg.', w: 85 },
  last: { label: 'Last', w: 80 },
  open: { label: 'Open', w: 80 },
  high: { label: 'High', w: 80 },
  low: { label: 'Low', w: 80 },
}

const CALL_COLS: ColKey[] = [
  'low', 'high', 'open', 'last', 'chg24', 'theta', 'vega', 'gamma', 'pos',
  'oiChg', 'volume', 'delta', 'bidQty', 'bid', 'mark', 'ask', 'askQty', 'oi',
]

const PUT_COLS: ColKey[] = [
  'oi', 'bidQty', 'bid', 'mark', 'ask', 'askQty', 'delta', 'volume', 'oiChg',
  'pos', 'gamma', 'vega', 'theta', 'chg24', 'last', 'open', 'high', 'low',
]

const STRIKE_W = 102

const CALL_TEMPLATE = CALL_COLS.map((k) => `${COLS[k].w}px`).join(' ')

const PUT_TEMPLATE = [`${STRIKE_W}px`, ...PUT_COLS.map((k) => `${COLS[k].w}px`)].join(' ')

/**
 * The option chain, laid out to match Delta Exchange's own.
 *
 * Deliberately absent, because Delta's chain does not have them: any
 * in-the-money row tint, and any highlight on the at-the-money strike cell.
 * Every one of their chain cells is transparent; the ATM row is marked only by
 * a brand-orange rule above and below it.
 *
 * Click semantics follow their terminal — a bid is what you sell into, an ask is
 * what you buy from, and the clicked price seeds the order ticket. Everything
 * else, the mark included, is informational.
 *
 * The two books scroll horizontally on their own and vertically in lockstep.
 * Only the calls book shows its vertical scrollbar; the puts book's is
 * suppressed, so one list reads as one list.
 */
export function OptionChain({ expiry, positions, onPick }: Props) {
  useMarketTick() // repaint on every throttled market update
  const spot = market.spot

  const positionBySymbol = useMemo(() => {
    const m = new Map<string, PositionRow>()
    for (const p of positions) m.set(p.symbol, p)
    return m
  }, [positions])

  // The strike nearest spot — anchors the ATM rule and the initial scroll.
  const atmStrike = useMemo(() => {
    if (!spot || expiry.strikes.length === 0) return null
    return expiry.strikes.reduce((best, s) => (Math.abs(s - spot) < Math.abs(best - spot) ? s : best))
  }, [expiry.strikes, spot])

  const callsRef = useRef<HTMLDivElement>(null)
  const putsRef = useRef<HTMLDivElement>(null)
  const centredFor = useRef<string | null>(null)
  // Raised while one book is driving the other, so the scroll event that the
  // assignment fires does not bounce straight back and fight the user.
  const syncing = useRef(false)

  const syncFrom = (source: 'calls' | 'puts') => () => {
    if (syncing.current) return
    const from = (source === 'calls' ? callsRef : putsRef).current
    const to = (source === 'calls' ? putsRef : callsRef).current
    if (!from || !to || to.scrollTop === from.scrollTop) return

    syncing.current = true
    to.scrollTop = from.scrollTop
    // The scroll event from that assignment lands before the next frame.
    requestAnimationFrame(() => {
      syncing.current = false
    })
  }

  // Park the books facing each other — calls read right up to the strike, puts
  // away from it — with the ATM row centred. Once per expiry; after that the
  // user's scroll position is left alone.
  useEffect(() => {
    const calls = callsRef.current
    const puts = putsRef.current
    if (!calls || !puts || !atmStrike || centredFor.current === expiry.label) return
    centredFor.current = expiry.label

    calls.scrollLeft = calls.scrollWidth
    puts.scrollLeft = 0

    const row = puts.querySelector<HTMLElement>(`[data-strike="${atmStrike}"]`)
    if (!row) return
    const top = row.offsetTop - puts.clientHeight / 2 + row.offsetHeight / 2
    calls.scrollTop = top
    puts.scrollTop = top
  }, [atmStrike, expiry.label])

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Calls · underlying price and countdown · Puts. Stays put while the
          column area scrolls horizontally beneath it. */}
      <div className="flex shrink-0 items-center justify-between border-b border-line px-4 py-2">
        <span className="text-[14px] text-ink">Calls</span>
        <div className="flex items-center gap-3 text-[14px]">
          <span className="text-ink-2">
            {UNDERLYING} <span className="num text-spot">{usdPrice(spot)}</span>
          </span>
          <span className="text-ink-4">|</span>
          <span className="text-ink-2">
            Time to Expiry{' '}
            <span className="num text-brand-text">{timeToExpiry(expiry.settlementTime)}</span>
          </span>
        </div>
        <span className="text-[14px] text-ink">Puts</span>
      </div>

      <div className="flex min-h-0 flex-1">
        <Book
          side="call"
          expiry={expiry}
          atmStrike={atmStrike}
          positionBySymbol={positionBySymbol}
          onPick={onPick}
          paneRef={callsRef}
          onScroll={syncFrom('calls')}
          // The one visible vertical scrollbar, so it lands against the strike.
          className="overflow-x-auto overflow-y-scroll"
        />
        <Book
          side="put"
          expiry={expiry}
          atmStrike={atmStrike}
          positionBySymbol={positionBySymbol}
          onPick={onPick}
          paneRef={putsRef}
          onScroll={syncFrom('puts')}
          className="overflow-x-auto overflow-y-scroll no-vscrollbar"
        />
      </div>
    </div>
  )
}

/**
 * One side of the chain. The puts book carries the strike column at its head,
 * which is where Delta puts it.
 */
function Book({
  side,
  expiry,
  atmStrike,
  positionBySymbol,
  onPick,
  paneRef,
  onScroll,
  className,
}: {
  side: 'call' | 'put'
  expiry: Expiry
  atmStrike: number | null
  positionBySymbol: Map<string, PositionRow>
  onPick: Props['onPick']
  paneRef: React.RefObject<HTMLDivElement | null>
  onScroll: () => void
  className: string
}) {
  const cols = side === 'call' ? CALL_COLS : PUT_COLS
  const template = side === 'call' ? CALL_TEMPLATE : PUT_TEMPLATE
  const book = side === 'call' ? expiry.calls : expiry.puts

  return (
    <div ref={paneRef} onScroll={onScroll} className={`min-w-0 flex-1 ${className}`}>
      <div className="min-w-max">
        <div
          className="sticky top-0 z-10 grid border-b border-line bg-surface"
          style={{ gridTemplateColumns: template }}
        >
          {side === 'put' && (
            <Head
              spec={{ label: 'Strike', w: STRIKE_W }}
              align="center"
              className="border-x border-line"
            />
          )}
          {cols.map((k) => (
            <Head key={k} spec={COLS[k]} />
          ))}
        </div>

        {expiry.strikes.map((strike) => {
          const product = book.get(strike)
          const position = product ? positionBySymbol.get(product.symbol) : undefined

          return (
            <div
              key={strike}
              data-strike={strike}
              // Delta marks the ATM row with a brand rule top and bottom and
              // nothing else. Row height is theirs: 43px.
              className={`grid h-[43px] items-center hover:bg-raised/50 ${
                strike === atmStrike
                  ? 'border-y-[0.8px] border-brand-text'
                  : 'border-b border-line'
              }`}
              style={{ gridTemplateColumns: template }}
            >
              {side === 'put' && (
                <StrikeCell
                  strike={strike}
                  expiry={expiry}
                  positionBySymbol={positionBySymbol}
                />
              )}
              {cols.map((k) => (
                <ChainCell
                  key={k}
                  col={k}
                  product={product}
                  ticker={product ? market.get(product.symbol) : undefined}
                  position={position}
                  onPick={onPick}
                />
              ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** The strike, walled off from both books by a rule on either side. */
function StrikeCell({
  strike,
  expiry,
  positionBySymbol,
}: {
  strike: number
  expiry: Expiry
  positionBySymbol: Map<string, PositionRow>
}) {
  const call = expiry.calls.get(strike)
  const put = expiry.puts.get(strike)
  const held =
    (call && positionBySymbol.has(call.symbol)) || (put && positionBySymbol.has(put.symbol))

  return (
    <div className="num flex h-full items-center justify-center gap-1 border-x border-line text-[12px] text-ink">
      {/* Not Delta's — a marker so held strikes stay findable. */}
      {held && <span className="text-[10px] text-brand-text">●</span>}
      {price(strike, 0)}
    </div>
  )
}

/**
 * Every header reads in the same secondary ink, Bid and Ask included — Delta
 * tones the quotes themselves green and red, never the labels above them.
 */
function Head({
  spec,
  align = 'right',
  className = '',
}: {
  spec: ColSpec
  align?: 'right' | 'center'
  className?: string
}) {
  return (
    <div
      className={`px-2 py-1.5 ${align === 'center' ? 'text-center' : 'text-right'} ${className}`}
    >
      <div className="text-[12px] whitespace-nowrap text-ink-2">{spec.label}</div>
      {spec.sub && <div className="text-[10px] whitespace-nowrap text-ink-2">{spec.sub}</div>}
    </div>
  )
}

// ---------------------------------------------------------------------------

/** `$` plus a compacted magnitude, e.g. `$88.27K` — how Delta shows OI and Volume. */
function usdCompact(v: number | string | null | undefined): string {
  const n = typeof v === 'string' ? Number(v) : v
  if (n === null || n === undefined || !Number.isFinite(n)) return '-'
  return `${n < 0 ? '-' : ''}$${compact(Math.abs(n))}`
}

/** Book size or position size expressed in the underlying, e.g. `30.877`. */
function inUnderlying(contracts: string | number | null | undefined, cv: number): string {
  const n = typeof contracts === 'string' ? Number(contracts) : contracts
  if (n === null || n === undefined || !Number.isFinite(n) || n === 0) return '-'
  return (n * cv).toLocaleString('en-US', { minimumFractionDigits: 3, maximumFractionDigits: 3 })
}

interface CellProps {
  col: ColKey
  product: Product | undefined
  ticker: Ticker | undefined
  position: PositionRow | undefined
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
}

function ChainCell({ col, product, ticker, position, onPick }: CellProps) {
  if (!product) return <Plain>-</Plain>

  const q = ticker?.quotes
  const g = ticker?.greeks
  const cv = Number(product.contract_value)

  switch (col) {
    case 'bid':
    case 'ask': {
      const raw = col === 'bid' ? q?.best_bid : q?.best_ask
      const value = raw ? Number(raw) : null
      const iv = col === 'bid' ? q?.bid_iv : q?.ask_iv
      return (
        <PriceCell
          value={value}
          iv={iv}
          tone={col === 'bid' ? 'pos' : 'neg'}
          // Hitting the bid sells; lifting the ask buys.
          onClick={value === null ? undefined : () => onPick(product, col === 'bid' ? 'sell' : 'buy', value)}
        />
      )
    }
    case 'mark':
      return <PriceCell value={ticker?.mark_price} iv={q?.mark_iv} tone="mark" />

    case 'bidQty':
      return <Plain>{inUnderlying(q?.bid_size, cv)}</Plain>
    case 'askQty':
      return <Plain>{inUnderlying(q?.ask_size, cv)}</Plain>

    case 'delta':
      return <Plain>{greek(g?.delta, 2)}</Plain>
    case 'gamma':
      return <Plain>{greek(g?.gamma, 5)}</Plain>
    case 'vega':
      return <Plain>{greek(g?.vega, 2)}</Plain>
    case 'theta':
      return <Plain>{greek(g?.theta, 2)}</Plain>

    case 'oi':
      return <Plain>{usdCompact(ticker?.oi_value_usd)}</Plain>
    case 'oiChg':
      return <Plain>{usdCompact(ticker?.oi_change_usd_6h)}</Plain>
    case 'volume':
      return <Plain>{usdCompact(ticker?.turnover_usd)}</Plain>

    case 'pos':
      // Our own paper position, signed, in the underlying.
      return <Plain>{position ? inUnderlying(position.net_qty, cv) : '-'}</Plain>

    case 'chg24': {
      const n = ticker?.ltp_change_24h ? Number(ticker.ltp_change_24h) : null
      if (n === null || !Number.isFinite(n)) return <Plain>-</Plain>
      return (
        <Plain className={n > 0 ? 'text-pos' : n < 0 ? 'text-neg' : undefined}>
          {n.toFixed(2)}%
        </Plain>
      )
    }

    case 'last':
      return <Plain>{usdPrice(ticker?.close)}</Plain>
    // Delta renders these without a currency prefix.
    case 'open':
      return <Plain>{price(ticker?.open)}</Plain>
    case 'high':
      return <Plain>{price(ticker?.high)}</Plain>
    case 'low':
      return <Plain>{price(ticker?.low)}</Plain>
  }
}

function Plain({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <div className={`num px-2 text-right text-[12px] ${className ?? 'text-ink'}`}>{children}</div>
  )
}

/** Price on top, its implied volatility beneath — Delta's "(Price / IV)" cell. */
function PriceCell({
  value,
  iv,
  tone,
  onClick,
}: {
  value: number | string | null | undefined
  iv: string | null | undefined
  tone: 'pos' | 'neg' | 'mark'
  onClick?: () => void
}) {
  const colour = tone === 'pos' ? 'text-pos' : tone === 'neg' ? 'text-neg' : 'text-ink'
  const hover = tone === 'pos' ? 'hover:bg-pos-muted' : tone === 'neg' ? 'hover:bg-neg-muted' : ''

  const body = (
    <>
      <div className={`num text-[12px] leading-tight ${colour}`}>{usdPrice(value)}</div>
      <div className="num text-[10px] leading-tight text-ink-2">{ivShort(iv)}</div>
    </>
  )

  if (!onClick) return <div className="px-2 py-1 text-right">{body}</div>

  return (
    <button
      type="button"
      onClick={onClick}
      title={`${tone === 'pos' ? 'Sell' : 'Buy'} at ${value}`}
      className={`flex h-full flex-col justify-center px-2 py-1 text-right transition-colors ${hover}`}
    >
      {body}
    </button>
  )
}
