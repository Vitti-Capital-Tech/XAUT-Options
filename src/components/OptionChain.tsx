import { useEffect, useMemo, useRef } from 'react'
import type { Expiry, Product, Ticker } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import type { PositionRow, Side } from '../engine/paper'
import { compact, greek, iv, price } from '../lib/format'

interface Props {
  expiry: Expiry
  positions: PositionRow[]
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
}

/**
 * The option chain: calls on the left, puts on the right, strikes down the middle.
 *
 * Click semantics match Delta's terminal — clicking a bid sells into it, clicking
 * an ask buys from it, and the clicked price seeds the order ticket.
 */
export function OptionChain({ expiry, positions, onPick }: Props) {
  useMarketTick() // repaint on every throttled market update
  const spot = market.spot

  const positionBySymbol = useMemo(() => {
    const m = new Map<string, PositionRow>()
    for (const p of positions) m.set(p.symbol, p)
    return m
  }, [positions])

  // The strike nearest spot, used to anchor the ATM divider and the initial scroll.
  const atmStrike = useMemo(() => {
    if (!spot || expiry.strikes.length === 0) return null
    return expiry.strikes.reduce((best, s) =>
      Math.abs(s - spot) < Math.abs(best - spot) ? s : best,
    )
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
      <div className="grid grid-cols-[1fr_5.5rem_1fr] border-b border-zinc-800 bg-zinc-900/60 text-[10px] font-semibold tracking-wider text-zinc-500 uppercase">
        <div className="px-2 py-1.5 text-center">Calls</div>
        <div className="px-2 py-1.5 text-center text-zinc-400">Strike</div>
        <div className="px-2 py-1.5 text-center">Puts</div>
      </div>

      <div className="grid grid-cols-[repeat(6,1fr)_5.5rem_repeat(6,1fr)] border-b border-zinc-800 bg-zinc-900/30 text-[10px] text-zinc-500">
        <HeadCell>OI</HeadCell>
        <HeadCell>Vol</HeadCell>
        <HeadCell>IV</HeadCell>
        <HeadCell>Delta</HeadCell>
        <HeadCell className="text-emerald-500/70">Bid</HeadCell>
        <HeadCell className="text-rose-500/70">Ask</HeadCell>
        <HeadCell className="text-center">Price</HeadCell>
        <HeadCell className="text-emerald-500/70">Bid</HeadCell>
        <HeadCell className="text-rose-500/70">Ask</HeadCell>
        <HeadCell>Delta</HeadCell>
        <HeadCell>IV</HeadCell>
        <HeadCell>Vol</HeadCell>
        <HeadCell>OI</HeadCell>
      </div>

      <div ref={scrollRef} className="min-h-0 flex-1 overflow-y-auto">
        {expiry.strikes.map((strike) => {
          const call = expiry.calls.get(strike)
          const put = expiry.puts.get(strike)
          const callTicker = call ? market.get(call.symbol) : undefined
          const putTicker = put ? market.get(put.symbol) : undefined
          const isAtm = strike === atmStrike

          return (
            <div key={strike}>
              {isAtm && spot > 0 && (
                <div className="flex items-center gap-2 bg-zinc-900/80 px-3 py-0.5">
                  <div className="h-px flex-1 bg-amber-500/30" />
                  <span className="num text-[10px] font-semibold text-amber-400">
                    SPOT {price(spot)}
                  </span>
                  <div className="h-px flex-1 bg-amber-500/30" />
                </div>
              )}
              <div
                data-strike={strike}
                className="grid grid-cols-[repeat(6,1fr)_5.5rem_repeat(6,1fr)] border-b border-zinc-900/70 text-[11px] hover:bg-zinc-900/40"
              >
                <SideCells
                  product={call}
                  ticker={callTicker}
                  position={call ? positionBySymbol.get(call.symbol) : undefined}
                  // Calls below spot are in the money.
                  inTheMoney={spot > 0 && strike < spot}
                  onPick={onPick}
                />

                <div
                  className={`num flex items-center justify-center border-x border-zinc-800 px-1 py-1.5 font-semibold ${
                    isAtm ? 'bg-amber-500/10 text-amber-300' : 'text-zinc-300'
                  }`}
                >
                  {price(strike, 0)}
                </div>

                <SideCells
                  product={put}
                  ticker={putTicker}
                  position={put ? positionBySymbol.get(put.symbol) : undefined}
                  // Puts above spot are in the money.
                  inTheMoney={spot > 0 && strike > spot}
                  onPick={onPick}
                  mirrored
                />
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}

function HeadCell({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <div className={`px-1.5 py-1 text-right ${className}`}>{children}</div>
}

interface SideProps {
  product: Product | undefined
  ticker: Ticker | undefined
  position: PositionRow | undefined
  inTheMoney: boolean
  onPick: (product: Product, side: Side, presetPrice: number | null) => void
  /** Puts render their columns in mirror order, bid/ask nearest the strike. */
  mirrored?: boolean
}

function SideCells({ product, ticker, position, inTheMoney, onPick, mirrored = false }: SideProps) {
  if (!product) {
    return (
      <>
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="px-1.5 py-1.5 text-right text-zinc-700">
            ·
          </div>
        ))}
      </>
    )
  }

  const bid = ticker?.quotes?.best_bid ? Number(ticker.quotes.best_bid) : null
  const ask = ticker?.quotes?.best_ask ? Number(ticker.quotes.best_ask) : null
  const bidSize = ticker?.quotes?.bid_size ?? null
  const askSize = ticker?.quotes?.ask_size ?? null

  const itmBg = inTheMoney ? 'bg-sky-500/[0.06]' : ''
  const held = position && position.net_qty !== 0

  const stats = [
    <Cell key="oi" className={itmBg}>
      {compact(ticker?.oi_contracts)}
    </Cell>,
    <Cell key="vol" className={itmBg}>
      {compact(ticker?.volume)}
    </Cell>,
    <Cell key="iv" className={itmBg}>
      {iv(ticker?.quotes?.mark_iv)}
    </Cell>,
    <Cell key="delta" className={itmBg}>
      {greek(ticker?.greeks?.delta)}
    </Cell>,
  ]

  const quotes = [
    <QuoteCell
      key="bid"
      value={bid}
      size={bidSize}
      tone="bid"
      className={itmBg}
      // Hitting the bid means selling.
      onClick={() => bid !== null && onPick(product, 'sell', bid)}
    />,
    <QuoteCell
      key="ask"
      value={ask}
      size={askSize}
      tone="ask"
      className={`${itmBg} ${held ? 'ring-1 ring-inset ring-amber-500/40' : ''}`}
      // Lifting the ask means buying.
      onClick={() => ask !== null && onPick(product, 'buy', ask)}
    />,
  ]

  return <>{mirrored ? [...quotes, ...stats.reverse()] : [...stats, ...quotes]}</>
}

function Cell({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  return <div className={`num px-1.5 py-1.5 text-right text-zinc-400 ${className}`}>{children}</div>
}

function QuoteCell({
  value,
  size,
  tone,
  onClick,
  className = '',
}: {
  value: number | null
  size: string | null
  tone: 'bid' | 'ask'
  onClick: () => void
  className?: string
}) {
  const colour = tone === 'bid' ? 'text-emerald-400' : 'text-rose-400'
  const hover = tone === 'bid' ? 'hover:bg-emerald-500/15' : 'hover:bg-rose-500/15'

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={value === null}
      title={value === null ? 'No quote' : `${tone === 'bid' ? 'Sell' : 'Buy'} at ${value}`}
      className={`num flex flex-col items-end px-1.5 py-1 leading-tight transition-colors ${hover} disabled:cursor-default disabled:hover:bg-transparent ${className}`}
    >
      <span className={value === null ? 'text-zinc-700' : colour}>{price(value)}</span>
      <span className="text-[9px] text-zinc-600">{compact(size)}</span>
    </button>
  )
}
