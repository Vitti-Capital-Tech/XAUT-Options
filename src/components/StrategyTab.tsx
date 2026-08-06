import { useEffect, useState } from 'react'
import { market, useMarketTick } from '../lib/marketStore'
import { bestAsk, bestBid } from '../engine/paper'
import { price } from '../lib/format'
import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { LogEntry, StrategyApi } from '../hooks/useAutoStrategy'

/**
 * The auto-strategy tab: the fixed rule and its knobs on the left, what it is
 * about to sell on the right, and a running tape of what it has done beneath. It
 * reads the same live marks the chain does, so the target contract's premium
 * ticks here too. The positions and trade history it produces live in the panel
 * below this, on the strategy's own account.
 */
export function StrategyTab({ strategy }: { strategy: StrategyApi }) {
  useMarketTick()
  const now = useClock()
  const {
    config,
    setConfig,
    armed,
    setArmed,
    latestClosed,
    color,
    signalKind,
    target,
    inWindowNow,
    marketLive,
    hasAccount,
    log,
    runNow,
  } = strategy

  const secsToClose = 3600 - (Math.floor(now / 1000) % 3600)
  const targetTicker = target ? market.get(target.product.symbol) : undefined

  return (
    <div className="grid grid-cols-1 gap-4 p-4 text-[13px] lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      {/* ---- left: the rule --------------------------------------------- */}
      <div className="space-y-4">
        <div className="flex items-center justify-between rounded-lg border border-line bg-raised p-3">
          <div>
            <div className="font-semibold text-ink">Auto strategy</div>
            <div className="mt-0.5 text-[11px] text-ink-3">
              Sells one option on each closed 1h candle. Runs only while this tab is open.
            </div>
          </div>
          <ArmSwitch armed={armed} onChange={setArmed} disabled={!hasAccount} />
        </div>

        {/* The rule, stated — it is not configurable, so it reads rather than
            toggles. */}
        <div className="rounded-lg border border-line bg-raised p-3 text-[12px] leading-relaxed text-ink-2">
          <Rule>
            Red 1h candle → <span className="text-neg">sell a Call</span>
          </Rule>
          <Rule>
            Green 1h candle → <span className="text-neg">sell a Put</span>
          </Rule>
          <Rule>
            Stop loss at <span className="text-ink">2× entry</span> premium (100% loss), on the mark
          </Rule>
          <Rule>Each hour adds another short — positions accumulate</Rule>
        </div>

        <div className="flex flex-wrap gap-1.5">
          <Pill on={marketLive} labelOn="Market live" labelOff="Market down" />
          <Pill on={armed} labelOn="Armed" labelOff="Idle" tone="brand" />
          <Pill on={inWindowNow} labelOn="In window" labelOff="Outside window" />
        </div>

        <Field label="Strike" hint="Distance from the money. ITM to 2, OTM to 5.">
          <div className="flex flex-wrap gap-1">
            {MONEYNESS_ORDER.map((m) => (
              <button
                key={m}
                onClick={() => setConfig({ moneyness: m })}
                className={`num rounded border px-2 py-1 text-[11px] transition-colors ${
                  config.moneyness === m
                    ? 'border-brand-text text-brand-text'
                    : 'border-raised-3 text-ink-3 hover:border-ink-3 hover:text-ink'
                }`}
              >
                {label(m)}
              </button>
            ))}
          </div>
        </Field>

        <Field label="Quantity" hint="Underlying sold each fire.">
          <div className="flex items-center gap-2">
            <input
              type="number"
              min={0.001}
              step={0.001}
              value={config.qty}
              onChange={(e) => {
                const n = Number(e.target.value)
                if (Number.isFinite(n) && n > 0) setConfig({ qty: n })
              }}
              className="num step-own w-28 rounded border border-raised-3 bg-raised px-2.5 py-1.5 text-right text-[13px] text-ink focus:border-ink-3 focus:outline-none"
            />
            <span className="text-[12px] text-ink-3">XAUT / signal</span>
          </div>
        </Field>

        <Field label="Trading window" hint="Trades only fire inside this window (IST).">
          <div className="flex items-center gap-2">
            <TimeInput value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
            <span className="text-ink-3">to</span>
            <TimeInput value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
            <span className="text-[11px] text-ink-3">IST</span>
          </div>
        </Field>
      </div>

      {/* ---- right: what it will do, and the tape ----------------------- */}
      <div className="space-y-4">
        <div className="rounded-lg border border-line bg-raised p-3">
          <div className="mb-2 flex items-baseline justify-between">
            <span className="text-[11px] tracking-wider text-ink-3 uppercase">Last 1h candle</span>
            <span className="num text-[11px] text-ink-3">next close in {mmss(secsToClose)}</span>
          </div>

          {latestClosed ? (
            <div className="flex items-baseline gap-3">
              <span
                className={`text-lg font-bold ${
                  color === 'green' ? 'text-pos' : color === 'red' ? 'text-neg' : 'text-ink-3'
                }`}
              >
                {color === 'green' ? '▲' : color === 'red' ? '▼' : '■'}{' '}
                {color ? color[0].toUpperCase() + color.slice(1) : '—'}
              </span>
              <span className="num text-ink-2">
                {price(latestClosed.open)} → {price(latestClosed.close)}
              </span>
            </div>
          ) : (
            <div className="text-ink-3">Loading candles…</div>
          )}

          {/* The resulting order, spelled out — always a sell. */}
          <div className="mt-3 border-t border-line pt-3">
            {signalKind && target ? (
              <div className="flex items-center justify-between">
                <div>
                  <span className="rounded bg-neg-muted px-1.5 py-0.5 text-[11px] font-bold text-neg">
                    SELL {config.qty} {signalKind === 'call' ? 'CALL' : 'PUT'}
                  </span>
                  <span className="num ml-2 text-ink">{target.product.symbol}</span>
                </div>
                <div className="text-right text-[11px] text-ink-3">
                  <div className="num">
                    bid <span className="text-pos">{price(bestBid(targetTicker))}</span> · ask{' '}
                    <span className="text-neg">{price(bestAsk(targetTicker))}</span>
                  </div>
                  <div className="num">
                    {config.moneyness} · ATM {price(target.atmStrike, 0)}
                  </div>
                </div>
              </div>
            ) : (
              <div className="text-[12px] text-ink-3">
                {marketLive ? 'No signal — flat candle or no strike near spot.' : 'Waiting for market data…'}
              </div>
            )}
          </div>

          <button
            onClick={runNow}
            disabled={!signalKind || !target || !hasAccount}
            className="mt-3 w-full rounded border border-raised-3 py-1.5 text-[12px] text-ink-2 hover:border-ink-3 hover:text-ink disabled:opacity-30 disabled:hover:border-raised-3"
            title="Sell the current signal now, ignoring the window and the once-per-candle guard"
          >
            Sell signal now
          </button>
        </div>

        <div className="rounded-lg border border-line bg-raised">
          <div className="border-b border-line px-3 py-2 text-[11px] tracking-wider text-ink-3 uppercase">
            Activity
          </div>
          {log.length === 0 ? (
            <div className="px-3 py-6 text-center text-[12px] text-ink-4">
              Nothing yet. Arm the strategy and it logs each decision here.
            </div>
          ) : (
            <ul className="max-h-64 divide-y divide-line overflow-y-auto">
              {log.map((e) => (
                <LogRow key={e.id} entry={e} />
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------

function Rule({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex items-start gap-2">
      <span className="mt-1.5 h-1 w-1 shrink-0 rounded-full bg-ink-4" aria-hidden />
      <span>{children}</span>
    </div>
  )
}

function LogRow({ entry }: { entry: LogEntry }) {
  const dot =
    entry.kind === 'trade'
      ? 'bg-brand-text'
      : entry.kind === 'error'
        ? 'bg-neg'
        : entry.kind === 'skip'
          ? 'bg-ink-4'
          : 'bg-ink-3'
  const t = new Date(entry.at).toLocaleTimeString('en-GB', { hour12: false })
  return (
    <li className="flex items-start gap-2 px-3 py-1.5 text-[12px]">
      <span className={`mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full ${dot}`} aria-hidden />
      <span className="num shrink-0 text-ink-4">{t}</span>
      <span className={entry.kind === 'error' ? 'text-neg' : 'text-ink-2'}>{entry.text}</span>
    </li>
  )
}

function ArmSwitch({
  armed,
  onChange,
  disabled,
}: {
  armed: boolean
  onChange: (on: boolean) => void
  disabled?: boolean
}) {
  return (
    <button
      role="switch"
      aria-checked={armed}
      disabled={disabled}
      title={disabled ? 'Create an auto account first' : undefined}
      onClick={() => onChange(!armed)}
      className={`relative h-7 w-12 shrink-0 rounded-full border transition-colors disabled:opacity-30 ${
        armed ? 'border-brand-text bg-brand' : 'border-raised-3 bg-raised-2'
      }`}
    >
      <span
        className={`absolute top-0.5 h-5 w-5 rounded-full bg-white transition-all ${
          armed ? 'left-[22px]' : 'left-0.5'
        }`}
      />
    </button>
  )
}

function Pill({
  on,
  labelOn,
  labelOff,
  tone = 'pos',
}: {
  on: boolean
  labelOn: string
  labelOff: string
  tone?: 'pos' | 'brand'
}) {
  const active =
    tone === 'brand'
      ? 'border-brand-text/50 bg-brand-muted text-brand-text'
      : 'border-pos/40 bg-pos-muted text-pos'
  return (
    <span
      className={`rounded-full border px-2 py-0.5 text-[10px] font-medium ${
        on ? active : 'border-raised-3 text-ink-4'
      }`}
    >
      {on ? labelOn : labelOff}
    </span>
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
    <div>
      <div className="mb-1.5 flex items-baseline gap-2">
        <span className="text-[12px] font-medium text-ink-2">{label}</span>
        {hint && <span className="text-[10px] text-ink-4">{hint}</span>}
      </div>
      {children}
    </div>
  )
}

function TimeInput({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <input
      type="time"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="num rounded border border-raised-3 bg-raised px-2 py-1 text-[12px] text-ink focus:border-ink-3 focus:outline-none"
    />
  )
}

// ---------------------------------------------------------------------------

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}

function mmss(total: number): string {
  const m = Math.floor(total / 60)
  const s = total % 60
  return `${m}:${String(s).padStart(2, '0')}`
}

/** A once-a-second tick, only for the countdown. */
function useClock(): number {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])
  return now
}
