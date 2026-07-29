import { useEffect, useMemo, useRef } from 'react'
import type { Expiry, Product, Ticker } from '../lib/delta'
import { UNDERLYING } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import type { PositionRow, Side } from '../engine/paper'
import { greek, ivShort, price, timeToExpiry, usdPrice } from '../lib/format'

interface Props {
  expiry: Expiry
  positions: PositionRow[]
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
}

/**
 * The option chain, laid out to match Delta Exchange's own.
 *
 * Column order per side — calls left-to-right, puts mirrored:
 *   Vega · Gamma · Delta · Bid(Price/IV) · Mark(Price/IV) · Ask(Price/IV)
 *
 * Deliberately absent, because Delta's chain does not have them: any
 * in-the-money row tint, and any highlight on the at-the-money strike cell.
 * Every one of their chain cells is transparent; the at-the-money row is marked
 * only by a 0.8px brand-orange rule above and below it.
 *
 * Click semantics follow their terminal — a bid is what you sell into, an ask is
 * what you buy from, and the clicked price seeds the order ticket. The mark is
 * informational and not clickable.
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

  // Centre on ATM once per expiry, then leave the user's scroll position alone.
  useEffect(() => {
    if (!atmStrike || centredFor.current === expiry.label) return
    const el = scrollRef.current?.querySelector<HTMLElement>(`[data-strike="${atmStrike}"]`)
    if (!el) return
    centredFor.current = expiry.label
    el.scrollIntoView({ block: 'center' })
  }, [atmStrike, expiry.label])

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Calls · underlying price and countdown · Puts */}
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

      <div className={`${GRID} shrink-0 border-b border-line`}>
        <Head>Vega</Head>
        <Head>Gamma</Head>
        <Head>Delta</Head>
        <Head sub="(Price / IV)" tone="pos">
          Bid
        </Head>
        <Head sub="(Price / IV)">Mark</Head>
        <Head sub="(Price / IV)" tone="neg">
          Ask
        </Head>
        <Head align="center">Strike</Head>
        <Head sub="(Price / IV)" tone="pos">
          Bid
        </Head>
        <Head sub="(Price / IV)">Mark</Head>
        <Head sub="(Price / IV)" tone="neg">
          Ask
        </Head>
        <Head>Delta</Head>
        <Head>Gamma</Head>
        <Head>Vega</Head>
      </div>

      <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto">
        {expiry.strikes.map((strike) => {
          const call = expiry.calls.get(strike)
          const put = expiry.puts.get(strike)
          const isAtm = strike === atmStrike
          const held =
            (call && positionBySymbol.get(call.symbol)) || (put && positionBySymbol.get(put.symbol))

          return (
            <div
              key={strike}
              data-strike={strike}
              // Delta marks the ATM row with a 0.8px brand rule top and bottom,
              // and nothing else. Row height is theirs: 43px.
              className={`${GRID} h-[43px] items-center hover:bg-raised/50 ${
                isAtm ? 'border-y-[0.8px] border-brand-text' : 'border-b border-line'
              }`}
            >
              <SideCells
                product={call}
                ticker={call ? market.get(call.symbol) : undefined}
                onPick={onPick}
              />

              <div className="num flex items-center justify-center gap-1 text-[12px] text-ink">
                {/* Not Delta's — a small marker so held strikes stay findable. */}
                {held && <span className="text-[10px] text-brand-text">●</span>}
                {price(strike, 0)}
              </div>

              <SideCells
                product={put}
                ticker={put ? market.get(put.symbol) : undefined}
                onPick={onPick}
                mirrored
              />
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Six columns per side, with Delta's 102px strike gutter down the middle. */
const GRID = 'grid grid-cols-[repeat(6,minmax(0,1fr))_102px_repeat(6,minmax(0,1fr))]'

function Head({
  children,
  sub,
  tone,
  align = 'right',
}: {
  children: React.ReactNode
  sub?: string
  tone?: 'pos' | 'neg'
  align?: 'right' | 'center'
}) {
  const colour = tone === 'pos' ? 'text-pos' : tone === 'neg' ? 'text-neg' : 'text-ink-2'
  return (
    <div className={`px-2 py-1.5 ${align === 'center' ? 'text-center' : 'text-right'}`}>
      <div className={`text-[12px] ${colour}`}>{children}</div>
      {sub && <div className="text-[10px] text-ink-2">{sub}</div>}
    </div>
  )
}

interface SideProps {
  product: Product | undefined
  ticker: Ticker | undefined
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
  /** Puts render Bid · Mark · Ask first, then Delta · Gamma · Vega. */
  mirrored?: boolean
}

function SideCells({ product, ticker, onPick, mirrored = false }: SideProps) {
  if (!product) {
    return (
      <>
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="px-2 text-right text-[12px] text-ink-4">
            -
          </div>
        ))}
      </>
    )
  }

  const q = ticker?.quotes
  const g = ticker?.greeks
  const bid = q?.best_bid ? Number(q.best_bid) : null
  const ask = q?.best_ask ? Number(q.best_ask) : null

  const greeks = [
    <Stat key="vega" value={g?.vega} dp={2} />,
    <Stat key="gamma" value={g?.gamma} dp={5} />,
    <Stat key="delta" value={g?.delta} dp={2} />,
  ]

  const prices = [
    <PriceCell
      key="bid"
      value={bid}
      iv={q?.bid_iv}
      tone="pos"
      // Hitting the bid means selling.
      onClick={bid === null ? undefined : () => onPick(product, 'sell', bid)}
    />,
    <PriceCell key="mark" value={ticker?.mark_price} iv={q?.mark_iv} tone="mark" />,
    <PriceCell
      key="ask"
      value={ask}
      iv={q?.ask_iv}
      tone="neg"
      // Lifting the ask means buying.
      onClick={ask === null ? undefined : () => onPick(product, 'buy', ask)}
    />,
  ]

  return <>{mirrored ? [...prices, ...greeks.reverse()] : [...greeks, ...prices]}</>
}

function Stat({ value, dp }: { value: string | undefined; dp: number }) {
  return <div className="num px-2 text-right text-[12px] text-ink">{greek(value, dp)}</div>
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
