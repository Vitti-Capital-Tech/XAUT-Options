import { useEffect, useMemo, useState } from 'react'
import type { Product } from '../lib/delta'
import { formatExpiry, parseSymbol } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import {
  bestAsk,
  bestBid,
  previewOrder,
  type OrderType,
  type PositionRow,
  type Side,
} from '../engine/paper'
import { price, usd } from '../lib/format'

export interface TicketRequest {
  product: Product
  side: Side
  presetPrice: number | null
}

interface Props {
  request: TicketRequest
  position: PositionRow | undefined
  available: number
  onClose: () => void
  onSubmit: (args: {
    product: Product
    side: Side
    orderType: OrderType
    qty: number
    limitPrice: number | null
  }) => Promise<void>
}

const QTY_PRESETS = [1, 10, 100, 1000]

export function OrderTicket({ request, position, available, onClose, onSubmit }: Props) {
  const { product } = request
  useMarketTick()

  const [side, setSide] = useState<Side>(request.side)
  const [orderType, setOrderType] = useState<OrderType>('market')
  const [qtyText, setQtyText] = useState('1')
  const [limitText, setLimitText] = useState(
    request.presetPrice !== null ? String(request.presetPrice) : '',
  )
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  // Reopening the ticket on a different contract resets the form.
  useEffect(() => {
    setSide(request.side)
    setOrderType('market')
    setQtyText('1')
    setLimitText(request.presetPrice !== null ? String(request.presetPrice) : '')
    setSubmitError(null)
  }, [request])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const ticker = market.get(product.symbol)
  const spot = market.spot
  const parsed = parseSymbol(product.symbol)
  const bid = bestBid(ticker)
  const ask = bestAsk(ticker)

  const qty = Number(qtyText)
  const limitPrice = limitText === '' ? null : Number(limitText)

  const preview = useMemo(
    () =>
      previewOrder(
        { product, side, orderType, qty, limitPrice },
        ticker,
        spot,
        position,
        available,
      ),
    // `market.spot` and the ticker mutate in place, so the tick from
    // useMarketTick above is what actually drives recomputation.
    [product, side, orderType, qty, limitPrice, ticker, spot, position, available],
  )

  const netQty = position?.net_qty ?? 0
  const signed = side === 'buy' ? qty : -qty
  const reduces = netQty !== 0 && Math.sign(netQty) !== Math.sign(signed)

  const canSubmit = !submitting && preview.error === null && Number.isInteger(qty) && qty > 0

  const submit = async () => {
    if (!canSubmit) return
    setSubmitting(true)
    setSubmitError(null)
    try {
      await onSubmit({ product, side, orderType, qty, limitPrice: orderType === 'limit' ? limitPrice : null })
      onClose()
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'Order failed')
      setSubmitting(false)
    }
  }

  const isCall = product.contract_type === 'call_options'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm overflow-hidden rounded-lg border border-raised-3 bg-raised shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between border-b border-line px-4 py-3">
          <div>
            <div className="flex items-center gap-2">
              <span className="num text-sm font-semibold text-ink">
                {parsed?.strike.toLocaleString()}
              </span>
              <span
                className={`rounded px-1.5 py-0.5 text-[10px] font-bold ${
                  isCall ? 'bg-pos-muted text-pos' : 'bg-neg-muted text-neg'
                }`}
              >
                {isCall ? 'CALL' : 'PUT'}
              </span>
            </div>
            <div className="mt-0.5 text-[12px] text-ink-3">
              XAUT · {parsed ? formatExpiry(parsed.expiry) : ''}
            </div>
          </div>
          <button
            onClick={onClose}
            className="rounded p-1 text-ink-3 hover:bg-raised-2 hover:text-ink"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="flex divide-x divide-line border-b border-line bg-sub text-center text-[12px]">
          <div className="flex-1 py-2">
            <div className="text-ink-4">Bid</div>
            <div className="num font-semibold text-pos">{price(bid)}</div>
          </div>
          <div className="flex-1 py-2">
            <div className="text-ink-4">Ask</div>
            <div className="num font-semibold text-neg">{price(ask)}</div>
          </div>
          <div className="flex-1 py-2">
            <div className="text-ink-4">Spot</div>
            <div className="num font-semibold text-warn">{price(spot)}</div>
          </div>
        </div>

        <div className="space-y-3 p-4">
          <div className="grid grid-cols-2 gap-2">
            <button
              onClick={() => setSide('buy')}
              className={`rounded py-2 text-sm font-semibold transition-colors ${
                side === 'buy'
                  ? 'bg-pos-solid text-white'
                  : 'bg-raised-2 text-ink-2 hover:bg-raised-3 hover:text-ink'
              }`}
            >
              Buy / Long
            </button>
            <button
              onClick={() => setSide('sell')}
              className={`rounded py-2 text-sm font-semibold transition-colors ${
                side === 'sell'
                  ? 'bg-neg-solid text-white'
                  : 'bg-raised-2 text-ink-2 hover:bg-raised-3 hover:text-ink'
              }`}
            >
              Sell / Short
            </button>
          </div>

          <div className="flex gap-1 rounded bg-sub p-0.5">
            {(['market', 'limit'] as const).map((t) => (
              <button
                key={t}
                onClick={() => setOrderType(t)}
                className={`flex-1 rounded py-1 text-xs font-medium capitalize transition-colors ${
                  orderType === t ? 'bg-raised-3 text-ink' : 'text-ink-3 hover:text-ink'
                }`}
              >
                {t}
              </button>
            ))}
          </div>

          {orderType === 'limit' && (
            <Field label="Limit price" hint={`Tick ${product.tick_size}`}>
              <input
                type="number"
                step={product.tick_size}
                value={limitText}
                onChange={(e) => setLimitText(e.target.value)}
                className="num w-full rounded border border-raised-3 bg-surface px-2 py-1.5 text-right text-sm text-ink focus:border-ink-3 focus:outline-none"
              />
            </Field>
          )}

          <Field label="Quantity" hint="lots">
            <input
              type="number"
              min={1}
              step={1}
              value={qtyText}
              onChange={(e) => setQtyText(e.target.value)}
              onFocus={(e) => e.target.select()}
              autoFocus
              className="num w-full rounded border border-raised-3 bg-surface px-2 py-1.5 text-right text-sm text-ink focus:border-ink-3 focus:outline-none"
            />
          </Field>

          <div className="flex gap-1.5">
            {QTY_PRESETS.map((n) => (
              <button
                key={n}
                onClick={() => setQtyText(String(n))}
                className="num flex-1 rounded border border-raised-3 py-1 text-[12px] text-ink-2 hover:border-ink-3 hover:text-ink"
              >
                {n}
              </button>
            ))}
            {netQty !== 0 && (
              <button
                onClick={() => {
                  setQtyText(String(Math.abs(netQty)))
                  setSide(netQty > 0 ? 'sell' : 'buy')
                }}
                className="flex-1 rounded border border-gold py-1 text-[12px] text-warn hover:border-warn"
                title={`Flatten ${Math.abs(netQty)} lots`}
              >
                Close
              </button>
            )}
          </div>

          <dl className="space-y-1 rounded bg-sub p-2.5 text-[12px]">
            <Row label={orderType === 'market' ? 'Est. fill' : 'Fills at'}>
              <span className="num text-ink">
                {preview.fillPrice !== null ? price(preview.fillPrice) : 'Resting'}
              </span>
            </Row>
            <Row label="Premium">
              <span className="num text-ink">{usd(preview.premium, 4)}</span>
            </Row>
            <Row label="Notional">
              <span className="num text-ink-2">{usd(preview.notional)}</span>
            </Row>
            <Row label="Est. fee">
              <span className="num text-ink-2">{usd(preview.fee, 4)}</span>
            </Row>
            <Row label={reduces ? 'Margin released' : 'Margin required'}>
              <span className="num text-ink">
                {reduces ? '—' : usd(preview.marginRequired, 4)}
              </span>
            </Row>
            <Row label="Available">
              <span className="num text-ink-2">{usd(available)}</span>
            </Row>
            {netQty !== 0 && (
              <Row label="Current position">
                <span className={`num ${netQty > 0 ? 'text-pos' : 'text-neg'}`}>
                  {netQty > 0 ? '+' : ''}
                  {netQty} lots @ {price(position!.avg_entry_price)}
                </span>
              </Row>
            )}
          </dl>

          {preview.warning && !preview.error && (
            <p className="rounded bg-warn-muted px-2 py-1.5 text-[12px] text-warn">
              {preview.warning}
            </p>
          )}
          {(preview.error || submitError) && (
            <p className="rounded bg-neg-muted px-2 py-1.5 text-[12px] text-neg">
              {submitError ?? preview.error}
            </p>
          )}

          <button
            onClick={submit}
            disabled={!canSubmit}
            className={`w-full rounded py-2.5 text-sm font-semibold transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
              side === 'buy'
                ? 'bg-pos-solid text-white hover:bg-pos-hover'
                : 'bg-neg-solid text-white hover:bg-neg-hover'
            }`}
          >
            {submitting
              ? 'Placing…'
              : `${side === 'buy' ? 'Buy' : 'Sell'} ${qty > 0 ? qty : ''} ${
                  orderType === 'limit' && preview.fillPrice === null ? '(rest)' : ''
                }`.trim()}
          </button>

          <p className="text-center text-[10px] text-ink-4">
            Paper trade — no real order is sent to Delta Exchange
          </p>
        </div>
      </div>
    </div>
  )
}

function Field({
  label,
  hint,
  children,
}: {
  label: string
  hint?: string
  children: React.ReactNode
}) {
  return (
    <label className="block">
      <div className="mb-1 flex items-baseline justify-between">
        <span className="text-[12px] font-medium text-ink-2">{label}</span>
        {hint && <span className="text-[10px] text-ink-4">{hint}</span>}
      </div>
      {children}
    </label>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between">
      <dt className="text-ink-3">{label}</dt>
      <dd>{children}</dd>
    </div>
  )
}
