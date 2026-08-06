import { useEffect, useMemo, useRef, useState } from 'react'
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
// than derived from one another, because a derivation would be wrong.
//
// Delta does not render one wide table either. The calls and the puts are
// separate scroll panes with the strike riding between them, which is why
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

const clamp = (n: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, n))

type BookSide = 'call' | 'put'

/** A clicked row: the strike, and which of the two books took the click. */
interface Selection {
  strike: number
  side: BookSide
}

/**
 * The option chain, laid out to match Delta Exchange's own.
 *
 * In-the-money rows are lifted to the raised surface, per side — a call below
 * spot, a put above it — which is the neutral step Delta uses (measured off
 * their chain at #22242c, our `raised`), not a colour. The ATM row is still
 * marked by the single brand-orange rule, and a clicked strike still takes that
 * same rule and nothing more.
 *
 * A held leg is flagged on the strike spine: an L for long, an S for short, on
 * the strike's left for a call and its right for a put — the side each book
 * sits on — in the position's colour.
 *
 * Click semantics follow their terminal — a bid is what you sell into, an ask is
 * what you buy from, and the clicked price seeds the order ticket. Everything
 * else, the mark included, is informational.
 *
 * The two books scroll as one. Vertically they are the same list of strikes.
 * Horizontally they are mirrored, both reading outward from the strike, so
 * scrolling the calls out to Low walks the puts out to Low alongside it. Only
 * the calls book shows its vertical scrollbar; the puts book's is suppressed.
 */
export function OptionChain({ expiry, positions, onPick }: Props) {
  useMarketTick() // repaint on every throttled market update
  const spot = market.spot

  const positionBySymbol = useMemo(() => {
    const m = new Map<string, PositionRow>()
    for (const p of positions) m.set(p.symbol, p)
    return m
  }, [positions])

  // The strike nearest spot — anchors the initial scroll.
  const atmStrike = useMemo(() => {
    if (!spot || expiry.strikes.length === 0) return null
    return expiry.strikes.reduce((best, s) => (Math.abs(s - spot) < Math.abs(best - spot) ? s : best))
  }, [expiry.strikes, spot])

  // Delta marks the money with a single rule laid where spot falls in the
  // ladder — not a box around a row. It sits above the lowest strike the
  // underlying has not reached, so the line lands between the two that
  // bracket it.
  const spotRule = useMemo(() => {
    if (!spot) return null
    let above: number | null = null
    for (const s of expiry.strikes) {
      if (s >= spot && (above === null || s < above)) above = s
    }
    return above
  }, [expiry.strikes, spot])

  // The row the user has clicked, and which book they clicked it in — only that
  // book rules it. Purely a reading aid; it holds no order state.
  const [selected, setSelected] = useState<Selection | null>(null)

  // A strike picked out on one expiry means nothing on the next.
  useEffect(() => setSelected(null), [expiry.label])

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
    if (!from || !to) return

    // How far this book has read away from the strike. The calls travel away
    // by scrolling towards zero and the puts by scrolling away from it, so the
    // two measurements are opposite ends of the same distance.
    const fromMax = from.scrollWidth - from.clientWidth
    const toMax = to.scrollWidth - to.clientWidth
    const away = source === 'calls' ? fromMax - from.scrollLeft : from.scrollLeft

    const left = clamp(source === 'calls' ? away : toMax - away, 0, toMax)
    const top = from.scrollTop
    if (to.scrollLeft === left && to.scrollTop === top) return

    syncing.current = true
    to.scrollLeft = left
    to.scrollTop = top
    // The scroll event from those assignments lands before the next frame.
    requestAnimationFrame(() => {
      syncing.current = false
    })
  }

  // Park the books facing each other — both read right up to the strike — with
  // the ATM row centred. Once per expiry; after that the user's scroll position
  // is left alone.
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
          spot={spot}
          spotRule={spotRule}
          selected={selected}
          onSelect={(strike) => setSelected({ strike, side: 'call' })}
          positionBySymbol={positionBySymbol}
          onPick={onPick}
          paneRef={callsRef}
          onScroll={syncFrom('calls')}
          // The one visible vertical scrollbar, so it lands against the strike.
          // Both books reserve the horizontal gutter whether or not they need
          // it: the puts carry the strike and so run 102px wider, and without
          // this the puts alone would take a horizontal scrollbar and stop a
          // gutter's height short of the calls at the bottom.
          className="overflow-x-scroll overflow-y-scroll"
        />
        <Book
          side="put"
          expiry={expiry}
          spot={spot}
          spotRule={spotRule}
          selected={selected}
          onSelect={(strike) => setSelected({ strike, side: 'put' })}
          positionBySymbol={positionBySymbol}
          onPick={onPick}
          paneRef={putsRef}
          onScroll={syncFrom('puts')}
          className="overflow-x-scroll overflow-y-scroll no-vscrollbar"
        />
      </div>
    </div>
  )
}

/**
 * One side of the chain. The puts book carries the strike column at its head,
 * pinned there rather than scrolling with the rest of it.
 */
function Book({
  side,
  expiry,
  spot,
  spotRule,
  selected,
  onSelect,
  positionBySymbol,
  onPick,
  paneRef,
  onScroll,
  className,
}: {
  side: BookSide
  expiry: Expiry
  spot: number
  spotRule: number | null
  selected: Selection | null
  onSelect: (strike: number) => void
  positionBySymbol: Map<string, PositionRow>
  onPick: Props['onPick']
  paneRef: React.RefObject<HTMLDivElement | null>
  onScroll: () => void
  className: string
}) {
  const cols = side === 'call' ? CALL_COLS : PUT_COLS
  const template = side === 'call' ? CALL_TEMPLATE : PUT_TEMPLATE
  const book = side === 'call' ? expiry.calls : expiry.puts

  // A click rules the row in the book that took it and nowhere else.
  const ruled = selected?.side === side ? selected.strike : null

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
              className="strike-spine border-x border-line"
            />
          )}
          {cols.map((k) => (
            <Head key={k} spec={COLS[k]} />
          ))}
        </div>

        {expiry.strikes.map((strike) => {
          const product = book.get(strike)
          const position = product ? positionBySymbol.get(product.symbol) : undefined

          // Both legs at this strike, so the spine can flag a held call on its
          // left and a held put on its right.
          const callPos = positionBySymbol.get(expiry.calls.get(strike)?.symbol ?? '')
          const putPos = positionBySymbol.get(expiry.puts.get(strike)?.symbol ?? '')

          // A call is in the money below spot, a put above it. Delta lifts the
          // in-the-money side to the raised surface — a neutral step, not a
          // colour — so the row bg carries it and hover steps once further up.
          const itm = spot > 0 && (side === 'call' ? strike < spot : strike > spot)
          const rowBg = itm ? 'bg-raised hover:bg-raised-2' : 'hover:bg-raised/50'

          return (
            <div
              key={strike}
              data-strike={strike}
              // The click sits under the bid and ask buttons rather than around
              // them, so lifting an ask both rules the row and opens the ticket.
              onClick={() => onSelect(strike)}
              // A clicked row is boxed top and bottom; the money is a single
              // rule laid above the strike spot has not reached. Row height is
              // Delta's: 43px.
              className={`grid h-[43px] cursor-pointer items-center ${rowBg} ${
                strike === ruled
                  ? 'border-y-[0.8px] border-brand-text'
                  : strike === spotRule
                    ? 'border-t-[0.8px] border-t-brand-text border-b border-b-line'
                    : 'border-b border-line'
              }`}
              style={{ gridTemplateColumns: template }}
            >
              {side === 'put' && (
                <StrikeCell
                  strike={strike}
                  callPos={callPos}
                  putPos={putPos}
                  // The strike is ruled alongside whichever book was clicked,
                  // and closes that book's box off on its far side.
                  ruledFrom={selected?.strike === strike ? selected.side : null}
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

/**
 * The strike, on its own spine between the two books.
 *
 * It also closes off the selected row's box. A box opened in the calls runs
 * leftward, so the strike's right edge shuts it and the strike supplies its own
 * top and bottom — the puts row it lives in is not ruled. A box opened in the
 * puts runs rightward, so the left edge shuts it and the row's own rule already
 * carries top and bottom across. Either way the edge between the strike and the
 * book that was clicked stays grey, because it falls inside the box.
 *
 * Sides are coloured one at a time rather than by overriding a shorthand, so
 * that none of this depends on the order Tailwind happens to emit.
 */
function StrikeCell({
  strike,
  callPos,
  putPos,
  ruledFrom,
}: {
  strike: number
  callPos: PositionRow | undefined
  putPos: PositionRow | undefined
  ruledFrom: BookSide | null
}) {
  const rule =
    ruledFrom === 'call'
      ? 'border-x border-l-line border-r-brand-text border-y-[0.8px] border-y-brand-text'
      : ruledFrom === 'put'
        ? 'border-x border-l-brand-text border-r-line'
        : 'border-x border-l-line border-r-line'

  return (
    <div
      className={`strike-spine num relative flex items-center justify-center self-stretch text-[12px] font-bold text-ink ${rule}`}
    >
      {/* A held call flags the strike's left, a held put its right — the side
          each book sits on. */}
      <PosFlag position={callPos} className="left-1" />
      {price(strike, 0)}
      <PosFlag position={putPos} className="right-1" />
    </div>
  )
}

/**
 * The L/S marker Delta hangs beside a strike you hold — a solid disc in the
 * position's colour with a white letter, green for long and red for short,
 * pinned to one edge of the spine and vertically centred. Absent when flat.
 */
function PosFlag({
  position,
  className,
}: {
  position: PositionRow | undefined
  className: string
}) {
  if (!position || position.net_qty === 0) return null
  const long = position.net_qty > 0
  return (
    <span
      className={`absolute top-1/2 flex h-4 w-4 -translate-y-1/2 items-center justify-center rounded-full text-[9px] font-bold text-white ${className} ${
        long ? 'bg-pos-solid' : 'bg-neg-solid'
      }`}
      title={`${long ? 'Long' : 'Short'} ${Math.abs(position.net_qty)} lot${Math.abs(position.net_qty) === 1 ? '' : 's'}`}
    >
      {long ? 'L' : 'S'}
    </span>
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
