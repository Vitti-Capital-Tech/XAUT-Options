import { useEffect, useRef, useState } from 'react'
import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { StrategyApi } from '../hooks/useAutoStrategy'

/**
 * The auto-strategy's controls — a compact bar above its trades table. The rule
 * is fixed (sell a call on a red 1h candle, a put on a green, stop at twice
 * entry), so there is nothing to toggle there; only whether it runs, the strike,
 * the size and the window. The positions and trade history it produces sit in
 * the panel below, on the strategy's own account.
 */
export function StrategyTab({ strategy }: { strategy: StrategyApi }) {
  const { config, setConfig, armed, setArmed, hasAccount } = strategy

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-4 border-b border-line bg-raised px-5 py-3.5">
      {/* Run / pause. The switch carries the state colour; the word says it plainly. */}
      <div className="flex items-center gap-3">
        <RunSwitch on={armed} onChange={setArmed} disabled={!hasAccount} />
        <span className={`text-[15px] font-semibold ${armed ? 'text-pos' : 'text-ink-3'}`}>
          {armed ? 'Running' : 'Paused'}
        </span>
      </div>

      <Divider />

      <Field label="Strike">
        <Select
          value={config.moneyness}
          onChange={(m) => setConfig({ moneyness: m })}
          options={MONEYNESS_ORDER.map((m) => ({ value: m, label: label(m) }))}
        />
      </Field>

      <Field label="Quantity">
        <div className="flex h-9 items-center rounded-md border border-raised-3 bg-surface pr-2.5 transition-colors focus-within:border-brand-text hover:border-ink-3">
          <input
            type="number"
            min={0.001}
            step={0.001}
            value={config.qty}
            onChange={(e) => {
              const n = Number(e.target.value)
              if (Number.isFinite(n) && n > 0) setConfig({ qty: n })
            }}
            className="num step-own w-20 bg-transparent px-2.5 text-right text-[13px] text-ink focus:outline-none"
          />
          <span className="text-[11px] font-medium text-ink-3">XAUT</span>
        </div>
      </Field>

      <Field label="Window · IST">
        <div className="flex h-9 items-center gap-2 rounded-md border border-raised-3 bg-surface px-3 transition-colors focus-within:border-brand-text hover:border-ink-3">
          <TimeInput value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
          <span className="text-ink-4">–</span>
          <TimeInput value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
        </div>
      </Field>
    </div>
  )
}

// ---------------------------------------------------------------------------

function RunSwitch({
  on,
  onChange,
  disabled,
}: {
  on: boolean
  onChange: (on: boolean) => void
  disabled?: boolean
}) {
  return (
    <button
      role="switch"
      aria-checked={on}
      aria-label="Run auto-trade"
      disabled={disabled}
      title={disabled ? 'Create an auto account first' : on ? 'Pause auto-trade' : 'Run auto-trade'}
      onClick={() => onChange(!on)}
      className={`relative h-7 w-[52px] shrink-0 rounded-full border transition-colors disabled:opacity-30 ${
        on ? 'border-pos-solid bg-pos-solid' : 'border-raised-3 bg-raised-2'
      }`}
    >
      <span
        className={`absolute top-0.5 h-[22px] w-[22px] rounded-full bg-white shadow transition-all ${
          on ? 'left-[26px]' : 'left-0.5'
        }`}
      />
    </button>
  )
}

/**
 * A dark-theme dropdown, since the native select's chrome does not match the
 * terminal. A button shows the choice; a click opens a list that closes on an
 * outside click or a pick.
 */
function Select<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T
  options: { value: T; label: string }[]
  onChange: (value: T) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [open])

  const current = options.find((o) => o.value === value)

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={`flex h-9 w-28 items-center justify-between gap-2 rounded-md border bg-surface px-2.5 text-[13px] text-ink transition-colors hover:border-ink-3 ${
          open ? 'border-brand-text' : 'border-raised-3'
        }`}
      >
        <span className="num">{current?.label}</span>
        <svg
          width="10"
          height="10"
          viewBox="0 0 12 12"
          fill="none"
          className={`shrink-0 text-ink-3 transition-transform ${open ? 'rotate-180' : ''}`}
          aria-hidden
        >
          <path d="M3 4.5L6 7.5L9 4.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div className="absolute z-30 mt-1 max-h-60 w-full overflow-auto rounded-md border border-raised-3 bg-raised py-1 shadow-delta-lg">
          {options.map((o) => {
            const active = o.value === value
            return (
              <button
                key={o.value}
                type="button"
                onClick={() => {
                  onChange(o.value)
                  setOpen(false)
                }}
                className={`num flex w-full items-center px-3 py-1.5 text-left text-[13px] transition-colors ${
                  active ? 'bg-raised-2 text-brand-text' : 'text-ink-2 hover:bg-raised-2 hover:text-ink'
                }`}
              >
                {o.label}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

function Divider() {
  return <span className="hidden h-9 w-px shrink-0 bg-line sm:block" aria-hidden />
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
        {label}
      </span>
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
      className="num w-[52px] bg-transparent text-center text-[13px] text-ink focus:outline-none"
    />
  )
}

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}
