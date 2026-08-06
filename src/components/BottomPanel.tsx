import { useState } from 'react'
import type { Product, Ticker } from '../lib/delta'
import { UNDERLYING } from '../lib/delta'
import { market, useMarketTick } from '../lib/marketStore'
import { shortImRate, valuePosition, type PositionRow } from '../engine/paper'
import type { FillRow } from '../hooks/useTrading'
import { dateTimeParts, ivShort, pct, pnlClass, price } from '../lib/format'

type Tab = 'positions' | 'history'

interface Props {
  positions: PositionRow[]
  fills: FillRow[]
  productsBySymbol: Map<string, Product>
  onClosePosition: (pos: PositionRow, product: Product) => Promise<void>
  onSetTpSl: (positionId: string, takeProfit: number | null, stopLoss: number | null) => Promise<void>
  onPickSymbol: (product: Product) => void
}

// No Open Orders tab: the ticket is market-only, so nothing ever rests. The
// browser fill engine still resolves any limit order left in the database from
// before, it simply has no tab of its own now — a position is closed from its
// own row, which is the only order anyone places here.
export function BottomPanel({
  positions,
  fills,
  productsBySymbol,
  onClosePosition,
  onSetTpSl,
  onPickSymbol,
}: Props) {
  const [tab, setTab] = useState<Tab>('positions')

  const tabs: { key: Tab; label: string; count: number }[] = [
    { key: 'positions', label: 'Positions', count: positions.length },
    { key: 'history', label: 'Trade History', count: fills.length },
  ]

  return (
    /* As tall as whichever table is showing. Nothing here scrolls: the document
       does. */
    <div className="flex flex-col border-t border-line bg-surface">
      <div className="flex shrink-0 items-center gap-1 border-b border-line px-2">
        {tabs.map((t) => {
          const active = tab === t.key
          return (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`relative px-3 py-2 text-xs font-medium transition-colors ${
                active ? 'text-ink' : 'text-ink-3 hover:text-ink'
              }`}
            >
              {/* Delta writes the count in parentheses beside the label, in the
                  same ink, rather than as a chip of its own. */}
              {t.label}
              {t.count > 0 && <span className="num ml-1 text-ink-3">({t.count})</span>}
              {/* The brand rule sits on the border line itself, the width of the
                  tab, the way theirs does. */}
              {active && <span className="absolute inset-x-0 -bottom-px h-0.5 bg-brand-text" />}
            </button>
          )
        })}
      </div>

      <div className="flex flex-col">
        {tab === 'positions' && (
          <PositionsTable
            positions={positions}
            productsBySymbol={productsBySymbol}
            onClosePosition={onClosePosition}
            onSetTpSl={onSetTpSl}
            onPickSymbol={onPickSymbol}
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
 * The two edge columns — symbol and action — are ruled off and lifted the way
 * the chain lifts its strike, so the scrolling middle reads as held between
 * them. Each casts its shadow inward over its neighbour, and no wider than that:
 * a longer reach greyed the figures in the next column along. No background of
 * their own, so a row's hover still runs the whole width underneath.
 */
const WALL: Record<'start' | 'end', string> = {
  start: 'border-x border-line shadow-[3px_0_6px_-3px_#000000aa]',
  end: 'border-x border-line shadow-[-3px_0_6px_-3px_#000000aa]',
}

const alignClass = (align: 'left' | 'right' | 'center') =>
  align === 'left' ? 'text-left' : align === 'center' ? 'text-center' : 'text-right'

function Th({
  children,
  align = 'right',
  wall,
  className = '',
}: {
  children: React.ReactNode
  align?: 'left' | 'right' | 'center'
  /** Ruled off and lifted as an edge column; the value picks which way it casts. */
  wall?: 'start' | 'end'
  className?: string
}) {
  /* Delta labels a table the way the chain's header does and no differently:
     12px, secondary ink, Title Case, regular weight. No small-caps, no letter
     spacing — those made the labels shout over the figures they name. */
  return (
    <th
      className={`bg-raised px-3 py-2 text-[12px] font-normal whitespace-nowrap text-ink-2 ${alignClass(
        align,
      )} ${wall ? WALL[wall] : ''} ${className}`}
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
  wall,
}: {
  children?: React.ReactNode
  align?: 'left' | 'right' | 'center'
  className?: string
  colSpan?: number
  title?: string
  /**
   * Ruled off and lifted as an edge column, the way the chain walls its strike.
   * Not pinned: it scrolls with the table like everything else.
   */
  wall?: 'start' | 'end'
}) {
  /* Delta's rows breathe: 12px of gutter and 10px above and below, so a
     two-line cell makes a taller row rather than a squeeze. */
  return (
    <td
      colSpan={colSpan}
      title={title}
      className={`num px-3 py-2.5 whitespace-nowrap ${alignClass(align)} ${
        wall ? WALL[wall] : ''
      } ${className}`}
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
      /* inline-flex, not flex: a block-level button sizes to fit and then sits
         wherever the box model puts it, which text-align cannot reach — that is
         what stranded this at the left of a centred column. */
      className="inline-flex items-center justify-center gap-2 align-middle enabled:hover:underline"
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
  onSetTpSl,
  onPickSymbol,
}: {
  positions: PositionRow[]
  productsBySymbol: Map<string, Product>
  onClosePosition: (pos: PositionRow, product: Product) => Promise<void>
  onSetTpSl: (positionId: string, takeProfit: number | null, stopLoss: number | null) => Promise<void>
  onPickSymbol: (product: Product) => void
}) {
  useMarketTick()
  const [closing, setClosing] = useState<string | null>(null)
  // The position whose TP/SL is being edited, in a dialog over the table.
  const [editing, setEditing] = useState<PositionRow | null>(null)
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
    <>
      {editing && (
        <TpSlDialog
          position={editing}
          spot={spot}
          onClose={() => setEditing(null)}
          onSave={onSetTpSl}
        />
      )}
    <Paged rows={positions}>
      {(visible) => (
    <table className="w-full text-[13px]">
      <thead className="sticky top-0 z-10">
        {/* Above the labels, not below the rows. Once the table pages, a footer
            total sits under one page and reads as that page's — these are the
            whole book's, every position, whichever page is showing. */}
        <tr className="border-b border-line bg-raised-2">
          <Td
            align="left"
            wall="start"
            className="text-[12px] font-semibold text-ink-2"
          >
            Σ Total · {positions.length}
          </Td>
          <Td />
          <Td className="text-ink">
            <Money value={totals.notional} />
          </Td>
          {/* entry · TP/SL · index · mark — none of them sum. */}
          <Td colSpan={4} />
          <Td className="text-ink">
            <Money value={totals.margin} />
          </Td>
          <Td className={`font-semibold ${pnlClass(totals.unrealized)}`}>
            <Money value={totals.unrealized} signed suffix="inherit" />
          </Td>
          <Td className="font-semibold text-ink">{totals.delta.toFixed(4)}</Td>
          <Td className="font-semibold text-ink">{totals.gamma.toFixed(6)}</Td>
          <Td className="font-semibold text-ink">{totals.vega.toFixed(4)}</Td>
          <Td className="pr-5 font-semibold text-ink">{totals.theta.toFixed(4)}</Td>
          <Td wall="end" />
        </tr>
        <tr>
          <Th align="left" wall="start">Symbol</Th>
          <Th>Size</Th>
          <Th>Notional</Th>
          <Th>Entry Price</Th>
          <Th align="center">TP / SL</Th>
          <Th>Index Price</Th>
          <Th>Mark Price</Th>
          <Th>Margin</Th>
          <Th>UPNL</Th>
          <Th>Delta</Th>
          <Th>Gamma</Th>
          <Th>Vega</Th>
          <Th className="pr-5">Theta</Th>
          <Th align="center" wall="end">Action</Th>
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
              <Td align="left" wall="start">
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
              <Td className="text-ink">
                <Money value={spot * cv * lots} />
              </Td>
              <Td className="text-ink">{price(pos.avg_entry_price)}</Td>
              <Td align="center">
                <TpSlCell
                  takeProfit={pos.take_profit}
                  stopLoss={pos.stop_loss}
                  onEdit={() => setEditing(pos)}
                  onClear={() => void onSetTpSl(pos.id, null, null)}
                />
              </Td>
              <Td className="text-ink">{price(spot)}</Td>
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
              <Td className="text-ink">
                <Money value={v.marginBlocked} />
                {isLong && <div className="text-[10px] text-ink-3">premium</div>}
              </Td>
              <Td className={pnlClass(v.unrealized)}>
                <div className="font-semibold">
                  <Money value={v.unrealized} signed suffix="inherit" />
                </div>
                <div className="text-[10px]">{pct(v.unrealizedPct)}</div>
              </Td>
              <Td className="text-ink-2">{greekCell(g.delta, 4)}</Td>
              <Td className="text-ink-2">{greekCell(g.gamma, 6)}</Td>
              <Td className="text-ink-2">{greekCell(g.vega, 4)}</Td>
              <Td className="pr-5 text-ink-2">{greekCell(g.theta, 4)}</Td>
              <Td align="center" wall="end">
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
    </>
  )
}

/**
 * The TP/SL cell, as Delta lays it out: the two levels stacked as TP (USD)/SL,
 * with a pencil to edit and a trash to clear both at once. The trash is dead
 * while nothing is armed, so it never promises to remove what is not there.
 */
function TpSlCell({
  takeProfit,
  stopLoss,
  onEdit,
  onClear,
}: {
  takeProfit: string | null
  stopLoss: string | null
  onEdit: () => void
  onClear: () => void
}) {
  const armed = Boolean(takeProfit || stopLoss)
  return (
    <div className="flex items-center justify-center gap-2">
      <div className="text-left text-[11px] leading-snug whitespace-nowrap">
        <div>
          <span className="text-ink-3">TP (USD) : </span>
          <span className={takeProfit ? 'text-ink' : 'text-ink-3'}>
            {takeProfit ? price(takeProfit) : '-'}
          </span>
        </div>
        <div>
          <span className="text-ink-3">SL : </span>
          <span className={stopLoss ? 'text-ink' : 'text-ink-3'}>
            {stopLoss ? price(stopLoss) : '-'}
          </span>
        </div>
      </div>
      <div className="flex items-center gap-1">
        <button
          type="button"
          onClick={onEdit}
          title="Edit take-profit / stop-loss"
          className="rounded border border-raised-3 p-1 text-brand-text hover:border-brand-text"
        >
          <PencilIcon />
        </button>
        <button
          type="button"
          onClick={onClear}
          disabled={!armed}
          title="Clear take-profit / stop-loss"
          className="rounded border border-raised-3 p-1 text-brand-text hover:border-brand-text disabled:opacity-30 disabled:hover:border-raised-3"
        >
          <TrashIcon />
        </button>
      </div>
    </div>
  )
}

function PencilIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path
        d="M11.5 2.5l2 2L5 13l-2.5.5L3 11l8.5-8.5z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function TrashIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 16 16" fill="none" aria-hidden>
      <path
        d="M2.5 4h11M6 4V2.5h4V4M4 4l.5 9.5h7L12 4M6.5 6.5v5M9.5 6.5v5"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

/**
 * Delta's "Edit Bracket Order": entry and the index it triggers against up top,
 * then a take-profit and a stop-loss block, each with a Market tag and a row of
 * percentage presets. The presets step the trigger away from the index in the
 * direction that side fires — profit for TP, loss for SL — so tapping 10% always
 * arms a sane level whichever way the position leans.
 */
function TpSlDialog({
  position,
  spot,
  onClose,
  onSave,
}: {
  position: PositionRow
  spot: number
  onClose: () => void
  onSave: (positionId: string, takeProfit: number | null, stopLoss: number | null) => Promise<void>
}) {
  // Coerced to string: a numeric column can arrive as a number, and the render
  // path calls .trim() on these — an uncoerced number blanked the dialog the
  // moment it opened on an already-set level.
  const [tp, setTp] = useState(position.take_profit != null ? String(position.take_profit) : '')
  const [sl, setSl] = useState(position.stop_loss != null ? String(position.stop_loss) : '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const isLong = position.net_qty > 0
  const bullish = (position.contract_type === 'call_options') === isLong

  // A level's distance from the index, as a signed percent, so the input can
  // show how far off it sits the way Delta's little box does.
  const distPct = (v: string) => {
    if (!spot || String(v).trim() === '') return null
    const n = Number(v)
    if (!Number.isFinite(n)) return null
    return Math.abs((n - spot) / spot) * 100
  }

  // Step the index by a percent in a side's firing direction.
  const stepFrom = (pct: number, side: 'tp' | 'sl') => {
    const up = side === 'tp' ? bullish : !bullish
    const level = spot * (1 + (up ? pct : -pct) / 100)
    return level.toFixed(2)
  }

  const save = async () => {
    const tpNum = String(tp).trim() === '' ? null : Number(tp)
    const slNum = String(sl).trim() === '' ? null : Number(sl)
    if (tpNum !== null && !(tpNum > 0)) return setError('Take-profit must be a positive price')
    if (slNum !== null && !(slNum > 0)) return setError('Stop-loss must be a positive price')

    // A level on the side the index has already passed would fire on the very
    // next poll and close the position seconds after saving — which reads as the
    // row vanishing. Refuse it, and say which way it has to go.
    if (spot > 0) {
      const tpArmed = tpNum !== null && (bullish ? spot >= tpNum : spot <= tpNum)
      const slArmed = slNum !== null && (bullish ? spot <= slNum : spot >= slNum)
      if (tpArmed) {
        return setError(
          `Take-profit ${price(tpNum)} is already past the index (${price(spot)}) — it would close at once. Put it ${bullish ? 'above' : 'below'} the index.`,
        )
      }
      if (slArmed) {
        return setError(
          `Stop-loss ${price(slNum)} is already past the index (${price(spot)}) — it would close at once. Put it ${bullish ? 'below' : 'above'} the index.`,
        )
      }
    }

    setBusy(true)
    setError(null)
    try {
      await onSave(position.id, tpNum, slNum)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not save levels')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
      onClick={onClose}
    >
      <div
        className="w-full max-w-sm rounded-lg border border-raised-3 bg-surface shadow-delta-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between border-b border-line px-4 py-3">
          <span className="num text-sm font-semibold text-ink">
            Edit Bracket Order: {position.symbol}
          </span>
          <button
            onClick={onClose}
            className="rounded p-1 text-ink-3 hover:bg-raised-2 hover:text-ink"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="space-y-4 p-4">
          <div className="flex items-baseline justify-between text-[12px]">
            <span className="text-ink-3">Entry Price</span>
            <span className="num text-ink">{price(position.avg_entry_price)}</span>
          </div>
          <div className="flex items-baseline justify-between text-[12px]">
            <span className="text-ink-3">Trigger Index</span>
            <span className="num text-ink">Index {price(spot)}</span>
          </div>

          <TpSlBlock
            title="Take Profit"
            value={tp}
            onChange={setTp}
            dist={distPct(tp)}
            onPct={(p) => setTp(stepFrom(p, 'tp'))}
          />

          <div className="border-t border-dashed border-line" />

          <TpSlBlock
            title="Stop Loss"
            value={sl}
            onChange={setSl}
            dist={distPct(sl)}
            onPct={(p) => setSl(stepFrom(p, 'sl'))}
          />

          {error && <p className="text-[11px] text-neg">{error}</p>}

          <button
            onClick={save}
            disabled={busy}
            className="w-full rounded bg-brand py-2.5 text-sm font-semibold text-white hover:bg-brand-hover disabled:opacity-40"
          >
            {busy ? 'Saving…' : 'Update'}
          </button>
        </div>
      </div>
    </div>
  )
}

/** One side of the bracket editor: title + Market tag, the trigger input with
 *  its distance readout, and the percentage presets beneath. */
function TpSlBlock({
  title,
  value,
  onChange,
  dist,
  onPct,
}: {
  title: string
  value: string
  onChange: (v: string) => void
  dist: number | null
  onPct: (pct: number) => void
}) {
  // The percent box is empty until a level is set, then shows its distance from
  // the index with trailing zeros trimmed. Empty falls back to the 0% placeholder.
  const pctValue = dist === null ? '' : parseFloat(dist.toFixed(2))
  return (
    <div>
      <div className="mb-1.5 flex items-center justify-between">
        <span className="text-[13px] font-bold text-ink">{title}</span>
        <span className="rounded border border-brand-text/50 px-2 py-0.5 text-[10px] font-semibold text-brand-text">
          Market
        </span>
      </div>

      <div className="mb-1 text-[11px] text-ink-3">Trigger Price</div>

      {/* One control: the price on top, and a strip beneath holding the four
          presets and the editable percent — the box on the right, as Delta has
          it, where typing a percent sets the trigger that far off the index.
          The placeholder sits left and the typed value right, the way theirs
          does, so it needs to be an overlay rather than the native placeholder. */}
      <div className="overflow-hidden rounded border border-raised-3 bg-raised focus-within:border-ink-3">
        <div className="relative">
          {value === '' && (
            <span className="pointer-events-none absolute inset-y-0 left-2.5 flex items-center text-sm text-ink-4">
              Trigger Price USD
            </span>
          )}
          <input
            type="number"
            value={value}
            onChange={(e) => onChange(e.target.value)}
            className="num step-own w-full bg-transparent px-2.5 py-2 text-right text-sm text-ink focus:outline-none"
          />
        </div>
        <div className="flex border-t border-raised-3 text-[11px]">
          {[5, 10, 15, 20].map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => onPct(p)}
              className="num flex-1 border-r border-raised-3 py-1 text-ink-3 hover:bg-raised-2 hover:text-ink"
            >
              {p}%
            </button>
          ))}
          <div className="flex w-16 items-center justify-center gap-0.5 bg-raised-2 text-ink">
            <input
              type="number"
              value={pctValue}
              onChange={(e) => {
                if (e.target.value === '') return
                const n = Number(e.target.value)
                if (Number.isFinite(n)) onPct(n)
              }}
              placeholder="0"
              aria-label={`${title} distance percent`}
              className="num step-own w-9 bg-transparent text-right placeholder:text-ink-4 focus:outline-none"
            />
            <span className="text-ink-3">%</span>
          </div>
        </div>
      </div>
    </div>
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

/**
 * A monetary value the way Delta writes it in this table: the number, then a
 * dimmed USD, rather than a $ prefix. Two decimals on ordinary sizes; more only
 * where the value is under a dollar, so a few-cent option premium is not
 * flattened to 0.00. `signed` prepends a + on gains, for the P&L column.
 */
function Money({
  value,
  signed = false,
  // The dimmed grey suits a white value; a coloured value (P&L) wants its USD
  // the same colour, so the whole figure reads as one.
  suffix = 'dim',
}: {
  value: number | string | null | undefined
  signed?: boolean
  suffix?: 'dim' | 'inherit'
}) {
  const n = typeof value === 'string' ? Number(value) : value
  if (n === null || n === undefined || !Number.isFinite(n)) return <span className="text-ink-4">—</span>
  const dp = n !== 0 && Math.abs(n) < 1 ? 4 : 2
  const num = Math.abs(n).toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp })
  const sign = n < 0 ? '-' : signed ? '+' : ''
  return (
    <>
      {sign}
      {num} <span className={suffix === 'dim' ? 'text-ink-2' : undefined}>USD</span>
    </>
  )
}

// ---------------------------------------------------------------------------

function HistoryTable({ fills }: { fills: FillRow[] }) {
  if (fills.length === 0) return <Empty>No trades yet.</Empty>

  return (
    <Paged rows={fills}>
      {(visible) => (
    <table className="w-full table-fixed text-[13px]">
      {/* Seven columns is a third of what Delta's order history carries, so a
          table this wide has slack — and auto layout gives it to whichever cell
          holds the longest string. That is what took Symbol out to a quarter of
          the row and opened the void between Side and Execution Price.

          Fixed shares instead, each column's widest content plus an equal cut of
          what is left over, so the air falls between the columns evenly rather
          than pooling in whichever one happens to hold a long header. */}
      <colgroup>
        <col className="w-[20%]" />
        <col className="w-[12%]" />
        <col className="w-[11%]" />
        <col className="w-[12%]" />
        <col className="w-[15%]" />
        <col className="w-[15%]" />
        <col className="w-[15%]" />
      </colgroup>
      <thead className="sticky top-0 z-10">
        {/* Delta's order-history order, less the columns that never vary on a
            fills ledger. Symbol and Time are walled, as the positions table
            walls its symbol and action, so the row reads between two edges.
            Every column centres over its own figures but Symbol, which hangs
            left the way Delta hangs it — the row reads from a fixed left edge,
            and a centred symbol wandered with the length of each contract. */}
        <tr>
          <Th align="left" wall="start">Symbol</Th>
          <Th align="center">Qty (XAUT)</Th>
          <Th align="center">Side</Th>
          <Th align="center">Execution Price</Th>
          <Th align="center">Size</Th>
          <Th align="center">Realized PnL</Th>
          <Th align="center" wall="end">Time</Th>
        </tr>
      </thead>
      <tbody>
        {visible.map((f) => {
          const realized = Number(f.realized_pnl)
          const buy = f.side === 'buy'
          const size = f.qty * Number(f.contract_value)
          const at = dateTimeParts(f.created_at)
          return (
            <tr key={f.id} className="border-b border-line hover:bg-raised">
              <Td align="left" wall="start">
                <Instrument symbol={f.symbol} accent={buy ? 'pos' : 'neg'} />
              </Td>
              {/* Quantity in the underlying now, not the lot count — the size
                  and the qty are one unit apart no longer. */}
              <Td align="center" className="text-ink">{size.toFixed(3)}</Td>
              {/* Title case, as Delta writes a side — `Sell`, not a shouted
                  SELL. The colour already says which way it went. */}
              <Td align="center" className={buy ? 'text-pos' : 'text-neg'}>
                {buy ? 'Buy' : 'Sell'}
              </Td>
              <Td align="center" className="text-ink">{price(f.price)}</Td>
              <Td align="center" className={buy ? 'text-pos' : 'text-neg'}>
                {buy ? '+' : '-'}
                {size.toFixed(3)} {UNDERLYING}
              </Td>
              <Td align="center" className={realized === 0 ? 'text-ink-4' : pnlClass(realized)}>
                {realized === 0 ? '—' : <Money value={realized} signed suffix="inherit" />}
              </Td>
              <Td align="center" wall="end" className="leading-tight text-ink-2">
                <div>{at.date}</div>
                <div>{at.time}</div>
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
