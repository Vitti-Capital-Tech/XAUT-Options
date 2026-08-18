import { useEffect, useState } from 'react'
import type { Product } from '../lib/delta'
import { UNDERLYING, nextFundingTime } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import {
  bestAsk,
  bestBid,
  fundingPayment,
  liquidationPrice,
  maintenanceRate,
  markPrice,
  maxLeverage,
  previewOrder,
  shortImRate,
  type PositionRow,
  type Side,
} from '../engine/paper'
import { compact, pct, price, signedUsd, usd } from '../lib/format'

interface Props {
  /** The perpetual's contract, or null while the first fetch is in flight. */
  product: Product | null
  /** Why there is no contract, when there is none. */
  error: string | null
  position: PositionRow | undefined
  /** The futures account's cash, for the liquidation estimate. */
  cashBalance: number
  available: number
  onSubmit: (args: { product: Product; side: Side; qty: number; leverage: number }) => Promise<void>
}

/**
 * The XAUT perpetual, traded by hand.
 *
 * There is no chain to draw here. Delta India lists exactly one non-option XAUT
 * contract — `XAUTUSD`, a perpetual future — so this page is one instrument: a
 * price strip across the top and a ticket under it. Everything the option pages
 * spend their width on (strikes, expiries, greeks) has no counterpart.
 *
 * What a perpetual has instead, and what this page is really about:
 *
 *   Leverage      Margin is notional over leverage, not a premium. Both sides
 *                 post it — a short future is no more dangerous than a long one,
 *                 which is the opposite of how the option book is margined.
 *   Funding       Every eight hours the two sides pay each other. It is the only
 *                 thing standing in for the expiry a perpetual does not have.
 *   Liquidation   At 100x, 1% against you is the whole account. The estimate is
 *                 on the ticket before the order goes, not only in the table
 *                 after it.
 *
 * The order is market-only, for the same reason the option ticket is: resting
 * orders are matched by a loop in this browser, so a limit would only work while
 * the tab stayed open.
 */
export function FuturesTab({ product, error, position, cashBalance, available, onSubmit }: Props) {
  useMarketTick()

  const [side, setSide] = useState<Side>('buy')
  const [qtyText, setQtyText] = useState('1')
  const [leverage, setLeverage] = useState(10)
  const [submitting, setSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState<string | null>(null)

  // Re-render once a second so the funding countdown moves. The market tick
  // would do it while quotes are arriving, but a dead feed must not freeze a
  // clock — a stopped countdown reads as "funding is not due", which is a
  // different and much worse claim than "the price is stale".
  const [, setSecond] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setSecond((n) => n + 1), 1000)
    return () => clearInterval(id)
  }, [])

  if (error) return <Notice tone="neg">{error}</Notice>
  if (!product) return <Notice tone="dim">Loading the perpetual contract…</Notice>

  const ticker = market.get(product.symbol)
  const cv = Number(product.contract_value)
  const mark = markPrice(ticker)
  const bid = bestBid(ticker)
  const ask = bestAsk(ticker)
  const spot = market.spot
  const cap = maxLeverage(product)
  const imRate = shortImRate(product)

  // The field reads in the underlying, as the option ticket's does: one Qty is
  // one XAUT, and the engine counts lots underneath.
  const qtyXaut = Number(qtyText)
  const lots = Number.isFinite(qtyXaut) ? Math.max(0, Math.round(qtyXaut / cv)) : 0
  const effectiveXaut = lots * cv

  const preview = previewOrder(
    { product, side, orderType: 'market', qty: lots, limitPrice: null, leverage },
    ticker,
    spot,
    position,
    available,
  )

  // The position this order would leave behind, so the liquidation estimate is
  // the one that will actually apply rather than the one for a flat book. Adding
  // to a position blends the entry; reversing through zero re-opens at the fill.
  const resulting = (() => {
    const fill = preview.fillPrice
    if (fill === null || lots === 0) return null
    const signed = side === 'buy' ? lots : -lots
    const held = position?.net_qty ?? 0
    const heldAvg = Number(position?.avg_entry_price ?? 0)
    const net = held + signed
    if (net === 0) return null
    if (held === 0 || Math.sign(held) === Math.sign(signed)) {
      const avg = (Math.abs(held) * heldAvg + lots * fill) / (Math.abs(held) + lots)
      return { net, avg: held === 0 ? fill : avg }
    }
    // Reducing keeps the entry; flipping through zero takes the fill price.
    return { net, avg: Math.sign(net) === Math.sign(held) ? heldAvg : fill }
  })()

  const estLiq = resulting
    ? liquidationPrice(resulting.net, resulting.avg, cv, cashBalance, maintenanceRate(product))
    : null

  const fundingRate = Number(ticker?.funding_rate)
  const hasFunding = Number.isFinite(fundingRate)
  const nextFunding = nextFundingTime(product)
  const nextPayment =
    hasFunding && position && mark !== null
      ? fundingPayment(mark, cv, position.net_qty, fundingRate)
      : null

  const change = Number(ticker?.mark_change_24h)
  const blocked = Boolean(preview.error) || lots === 0 || submitting

  const submit = async () => {
    setSubmitting(true)
    setSubmitError(null)
    try {
      await onSubmit({ product, side, qty: lots, leverage })
    } catch (err) {
      setSubmitError(err instanceof Error ? err.message : 'Order failed')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="shrink-0 border-b border-line bg-raised">
      {/* ---- The instrument, and everything the venue publishes about it ---- */}
      <div className="flex flex-wrap items-center gap-x-6 gap-y-3 border-b border-line px-4 py-3">
        <div className="flex shrink-0 items-baseline gap-2.5">
          <span className="num text-[15px] font-bold text-ink">{product.symbol}</span>
          <span className="rounded-sm border border-brand-text/40 bg-brand-muted px-1.5 py-0.5 text-[9px] font-bold tracking-wider text-brand-text uppercase">
            Perpetual
          </span>
        </div>

        {/* The mark, big, because it is the number the position is valued and
            liquidated against — not the last trade. */}
        <div className="shrink-0">
          <div className="text-[10px] tracking-wider text-ink-3 uppercase">Mark</div>
          <div className="num text-[20px] leading-tight font-bold text-ink">
            {mark === null ? '—' : price(mark)}
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
          <Stat label="24h Change" value={Number.isFinite(change) ? pct(change) : '—'} className={pnl(change)} />
          <Stat label="Index" value={spot > 0 ? price(spot) : '—'} />
          <Stat label="Bid" value={bid === null ? '—' : price(bid)} className="text-pos" />
          <Stat label="Ask" value={ask === null ? '—' : price(ask)} className="text-neg" />
          <Stat label="24h High" value={ticker?.high == null ? '—' : price(ticker.high)} />
          <Stat label="24h Low" value={ticker?.low == null ? '—' : price(ticker.low)} />
          <Stat label="24h Volume" value={ticker?.turnover_usd == null ? '—' : `$${compact(ticker.turnover_usd)}`} />
          <Stat label="Open Interest" value={ticker?.oi_value_usd == null ? '—' : `$${compact(ticker.oi_value_usd)}`} />
          {/* Funding is the perpetual's substitute for an expiry, so it is
              carried in the header rather than buried in the ticket. Sign and
              direction together: a bare percentage does not say who pays. */}
          <Stat
            label="Funding / 8h"
            value={hasFunding ? `${fundingRate > 0 ? '+' : ''}${fundingRate.toFixed(4)}%` : '—'}
            className={hasFunding ? (fundingRate > 0 ? 'text-neg' : 'text-pos') : undefined}
            hint={
              hasFunding
                ? fundingRate === 0
                  ? 'flat'
                  : fundingRate > 0
                    ? 'longs pay shorts'
                    : 'shorts pay longs'
                : undefined
            }
          />
          <Stat label="Next Funding" value={countdown(nextFunding)} hint={istTime(nextFunding)} />
        </div>
      </div>

      {/* ---- The ticket ---------------------------------------------------- */}
      <div className="flex flex-wrap items-start gap-x-8 gap-y-4 px-4 py-3">
        {/* Long and short, in the ink each direction reads in everywhere else. */}
        <div className="flex shrink-0 overflow-hidden rounded-md border border-raised-3">
          {(['buy', 'sell'] as Side[]).map((s) => (
            <button
              key={s}
              onClick={() => setSide(s)}
              className={`px-5 py-2 text-[13px] font-semibold transition-colors ${
                side === s
                  ? s === 'buy'
                    ? 'bg-pos-solid text-white'
                    : 'bg-neg-solid text-white'
                  : 'text-ink-3 hover:text-ink'
              }`}
            >
              {s === 'buy' ? 'Long' : 'Short'}
            </button>
          ))}
        </div>

        <Field label={`Qty (${UNDERLYING})`}>
          <input
            value={qtyText}
            onChange={(e) => setQtyText(e.target.value)}
            inputMode="decimal"
            className="num w-28 rounded-md border border-raised-3 bg-surface px-2.5 py-1.5 text-left text-[13px] text-ink focus:border-ink-3 focus:outline-none"
          />
          <span className="text-[10px] text-ink-3">
            {lots.toLocaleString()} {lots === 1 ? 'lot' : 'lots'}
            {effectiveXaut !== qtyXaut && Number.isFinite(qtyXaut) ? ` · ${effectiveXaut.toFixed(3)}` : ''}
          </span>
        </Field>

        {/* The venue's own ladder, clamped to the leverage it will actually open
            the contract at — the ladder is UI config and the cap is margin, and
            it is the cap that decides. */}
        <Field label="Leverage">
          <div className="flex flex-wrap gap-1">
            {leverageLadder(product, cap).map((n) => (
              <button
                key={n}
                onClick={() => setLeverage(n)}
                className={`num rounded border px-2 py-1 text-[11px] font-semibold transition-colors ${
                  leverage === n
                    ? 'border-brand-text bg-brand-muted text-brand-text'
                    : 'border-raised-3 text-ink-3 hover:border-ink-3 hover:text-ink'
                }`}
              >
                {n}x
              </button>
            ))}
          </div>
          {/* Not `pct`: that formatter signs its output for a change figure, and
              a margin rate is not a change — "+1.00%" would read as a move. */}
          <span className="text-[10px] text-ink-3">
            min margin {(imRate * 100).toFixed(2)}% · max {cap}x
          </span>
        </Field>

        {/* What the order costs and what it risks, before it goes. */}
        <div className="flex flex-wrap items-center gap-x-6 gap-y-2">
          <Stat label="Order Value" value={usd(preview.premium)} />
          <Stat label="Margin" value={usd(preview.marginRequired, 4)} />
          <Stat label="Fee" value={usd(preview.fee, 4)} />
          <Stat label="Available" value={usd(available)} className={available < 0 ? 'text-neg' : undefined} />
          {/* The one figure on this page that ends the position by itself. */}
          <Stat
            label="Est. Liquidation"
            value={estLiq === null ? '—' : price(estLiq)}
            className={estLiq === null ? undefined : 'text-neg'}
            hint={estLiq === null ? undefined : 'whole book, at maintenance'}
          />
          {nextPayment !== null && (
            <Stat
              label="Next Funding P&L"
              value={signedUsd(nextPayment, 4)}
              className={pnl(nextPayment)}
              hint="on the position held now"
            />
          )}
        </div>

        <div className="ml-auto flex shrink-0 flex-col items-end gap-1">
          <button
            onClick={submit}
            disabled={blocked}
            className={`rounded-md px-6 py-2 text-[13px] font-semibold text-white transition-colors disabled:opacity-40 ${
              side === 'buy' ? 'bg-pos-solid hover:brightness-110' : 'bg-neg-solid hover:brightness-110'
            }`}
          >
            {submitting ? 'Placing…' : `${side === 'buy' ? 'Long' : 'Short'} ${UNDERLYING}`}
          </button>
          {(preview.error || submitError) && (
            <span className="max-w-[320px] text-right text-[10px] text-neg">
              {submitError ?? preview.error}
            </span>
          )}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------

/**
 * The leverage buttons. Delta's own ladder where they publish one, ours where
 * they do not, and never a rung above the margin cap — an offer the venue would
 * refuse is worse than a shorter ladder.
 */
function leverageLadder(product: Product, cap: number): number[] {
  const ladder = product.ui_config?.leverage_slider_values ?? [1, 5, 10, 25, 50, 100]
  const within = ladder.filter((n) => n > 0 && n <= cap)
  return within.length > 0 ? within : [1]
}

/** `0d 13h 24m` style, to the second under an hour. */
function countdown(to: Date): string {
  const ms = to.getTime() - Date.now()
  if (ms <= 0) return 'due'
  const s = Math.floor(ms / 1000)
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return h > 0 ? `${h}h ${String(m).padStart(2, '0')}m` : `${m}m ${String(s % 60).padStart(2, '0')}s`
}

/** The wall-clock the desk reads, which is IST — matching every other time here. */
function istTime(at: Date): string {
  return at.toLocaleTimeString('en-IN', {
    timeZone: 'Asia/Kolkata',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  })
}

const pnl = (v: number) => (!Number.isFinite(v) || v === 0 ? 'text-ink' : v > 0 ? 'text-pos' : 'text-neg')

function Stat({
  label,
  value,
  className,
  hint,
}: {
  label: string
  value: string
  className?: string
  hint?: string
}) {
  return (
    <div className="shrink-0 whitespace-nowrap">
      <div className="text-[10px] tracking-wider text-ink-3 uppercase">{label}</div>
      <div className={`num text-[13px] font-semibold ${className ?? 'text-ink'}`}>{value}</div>
      {hint && <div className="text-[9px] text-ink-4">{hint}</div>}
    </div>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="shrink-0">
      <div className="mb-1 text-[10px] tracking-wider text-ink-3 uppercase">{label}</div>
      <div className="flex items-center gap-2">{children}</div>
    </div>
  )
}

function Notice({ tone, children }: { tone: 'neg' | 'dim'; children: React.ReactNode }) {
  return (
    <div
      className={`shrink-0 border-b border-line bg-raised px-4 py-6 text-center text-xs ${
        tone === 'neg' ? 'text-neg' : 'text-ink-3'
      }`}
    >
      {children}
    </div>
  )
}
