import { useState } from 'react'
import type { Product, Ticker } from '../lib/delta'
import { formatExpiry } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import { valuePosition, type OrderRow, type PositionRow } from '../engine/paper'
import type { FillRow } from '../hooks/useTrading'
import { compact, dateTime, pct, pnlClass, price, signedUsd, timeOfDay, usd } from '../lib/format'

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
    <div className="flex min-h-0 flex-col border-t border-line bg-surface">
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

      <div className="min-h-0 flex-1 overflow-auto">
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

function Th({ children, align = 'right' }: { children: React.ReactNode; align?: 'left' | 'right' }) {
  return (
    <th
      className={`sticky top-0 z-10 bg-raised px-2.5 py-1.5 text-[10px] font-semibold tracking-wider text-ink-3 uppercase ${
        align === 'left' ? 'text-left' : 'text-right'
      }`}
    >
      {children}
    </th>
  )
}

function Td({
  children,
  align = 'right',
  className = '',
  colSpan,
}: {
  children?: React.ReactNode
  align?: 'left' | 'right'
  className?: string
  colSpan?: number
}) {
  return (
    <td
      colSpan={colSpan}
      className={`num px-2.5 py-1.5 ${align === 'left' ? 'text-left' : 'text-right'} ${className}`}
    >
      {children}
    </td>
  )
}

/** `C-XAUT-4040-300726` rendered as a compact, readable instrument label. */
function Instrument({
  symbol,
  contractType,
  strike,
  expiryLabel,
  onClick,
}: {
  symbol: string
  contractType: string
  strike: string | number
  expiryLabel: string
  onClick?: () => void
}) {
  const isCall = contractType === 'call_options'
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={!onClick}
      title={symbol}
      className="flex items-center gap-1.5 text-left enabled:hover:underline"
    >
      <span className="num font-medium text-ink">{Number(strike).toLocaleString()}</span>
      <span
        className={`rounded px-1 py-px text-[10px] font-bold ${
          isCall ? 'bg-pos-muted text-pos' : 'bg-neg-muted text-neg'
        }`}
      >
        {isCall ? 'C' : 'P'}
      </span>
      <span className="text-[10px] text-ink-3">{formatExpiry(expiryLabel)}</span>
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
  const totals = positions.reduce(
    (acc, pos) => {
      const t = market.get(pos.symbol)
      const v = valuePosition(pos, t, spot)
      const g = positionGreeks(pos, t)
      return {
        value: acc.value + (v.currentValue ?? 0),
        unrealized: acc.unrealized + (v.unrealized ?? 0),
        margin: acc.margin + v.marginBlocked,
        delta: acc.delta + (g.delta ?? 0),
        gamma: acc.gamma + (g.gamma ?? 0),
        vega: acc.vega + (g.vega ?? 0),
        theta: acc.theta + (g.theta ?? 0),
      }
    },
    { value: 0, unrealized: 0, margin: 0, delta: 0, gamma: 0, vega: 0, theta: 0 },
  )

  return (
    <table className="w-full text-[12px]">
      <thead>
        <tr>
          <Th align="left">Instrument</Th>
          <Th>Size</Th>
          <Th>Entry</Th>
          <Th>Mark</Th>
          <Th>Value</Th>
          <Th>Unrealized</Th>
          <Th>%</Th>
          <Th>Margin</Th>
          <Th>Delta</Th>
          <Th>Gamma</Th>
          <Th>Vega</Th>
          <Th>Theta</Th>
          <Th align="right">Action</Th>
        </tr>
      </thead>
      <tbody>
        {positions.map((pos) => {
          const ticker = market.get(pos.symbol)
          const v = valuePosition(pos, ticker, spot)
          const product = productsBySymbol.get(pos.symbol)
          const isLong = pos.net_qty > 0
          const g = positionGreeks(pos, ticker)

          return (
            <tr key={pos.id} className="border-b border-line hover:bg-raised">
              <Td align="left">
                <Instrument
                  symbol={pos.symbol}
                  contractType={pos.contract_type}
                  strike={pos.strike_price}
                  expiryLabel={pos.expiry_label}
                  onClick={product ? () => onPickSymbol(product) : undefined}
                />
              </Td>
              <Td className={isLong ? 'text-pos' : 'text-neg'}>
                {isLong ? '+' : ''}
                {pos.net_qty}
              </Td>
              <Td className="text-ink">{price(pos.avg_entry_price)}</Td>
              <Td className="text-ink" >
                {v.mark !== null ? (
                  <span title="Delta's fair mark price">
                    {price(v.mark)}
                  </span>
                ) : (
                  <span className="text-ink-4" title="No quote on the exit side">—</span>
                )}
              </Td>
              <Td className="text-ink-2">{usd(v.currentValue, 4)}</Td>
              <Td className={`font-semibold ${pnlClass(v.unrealized)}`}>{signedUsd(v.unrealized, 4)}</Td>
              <Td className={pnlClass(v.unrealized)}>{pct(v.unrealizedPct)}</Td>
              <Td className="text-ink-2">{usd(v.marginBlocked, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.delta, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.gamma, 6)}</Td>
              <Td className="text-ink-2">{greekCell(g.vega, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.theta, 4)}</Td>
              <Td align="right">
                <button
                  disabled={!product || closing === pos.id}
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
                  className="rounded border border-raised-3 px-2 py-0.5 text-[10px] text-ink hover:border-neg hover:text-neg disabled:opacity-40"
                >
                  {closing === pos.id ? '…' : 'Close'}
                </button>
              </Td>
            </tr>
          )
        })}
      </tbody>

      <tfoot>
        <tr className="border-t border-line bg-raised">
          <Td align="left" className="text-[10px] font-semibold tracking-wider text-ink-3 uppercase">
            Total · {positions.length}
          </Td>
          {/* Size, entry, mark and the percentage do not sum to anything. */}
          <Td colSpan={3} />
          <Td className="text-ink-2">{usd(totals.value, 4)}</Td>
          <Td className={`font-semibold ${pnlClass(totals.unrealized)}`}>
            {signedUsd(totals.unrealized, 4)}
          </Td>
          <Td />
          <Td className="text-ink-2">{usd(totals.margin, 4)}</Td>
          <Td className="font-semibold text-ink">{totals.delta.toFixed(4)}</Td>
          <Td className="font-semibold text-ink">{totals.gamma.toFixed(6)}</Td>
          <Td className="font-semibold text-ink">{totals.vega.toFixed(4)}</Td>
          <Td className="font-semibold text-ink">{totals.theta.toFixed(4)}</Td>
          <Td />
        </tr>
      </tfoot>
    </table>
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
    <table className="w-full text-[12px]">
      <thead>
        <tr>
          <Th align="left">Time</Th>
          <Th align="left">Instrument</Th>
          <Th align="left">Side</Th>
          <Th align="left">Type</Th>
          <Th>Qty</Th>
          <Th>Limit</Th>
          <Th>Distance</Th>
          <Th align="right">Action</Th>
        </tr>
      </thead>
      <tbody>
        {orders.map((o) => {
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
                <Instrument
                  symbol={o.symbol}
                  contractType={o.contract_type}
                  strike={o.strike_price}
                  expiryLabel={o.expiry_label}
                />
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
              <Td align="right">
                <button
                  disabled={cancelling === o.id || !productsBySymbol.has(o.symbol)}
                  onClick={async () => {
                    setCancelling(o.id)
                    try {
                      await onCancelOrder(o.id)
                    } finally {
                      setCancelling(null)
                    }
                  }}
                  className="rounded border border-raised-3 px-2 py-0.5 text-[10px] text-ink hover:border-neg hover:text-neg disabled:opacity-40"
                >
                  {cancelling === o.id ? '…' : 'Cancel'}
                </button>
              </Td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}

// ---------------------------------------------------------------------------

function HistoryTable({ fills }: { fills: FillRow[] }) {
  if (fills.length === 0) return <Empty>No trades yet.</Empty>

  return (
    <table className="w-full text-[12px]">
      <thead>
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
        {fills.map((f) => {
          const realized = Number(f.realized_pnl)
          return (
            <tr key={f.id} className="border-b border-line hover:bg-raised">
              <Td align="left" className="text-ink-3">{dateTime(f.created_at)}</Td>
              <Td align="left">
                <span className="num font-medium text-ink">
                  {Number(f.strike_price).toLocaleString()}
                </span>
                <span
                  className={`ml-1.5 rounded px-1 py-px text-[10px] font-bold ${
                    f.contract_type === 'call_options'
                      ? 'bg-pos-muted text-pos'
                      : 'bg-neg-muted text-neg'
                  }`}
                >
                  {f.contract_type === 'call_options' ? 'C' : 'P'}
                </span>
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
  )
}
