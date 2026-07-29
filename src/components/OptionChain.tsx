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
// ---------------------------------------------------------------------------

type ColKey =
  | 'oi' | 'bidQty' | 'bid' | 'mark' | 'ask' | 'askQty' | 'delta' | 'volume'
  | 'oiChg' | 'pos' | 'gamma' | 'vega' | 'theta' | 'chg24' | 'last'
  | 'open' | 'high' | 'low'

interface ColSpec {
  label: string
  sub?: string
  tone?: 'pos' | 'neg'
  /** Widths are Delta's own. */
  w: number
}

const COLS: Record<ColKey, ColSpec> = {
  oi: { label: 'OI', w: 83 },
  bidQty: { label: 'Bid Qty', sub: UNDERLYING, w: 80 },
  bid: { label: 'Bid', sub: '(Price / IV)', tone: 'pos', w: 80 },
  mark: { label: 'Mark', sub: '(Price / IV)', w: 80 },
  ask: { label: 'Ask', sub: '(Price / IV)', tone: 'neg', w: 80 },
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

const TEMPLATE = [
  ...CALL_COLS.map((k) => `${COLS[k].w}px`),
  `${STRIKE_W}px`,
  ...PUT_COLS.map((k) => `${COLS[k].w}px`),
].join(' ')

const CALLS_WIDTH = CALL_COLS.reduce((sum, k) => sum + COLS[k].w, 0)

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

  const scrollRef = useRef<HTMLDivElement>(null)
  const centredFor = useRef<string | null>(null)

  // Centre on the strike column horizontally and the ATM row vertically, once
  // per expiry. After that the user's scroll position is left alone.
  useEffect(() => {
    const el = scrollRef.current
    if (!el || !atmStrike || centredFor.current === expiry.label) return
    centredFor.current = expiry.label

    el.scrollLeft = CALLS_WIDTH + STRIKE_W / 2 - el.clientWidth / 2

    const row = el.querySelector<HTMLElement>(`[data-strike="${atmStrike}"]`)
    if (row) el.scrollTop = row.offsetTop - el.clientHeight / 2 + row.offsetHeight / 2
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

      <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
        <div className="min-w-max">
          <div
            className="sticky top-0 z-10 grid border-b border-line bg-surface"
            style={{ gridTemplateColumns: TEMPLATE }}
          >
            {CALL_COLS.map((k) => (
              <Head key={`c-${k}`} spec={COLS[k]} />
            ))}
            <Head spec={{ label: 'Strike', w: STRIKE_W }} align="center" />
            {PUT_COLS.map((k) => (
              <Head key={`p-${k}`} spec={COLS[k]} />
            ))}
          </div>

          {expiry.strikes.map((strike) => {
            const call = expiry.calls.get(strike)
            const put = expiry.puts.get(strike)
            const isAtm = strike === atmStrike
            const callPos = call ? positionBySymbol.get(call.symbol) : undefined
            const putPos = put ? positionBySymbol.get(put.symbol) : undefined

            return (
              <div
                key={strike}
                data-strike={strike}
                // Delta marks the ATM row with a brand rule top and bottom and
                // nothing else. Row height is theirs: 43px.
                className={`grid h-[43px] items-center hover:bg-raised/50 ${
                  isAtm ? 'border-y-[0.8px] border-brand-text' : 'border-b border-line'
                }`}
                style={{ gridTemplateColumns: TEMPLATE }}
              >
                {CALL_COLS.map((k) => (
                  <ChainCell
                    key={`c-${k}`}
                    col={k}
                    product={call}
                    ticker={call ? market.get(call.symbol) : undefined}
                    position={callPos}
                    onPick={onPick}
                  />
                ))}

                <div className="num flex items-center justify-center gap-1 text-[12px] text-ink">
                  {/* Not Delta's — a marker so held strikes stay findable. */}
                  {(callPos || putPos) && <span className="text-[10px] text-brand-text">●</span>}
                  {price(strike, 0)}
                </div>

                {PUT_COLS.map((k) => (
                  <ChainCell
                    key={`p-${k}`}
                    col={k}
                    product={put}
                    ticker={put ? market.get(put.symbol) : undefined}
                    position={putPos}
                    onPick={onPick}
                  />
                ))}
              </div>
            )
          })}
        </div>
      </div>
    </div>
  )
}

function Head({ spec, align = 'right' }: { spec: ColSpec; align?: 'right' | 'center' }) {
  const colour = spec.tone === 'pos' ? 'text-pos' : spec.tone === 'neg' ? 'text-neg' : 'text-ink-2'
  return (
    <div className={`px-2 py-1.5 ${align === 'center' ? 'text-center' : 'text-right'}`}>
      <div className={`text-[12px] whitespace-nowrap ${colour}`}>{spec.label}</div>
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
