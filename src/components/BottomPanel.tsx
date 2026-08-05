import { useState } from 'react'
import type { Product, Ticker } from '../lib/delta'
import { UNDERLYING } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import { shortImRate, valuePosition, type OrderRow, type PositionRow } from '../engine/paper'
import type { FillRow } from '../hooks/useTrading'
import {
  compact,
  dateTime,
  ivShort,
  pct,
  pnlClass,
  price,
  signedUsd,
  timeOfDay,
  usd,
} from '../lib/format'

type Tab = 'positions' | 'orders' | 'history'

interface Props {
  positions: PositionRow[]
  openOrders: OrderRow[]
  fills: FillRow[]
  productsBySymbol: Map<string, Product>
  onClosePosition: (pos: PositionRow, product: Product) => Promise<void>
  onCancelOrder: (orderId: string) => Promise<void>
  onPickSymbol: (product: Product) => void
}

export function BottomPanel({
  positions,
  openOrders,
  fills,
  productsBySymbol,
  onClosePosition,
  onCancelOrder,
  onPickSymbol,
}: Props) {
  const [tab, setTab] = useState<Tab>('positions')

  const tabs: { key: Tab; label: string; count: number }[] = [
    { key: 'positions', label: 'Positions', count: positions.length },
    { key: 'orders', label: 'Open Orders', count: openOrders.length },
    { key: 'history', label: 'Trade History', count: fills.length },
  ]

  return (
    /* As tall as whichever table is showing. Nothing here scrolls: the document
       does. */
    <div className="flex flex-col border-t border-line bg-surface">
      <div className="flex shrink-0 items-center gap-1 border-b border-line px-2">
        {tabs.map((t) => (
          <button
            key={t.key}
            onClick={() => setTab(t.key)}
            className={`relative px-3 py-2 text-xs font-medium transition-colors ${
              tab === t.key ? 'text-ink' : 'text-ink-3 hover:text-ink'
            }`}
          >
            {t.label}
            {t.count > 0 && (
              <span className="num ml-1.5 rounded bg-raised-2 px-1.5 py-0.5 text-[10px] text-ink-2">
                {t.count}
              </span>
            )}
            {tab === t.key && <span className="absolute inset-x-0 -bottom-px h-0.5 bg-brand" />}
          </button>
        ))}
      </div>

      <div className="flex flex-col">
        {tab === 'positions' && (
          <PositionsTable
            positions={positions}
            productsBySymbol={productsBySymbol}
            onClosePosition={onClosePosition}
            onPickSymbol={onPickSymbol}
          />
        )}
        {tab === 'orders' && (
          <OrdersTable
            orders={openOrders}
            productsBySymbol={productsBySymbol}
            onCancelOrder={onCancelOrder}
          />
        )}
        {tab === 'history' && <HistoryTable fills={fills} />}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------

function Empty({ children }: { children: React.ReactNode }) {
  return <div className="px-4 py-8 text-center text-xs text-ink-4">{children}</div>
}

/**
 * A ruled, lifted column — what the chain does to the strike, applied to the
 * action column here. The shadow falls leftward, over the columns it sits beside,
 * which is what makes it read as standing on the table rather than in it.
 *
 * No background of its own, so the row's hover still runs underneath.
 */
// A tight shadow that sits at the rule rather than reaching back across the
// column before it — a wider one washed over the Theta figures next to it.
const WALL = 'border-x border-line shadow-[-2px_0_5px_-3px_#000000aa]'

/**
 * Sticky lives on the `thead` rather than on each cell, so a table can pin more
 * than one row — the positions table pins its totals above its labels.
 */
const alignClass = (align: 'left' | 'right' | 'center') =>
  align === 'left' ? 'text-left' : align === 'center' ? 'text-center' : 'text-right'

function Th({
  children,
  align = 'right',
  walled = false,
}: {
  children: React.ReactNode
  align?: 'left' | 'right' | 'center'
  /** Ruled off on both sides and lifted, as the chain walls the strike column. */
  walled?: boolean
}) {
  return (
    <th
      className={`bg-raised px-2.5 py-1.5 text-[10px] font-semibold tracking-wider text-ink-3 uppercase ${alignClass(
        align,
      )} ${walled ? WALL : ''}`}
    >
      {children}
    </th>
  )
}

/**
 * The red ✕ Delta closes and cancels with. A box rather than a bare glyph, so it
 * reads as a button at 10px, and never a word — the column is too narrow for one
 * and every row's word would be the same.
 */
function KillButton({
  onClick,
  disabled,
  busy,
  title,
}: {
  onClick: () => void
  disabled?: boolean
  busy?: boolean
  title: string
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={title}
      className="rounded border border-neg/70 px-2 py-0.5 text-[11px] leading-none text-neg hover:border-neg hover:bg-neg-muted disabled:opacity-30 disabled:hover:bg-transparent"
    >
      {busy ? '…' : '✕'}
    </button>
  )
}

function PageArrow({
  children,
  onClick,
  disabled,
  label,
}: {
  children: React.ReactNode
  onClick: () => void
  disabled: boolean
  label: string
}) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      aria-label={label}
      className="rounded border border-raised-3 px-2 py-0.5 text-[12px] leading-tight text-ink-2 hover:border-ink-3 hover:text-ink disabled:opacity-30 disabled:hover:border-raised-3 disabled:hover:text-ink-2"
    >
      {children}
    </button>
  )
}

/**
 * Rows, then the pager beneath them. Delta pages every one of these tables.
 *
 * The page size and the page live here so that switching tabs does not carry a
 * page number over to a table that may not have that many rows.
 */
function Paged<T>({
  rows,
  children,
}: {
  rows: T[]
  children: (visible: T[]) => React.ReactNode
}) {
  const [size, setSize] = useState(20)
  const [page, setPage] = useState(0)

  const pages = Math.max(1, Math.ceil(rows.length / size))
  // Clamped rather than reset: deleting the last row of the last page should
  // land you on the new last page, not back at the beginning.
  const current = Math.min(page, pages - 1)
  const start = current * size

  return (
    <div className="flex flex-col">
      {/* No scroll box at all: the rows decide the height and the document
          scrolls to them, so a page of a hundred makes a long page rather than a
          small window onto a hundred rows. */}
      <div>{children(rows.slice(start, start + size))}</div>

      {/* Delta's arrangement: the size selector, then boxed arrows either side of
          the range. The range is the one bright thing here, because it is the
          only part that answers "where am I". */}
      {rows.length > 0 && (
        <div className="flex shrink-0 items-center justify-center gap-2 border-t border-line px-3 py-1.5">
          <select
            value={size}
            onChange={(e) => {
              setSize(Number(e.target.value))
              setPage(0)
            }}
            aria-label="Rows per page"
            className="num rounded border border-raised-3 bg-raised px-2 py-1 text-[11px] text-ink-2 hover:border-ink-3 focus:border-ink-3 focus:outline-none"
          >
            {[10, 20, 50, 100].map((n) => (
              <option key={n} value={n}>
                {n}/ Page
              </option>
            ))}
          </select>

          <PageArrow
            onClick={() => setPage(current - 1)}
            disabled={current === 0}
            label="Previous page"
          >
            ‹
          </PageArrow>
          <span className="num px-1 text-[11px] font-bold text-ink">
            {start + 1} - {Math.min(rows.length, start + size)}
          </span>
          <PageArrow
            onClick={() => setPage(current + 1)}
            disabled={current >= pages - 1}
            label="Next page"
          >
            ›
          </PageArrow>
        </div>
      )}
    </div>
  )
}

function Td({
  children,
  align = 'right',
  className = '',
  colSpan,
  title,
  walled = false,
}: {
  children?: React.ReactNode
  align?: 'left' | 'right' | 'center'
  className?: string
  colSpan?: number
  title?: string
  /**
   * Ruled off on both sides and lifted, as the chain walls the strike column.
   * Not pinned: it scrolls with the table like everything else.
   */
  walled?: boolean
}) {
  return (
    <td
      colSpan={colSpan}
      title={title}
      className={`num px-2.5 py-1.5 ${alignClass(align)} ${walled ? WALL : ''} ${className}`}
    >
      {children}
    </td>
  )
}

/**
 * The full symbol behind a coloured bar, the way Delta prints it —
 * `C-XAUT-4050-020826`, not a reformatting of it, because that string is what a
 * trader reads across the terminal and the API. The bar is the accent: green
 * where the row is long or a call, red where it is short or a put.
 */
function Instrument({
  symbol,
  accent,
  onClick,
}: {
  symbol: string
  accent: 'pos' | 'neg'
  onClick?: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={!onClick}
      title={symbol}
      className="flex items-center gap-2 text-left enabled:hover:underline"
    >
      <span
        aria-hidden
        className={`h-3.5 w-[3px] shrink-0 rounded-full ${accent === 'pos' ? 'bg-pos' : 'bg-neg'}`}
      />
      <span className="num font-medium text-ink">{symbol}</span>
    </button>
  )
}

// ---------------------------------------------------------------------------

function PositionsTable({
  positions,
  productsBySymbol,
  onClosePosition,
  onPickSymbol,
}: {
  positions: PositionRow[]
  productsBySymbol: Map<string, Product>
  onClosePosition: (pos: PositionRow, product: Product) => Promise<void>
  onPickSymbol: (product: Product) => void
}) {
  useMarketTick()
  const [closing, setClosing] = useState<string | null>(null)
  const spot = market.spot

  if (positions.length === 0) return <Empty>No open positions. Click a bid or ask on the chain to trade.</Empty>

  // Portfolio totals. Only the greeks and the money add up across rows — an
  // average entry or a percentage would not, so those columns stay blank in the
  // footer rather than carrying a number that means nothing.
  const imRateFor = (symbol: string) => {
    const p = productsBySymbol.get(symbol)
    return p ? shortImRate(p) : undefined
  }

  const totals = positions.reduce(
    (acc, pos) => {
      const t = market.get(pos.symbol)
      const v = valuePosition(pos, t, spot, imRateFor(pos.symbol))
      const g = positionGreeks(pos, t)
      return {
        notional: acc.notional + spot * Number(pos.contract_value) * Math.abs(pos.net_qty),
        unrealized: acc.unrealized + (v.unrealized ?? 0),
        margin: acc.margin + v.marginBlocked,
        delta: acc.delta + (g.delta ?? 0),
        gamma: acc.gamma + (g.gamma ?? 0),
        vega: acc.vega + (g.vega ?? 0),
        theta: acc.theta + (g.theta ?? 0),
      }
    },
    { notional: 0, unrealized: 0, margin: 0, delta: 0, gamma: 0, vega: 0, theta: 0 },
  )

  // Columns follow Delta's positions table: symbol, size in the underlying,
  // notional, entry, index, mark, margin, then UPNL with its percentage beneath
  // it in one cell rather than spread over two. Cashflows and Share are theirs
  // and not wanted. The greeks and the totals row are ours.
  return (
    <Paged rows={positions}>
      {(visible) => (
    <table className="w-full text-[12px]">
      <thead className="sticky top-0 z-10">
        {/* Above the labels, not below the rows. Once the table pages, a footer
            total sits under one page and reads as that page's — these are the
            whole book's, every position, whichever page is showing. */}
        <tr className="border-b border-line bg-raised-2">
          <Td align="left" className="text-[10px] font-semibold tracking-wider text-ink-2 uppercase">
            Σ Total · {positions.length}
          </Td>
          <Td />
          <Td className="text-ink-2">{usd(totals.notional)}</Td>
          <Td colSpan={3} />
          <Td className="text-ink-2">{usd(totals.margin, 4)}</Td>
          <Td className={`font-semibold ${pnlClass(totals.unrealized)}`}>
            {signedUsd(totals.unrealized, 4)}
          </Td>
          <Td className="font-semibold text-ink">{totals.delta.toFixed(4)}</Td>
          <Td className="font-semibold text-ink">{totals.gamma.toFixed(6)}</Td>
          <Td className="font-semibold text-ink">{totals.vega.toFixed(4)}</Td>
          <Td className="font-semibold text-ink">{totals.theta.toFixed(4)}</Td>
          <Td walled />
        </tr>
        <tr>
          <Th align="left">Symbol</Th>
          <Th>Size</Th>
          <Th>Notional</Th>
          <Th>Entry Price</Th>
          <Th>Index Price</Th>
          <Th>Mark Price</Th>
          <Th>Margin</Th>
          <Th>UPNL</Th>
          <Th>Delta</Th>
          <Th>Gamma</Th>
          <Th>Vega</Th>
          <Th>Theta</Th>
          <Th align="center" walled>Action</Th>
        </tr>
      </thead>
      <tbody>
        {visible.map((pos) => {
          const ticker = market.get(pos.symbol)
          const product = productsBySymbol.get(pos.symbol)
          const v = valuePosition(pos, ticker, spot, product ? shortImRate(product) : undefined)
          const isLong = pos.net_qty > 0
          const g = positionGreeks(pos, ticker)
          const cv = Number(pos.contract_value)
          const lots = Math.abs(pos.net_qty)

          return (
            <tr key={pos.id} className="border-b border-line hover:bg-raised">
              <Td align="left">
                <Instrument
                  symbol={pos.symbol}
                  accent={isLong ? 'pos' : 'neg'}
                  onClick={product ? () => onPickSymbol(product) : undefined}
                />
              </Td>
              {/* Delta sizes in the underlying, not in contracts. The contract
                  count is what you trade in, so it rides along in the title. */}
              <Td
                className={isLong ? 'text-pos' : 'text-neg'}
                title={`${lots} ${lots === 1 ? 'contract' : 'contracts'}`}
              >
                {isLong ? '+' : ''}
                {(pos.net_qty * cv).toFixed(3)} {UNDERLYING}
              </Td>
              <Td className="text-ink-2">{usd(spot * cv * lots)}</Td>
              <Td className="text-ink">{price(pos.avg_entry_price)}</Td>
              <Td className="text-ink-2">{price(spot)}</Td>
              <Td>
                {v.mark !== null ? (
                  <>
                    <div className="text-ink">{price(v.mark)}</div>
                    <div className="text-[10px] text-ink-3">
                      {ivShort(ticker?.quotes?.mark_iv)}
                    </div>
                  </>
                ) : (
                  <span className="text-ink-3" title="No mark published">
                    —
                  </span>
                )}
              </Td>
              {/* Delta shows no margin against a long, because buying one debits
                  the premium outright. Ours blocks that premium instead, so the
                  figure is real here and reduces what is available. */}
              <Td className="text-ink-2">
                {usd(v.marginBlocked, 4)}
                {isLong && <div className="text-[10px] text-ink-3">premium</div>}
              </Td>
              <Td className={pnlClass(v.unrealized)}>
                <div className="font-semibold">{signedUsd(v.unrealized, 4)}</div>
                <div className="text-[10px]">{pct(v.unrealizedPct)}</div>
              </Td>
              <Td className="text-ink-2">{greekCell(g.delta, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.gamma, 6)}</Td>
              <Td className="text-ink-2">{greekCell(g.vega, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.theta, 4)}</Td>
              <Td align="center" walled>
                <KillButton
                  disabled={!product || closing === pos.id}
                  busy={closing === pos.id}
                  onClick={async () => {
                    if (!product) return
                    setClosing(pos.id)
                    try {
                      await onClosePosition(pos, product)
                    } finally {
                      setClosing(null)
                    }
                  }}
                  title={product ? 'Close at market' : 'Contract not in the loaded chain'}
                />
              </Td>
            </tr>
          )
        })}
      </tbody>

    </table>
      )}
    </Paged>
  )
}

/**
 * A position's greeks: the per-contract figure scaled by signed size and
 * contract value, so a short reads negative and the column sums to the book's
 * exposure. Null where the venue has published no greek for that leg.
 */
function positionGreeks(pos: PositionRow, ticker: Ticker | undefined) {
  const cv = Number(pos.contract_value)
  const scale = (v: string | null | undefined) => {
    if (v === null || v === undefined || v === '') return null
    const n = Number(v)
    return Number.isFinite(n) ? n * pos.net_qty * cv : null
  }
  const g = ticker?.greeks
  return {
    delta: scale(g?.delta),
    gamma: scale(g?.gamma),
    vega: scale(g?.vega),
    theta: scale(g?.theta),
  }
}

const greekCell = (v: number | null, dp: number) => (v === null ? '—' : v.toFixed(dp))

// ---------------------------------------------------------------------------

function OrdersTable({
  orders,
  productsBySymbol,
  onCancelOrder,
}: {
  orders: OrderRow[]
  productsBySymbol: Map<string, Product>
  onCancelOrder: (orderId: string) => Promise<void>
}) {
  useMarketTick()
  const [cancelling, setCancelling] = useState<string | null>(null)

  if (orders.length === 0) {
    return (
      <Empty>
        No open orders. The ticket places market orders only, so nothing rests here — any
        limit order left from before can still be cancelled from this tab.
      </Empty>
    )
  }

  return (
    <Paged rows={orders}>
      {(visible) => (
    <table className="w-full text-[12px]">
      <thead className="sticky top-0 z-10">
        <tr>
          <Th align="left">Time</Th>
          <Th align="left">Instrument</Th>
          <Th align="left">Side</Th>
          <Th align="left">Type</Th>
          <Th>Qty</Th>
          <Th>Limit</Th>
          <Th>Distance</Th>
          <Th align="center" walled>Action</Th>
        </tr>
      </thead>
      <tbody>
        {visible.map((o) => {
          const ticker = market.get(o.symbol)
          const limit = Number(o.limit_price)
          // How far the relevant side of the book has to travel to fill this order.
          const reference =
            o.side === 'buy' ? ticker?.quotes?.best_ask : ticker?.quotes?.best_bid
          const gap = reference ? (o.side === 'buy' ? Number(reference) - limit : limit - Number(reference)) : null

          return (
            <tr key={o.id} className="border-b border-line hover:bg-raised">
              <Td align="left" className="text-ink-3">{timeOfDay(o.created_at)}</Td>
              <Td align="left">
                <Instrument symbol={o.symbol} accent={o.side === 'buy' ? 'pos' : 'neg'} />
              </Td>
              <Td align="left" className={o.side === 'buy' ? 'text-pos' : 'text-neg'}>
                {o.side.toUpperCase()}
              </Td>
              <Td align="left" className="text-ink-2 capitalize">
                {o.order_type}
                {o.reduce_only && <span className="ml-1 text-[10px] text-brand-text">RO</span>}
              </Td>
              <Td className="text-ink">{o.qty}</Td>
              <Td className="text-ink">{price(o.limit_price)}</Td>
              <Td className={gap !== null && gap <= 0 ? 'text-pos' : 'text-ink-3'}>
                {gap === null ? '—' : gap <= 0 ? 'crossing' : price(gap)}
              </Td>
              <Td align="center" walled>
                <KillButton
                  disabled={cancelling === o.id || !productsBySymbol.has(o.symbol)}
                  busy={cancelling === o.id}
                  onClick={async () => {
                    setCancelling(o.id)
                    try {
                      await onCancelOrder(o.id)
                    } finally {
                      setCancelling(null)
                    }
                  }}
                  title="Cancel this order"
                />
              </Td>
            </tr>
          )
        })}
      </tbody>
    </table>
      )}
    </Paged>
  )
}

// ---------------------------------------------------------------------------

function HistoryTable({ fills }: { fills: FillRow[] }) {
  if (fills.length === 0) return <Empty>No trades yet.</Empty>

  return (
    <Paged rows={fills}>
      {(visible) => (
    <table className="w-full text-[12px]">
      <thead className="sticky top-0 z-10">
        <tr>
          <Th align="left">Time</Th>
          <Th align="left">Instrument</Th>
          <Th align="left">Side</Th>
          <Th align="left">Type</Th>
          <Th>Qty</Th>
          <Th>Price</Th>
          <Th>Premium</Th>
          <Th>Notional</Th>
          <Th>Fee</Th>
          <Th>Realized</Th>
        </tr>
      </thead>
      <tbody>
        {visible.map((f) => {
          const realized = Number(f.realized_pnl)
          return (
            <tr key={f.id} className="border-b border-line hover:bg-raised">
              <Td align="left" className="text-ink-3">{dateTime(f.created_at)}</Td>
              <Td align="left">
                <Instrument symbol={f.symbol} accent={f.side === 'buy' ? 'pos' : 'neg'} />
              </Td>
              <Td align="left" className={f.side === 'buy' ? 'text-pos' : 'text-neg'}>
                {f.side.toUpperCase()}
              </Td>
              <Td align="left" className="text-ink-3 capitalize">{f.order_type}</Td>
              <Td className="text-ink">{compact(f.qty)}</Td>
              <Td className="text-ink">{price(f.price)}</Td>
              <Td className="text-ink-2">{usd(Number(f.premium), 4)}</Td>
              <Td className="text-ink-3">{usd(Number(f.notional))}</Td>
              <Td className="text-ink-3">{usd(Number(f.fee), 4)}</Td>
              <Td className={realized === 0 ? 'text-ink-4' : pnlClass(realized)}>
                {realized === 0 ? '—' : signedUsd(realized, 4)}
              </Td>
            </tr>
          )
        })}
      </tbody>
    </table>
      )}
    </Paged>
  )
}
