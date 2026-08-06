import { useEffect, useMemo, useState } from 'react'
import type { Product } from '../lib/delta'
import { UNDERLYING, formatExpiry, parseSymbol } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import { bestAsk, bestBid, previewOrder, type OrderType, type PositionRow, type Side } from '../engine/paper'
import { price, usd } from '../lib/format'

export interface TicketRequest {
  product: Product
  side: Side
  /**
   * The price that was clicked on the chain. Market orders cross the touch, so
   * this no longer seeds anything — it is kept because it records which side of
   * the book the click came from, and the estimated fill is checked against it.
   */
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

/** Delta sizes by fraction of margin, not by round lots. */
const PCTS = [10, 25, 50, 75, 100]

/**
 * The order ticket, laid out as Delta lays theirs out.
 *
 * Market only, deliberately. Resting orders are matched by a loop in this very
 * browser, so a limit or a stop would only work while the tab stayed open —
 * which is precisely when you would not need it. Offering one would be
 * promising something we cannot keep. If the fill engine ever moves to the
 * database, where the settlement cron already lives, they become worth having.
 *
 * Absent for the same reason: Reduce Only, and bracket TP/SL. A Reduce Only box
 * that nothing enforces is worse than no box at all.
 */
export function OrderTicket({ request, position, available, onClose, onSubmit }: Props) {
  const { product } = request
  useMarketTick()

  const [side, setSide] = useState<Side>(request.side)
  const [qtyText, setQtyText] = useState('1')
  const [details, setDetails] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  // Reopening the ticket on a different contract resets the form.
  useEffect(() => {
    setSide(request.side)
    setQtyText('1')
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

  // The field reads in the underlying now — one Qty is one XAUT — while the
  // engine still counts lots, so we convert on the way down. One lot is the
  // contract value (0.001 XAUT), which is also the smallest order; `effective`
  // is what the rounded lot count actually comes to, in case a typed figure did
  // not land on a whole lot.
  const lotSize = Number(product.contract_value)
  const qtyXaut = Number(qtyText)
  const lots = Number.isFinite(qtyXaut) ? Math.max(0, Math.round(qtyXaut / lotSize)) : 0
  const effectiveXaut = lots * lotSize

  const preview = useMemo(
    () =>
      previewOrder({ product, side, orderType: 'market', qty: lots, limitPrice: null }, ticker, spot, position, available),
    // `market.spot` and the ticker mutate in place, so the tick from
    // useMarketTick above is what actually drives recomputation.
    [product, side, lots, ticker, spot, position, available],
  )

  const netQty = position?.net_qty ?? 0
  const signed = side === 'buy' ? lots : -lots
  const reduces = netQty !== 0 && Math.sign(netQty) !== Math.sign(signed)

  // What one lot costs in margin, so the percentage buttons can size against
  // the balance the way Delta's do. Priced at one lot rather than derived from
  // the current quantity, so the buttons do not drift as the field changes.
  const perLot = useMemo(
    () =>
      previewOrder(
        { product, side, orderType: 'market', qty: 1, limitPrice: null },
        ticker,
        spot,
        position,
        available,
      ).marginRequired,
    [product, side, ticker, spot, position, available],
  )

  // Closing an existing position is bounded by the position, not the balance.
  const maxLots = reduces
    ? Math.abs(netQty)
    : perLot > 0
      ? Math.floor(available / perLot)
      : 0

  // The field's own stepper, so the chevrons can be grey rather than the white
  // pair the browser draws. Steps by one XAUT, and never below a single lot.
  const step = (byXaut: number) => {
    const from = Number.isFinite(qtyXaut) ? qtyXaut : 0
    setQtyText(fmtQty(Math.max(lotSize, from + byXaut)))
  }

  const setPct = (p: number) => {
    // Size in lots against the balance, then show it back in the underlying.
    const n = Math.max(1, Math.floor((maxLots * p) / 100))
    setQtyText(fmtQty(n * lotSize))
  }

  const canSubmit = !submitting && preview.error === null && lots >= 1

  const submit = async () => {
    if (!canSubmit) return
    setSubmitting(true)
    setSubmitError(null)
    try {
      await onSubmit({ product, side, orderType: 'market', qty: lots, limitPrice: null })
      onClose()
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'Order failed')
      setSubmitting(false)
    }
  }

  const isCall = product.contract_type === 'call_options'
  const buying = side === 'buy'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm overflow-hidden rounded-lg border border-raised-3 bg-surface shadow-delta-lg"
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
              {UNDERLYING} · {parsed ? formatExpiry(parsed.expiry) : ''}
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

        {/* Delta's ticket has no quote strip because their chain is beside it.
            Ours covers the chain, so it earns its place — quietly. */}
        <div className="flex items-baseline gap-4 border-b border-line px-4 py-2 text-[11px]">
          <span className="text-ink-3">
            Bid <span className="num text-pos">{price(bid)}</span>
          </span>
          <span className="text-ink-3">
            Ask <span className="num text-neg">{price(ask)}</span>
          </span>
          <span className="ml-auto text-ink-3">
            Spot <span className="num text-brand-text">{price(spot)}</span>
          </span>
        </div>

        <div className="space-y-3 p-4">
          {/* Delta's own arrangement: the side chosen first, on two tabs that
              carry the colour of the trade. */}
          <div className="grid grid-cols-2 gap-2">
            <button
              onClick={() => setSide('buy')}
              className={`rounded border py-2 text-sm font-semibold transition-colors ${
                buying
                  ? 'border-pos-solid bg-pos-muted text-pos'
                  : 'border-raised-3 text-ink-3 hover:border-ink-3 hover:text-ink'
              }`}
            >
              Buy
            </button>
            <button
              onClick={() => setSide('sell')}
              className={`rounded border py-2 text-sm font-semibold transition-colors ${
                !buying
                  ? 'border-neg-solid bg-neg-muted text-neg'
                  : 'border-raised-3 text-ink-3 hover:border-ink-3 hover:text-ink'
              }`}
            >
              Sell
            </button>
          </div>

          {/* Where Delta's Limit / Market / Stop Limit tabs sit. One order type
              needs no tabs, but it should still say which one it is. */}
          <div className="flex items-baseline gap-3">
            <span className="border-b-2 border-brand-text pb-1 text-[13px] font-bold text-ink">
              Market
            </span>
            <span className="text-[10px] text-ink-3">
              crosses the {buying ? 'ask' : 'bid'}
            </span>
          </div>

          <div>
            <div className="flex items-center rounded border border-raised-3 bg-raised focus-within:border-ink-3">
              <input
                type="number"
                min={lotSize}
                step={lotSize}
                value={qtyText}
                onChange={(e) => setQtyText(e.target.value)}
                onFocus={(e) => e.target.select()}
                autoFocus
                placeholder="Enter Quantity"
                aria-label="Quantity in XAUT"
                className="num step-own min-w-0 flex-1 bg-transparent px-2.5 py-2 text-sm text-ink placeholder:text-ink-3 focus:outline-none"
              />
              <div className="flex flex-col justify-center">
                <button
                  type="button"
                  onClick={() => step(1)}
                  aria-label="Increase quantity"
                  className="px-1 text-[7px] leading-none text-ink-3 hover:text-ink"
                >
                  ▲
                </button>
                <button
                  type="button"
                  onClick={() => step(-1)}
                  aria-label="Decrease quantity"
                  className="px-1 pt-0.5 text-[7px] leading-none text-ink-3 hover:text-ink"
                >
                  ▼
                </button>
              </div>
              {/* The quantity is in the underlying now, so the tag names it —
                  Qty in XAUT — and the lot count it comes to is spelled out on
                  the conversion line below. */}
              <span className="pr-2.5 pl-2 text-[11px] font-medium tracking-wider text-ink-3 uppercase">
                XAUT
              </span>
            </div>

            {/* One divided strip, as theirs is — five bordered boxes read as
                five controls, and this is one control with five notches. */}
            <div className="mt-1.5 flex overflow-hidden rounded bg-raised">
              {PCTS.map((p, i) => (
                <button
                  key={p}
                  onClick={() => setPct(p)}
                  title={
                    reduces
                      ? `${p}% of the ${Math.abs(netQty)} held`
                      : `${p}% of what the balance can margin`
                  }
                  className={`num flex-1 py-1 text-[11px] text-ink-3 hover:bg-raised-2 hover:text-ink ${
                    i > 0 ? 'border-l border-surface' : ''
                  }`}
                >
                  {p}%
                </button>
              ))}
            </div>

            {/* The order's size in the underlying — which is the quantity, once
                snapped to a whole lot — and the lot count it becomes, since that
                is what the book actually fills. */}
            <div className="mt-1.5 flex items-baseline justify-between text-[10px] text-ink-3">
              <span>
                Size{' '}
                <span className="num">
                  ≈{' '}
                  {effectiveXaut.toLocaleString('en-US', {
                    minimumFractionDigits: 3,
                    maximumFractionDigits: 3,
                  })}{' '}
                  {UNDERLYING}
                </span>
              </span>
              <span className="num">
                = {lots.toLocaleString('en-US')} {lots === 1 ? 'lot' : 'lots'}
              </span>
            </div>
          </div>

          {/* Two figures, unboxed. Delta shows exactly these two and nothing
              else, and the panel is quieter for it. The rest is a click away. */}
          <div className="space-y-1.5 pt-1">
            <Row label={reduces ? 'Funds released' : 'Funds req.'} hint="Margin this order blocks">
              <span className="num text-[13px] font-semibold text-ink">
                {reduces ? '—' : usd(preview.marginRequired, 4)}
              </span>
            </Row>
            <Row label="Available Margin">
              <span className="num text-[13px] text-ink-2">{usd(available)}</span>
            </Row>
            {netQty !== 0 && (
              <Row label="Position">
                <span className={`num ${netQty > 0 ? 'text-pos' : 'text-neg'}`}>
                  {netQty > 0 ? '+' : ''}
                  {(netQty * lotSize).toFixed(3)} {UNDERLYING} @ {price(position!.avg_entry_price)}
                </span>
              </Row>
            )}
          </div>

          <div>
            <button
              onClick={() => setDetails((v) => !v)}
              className="flex items-center gap-1 text-[11px] text-ink-3 hover:text-ink"
            >
              <span className="border-b border-dashed border-ink-3">Order details</span>
              <span className="text-[8px]">{details ? '▲' : '▼'}</span>
            </button>

            {details && (
              <div className="mt-2 space-y-1">
                <Row label="Est. fill">
                  <span className="num text-ink">
                    {preview.fillPrice !== null ? price(preview.fillPrice) : '—'}
                  </span>
                </Row>
                <Row label="Premium">
                  <span className="num text-ink-2">{usd(preview.premium, 4)}</span>
                </Row>
                <Row label="Notional">
                  <span className="num text-ink-2">{usd(preview.notional)}</span>
                </Row>
                <Row label="Est. fee">
                  <span className="num text-ink-2">{usd(preview.fee, 4)}</span>
                </Row>
              </div>
            )}
          </div>

          {netQty !== 0 && (
            <button
              onClick={() => {
                setQtyText(fmtQty(Math.abs(netQty) * lotSize))
                setSide(netQty > 0 ? 'sell' : 'buy')
              }}
              className="w-full rounded border border-brand-text py-1.5 text-[12px] text-brand-text hover:bg-brand-muted"
            >
              Close position
            </button>
          )}

          {/* Errors only. An advisory banner is not something Delta's ticket
              carries, and these are the ones that block the order. */}
          {(preview.error || submitError) && (
            <p className="rounded bg-neg-muted px-2 py-1.5 text-[12px] text-neg">
              {submitError ?? preview.error}
            </p>
          )}

          <button
            onClick={submit}
            disabled={!canSubmit}
            className={`w-full rounded py-2.5 text-sm font-semibold text-white transition-colors disabled:cursor-not-allowed disabled:opacity-40 ${
              buying ? 'bg-pos-solid hover:bg-pos-hover' : 'bg-neg-solid hover:bg-neg-hover'
            }`}
          >
            {submitting ? 'Placing…' : buying ? 'Buy' : 'Sell'}
          </button>
        </div>
      </div>
    </div>
  )
}

/** A quantity for the field, trimmed of trailing zeros — 1.5, not 1.500, and
 *  0.001 rather than 0.0010 — so the box reads like something typed. */
function fmtQty(x: number): string {
  return String(Number(x.toFixed(3)))
}

/** A label on the left, a figure on the right. Hinted labels take Delta's
 *  dashed underline, which is their signal that an explanation is available. */
function Row({
  label,
  hint,
  children,
}: {
  label: string
  hint?: string
  children: React.ReactNode
}) {
  return (
    <div className="flex items-baseline justify-between text-[12px]">
      {/* Delta reads these labels in secondary ink, not tertiary — they are
          content, and the figure beside them is what should recede less. */}
      <span className="text-ink-2">
        {hint ? (
          <span className="border-b border-dashed border-ink-3" title={hint}>
            {label}
          </span>
        ) : (
          label
        )}
      </span>
      <span>{children}</span>
    </div>
  )
}
