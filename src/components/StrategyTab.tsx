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
        <div className="leading-tight">
          <div className="text-[10px] font-semibold tracking-[0.14em] text-ink-4 uppercase">
            Auto-trade
          </div>
          <div className={`text-[14px] font-semibold ${armed ? 'text-pos' : 'text-ink-3'}`}>
            {armed ? 'Running' : 'Paused'}
          </div>
        </div>
      </div>

      <Divider />

      <Field label="Strike">
        <select
          value={config.moneyness}
          onChange={(e) => setConfig({ moneyness: e.target.value as Moneyness })}
          className="num h-9 w-24 rounded-md border border-raised-3 bg-surface px-2.5 text-[13px] text-ink transition-colors hover:border-ink-3 focus:border-brand-text focus:outline-none"
        >
          {MONEYNESS_ORDER.map((m) => (
            <option key={m} value={m}>
              {label(m)}
            </option>
          ))}
        </select>
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
        <div className="flex h-9 items-center gap-2 rounded-md border border-raised-3 bg-surface px-2.5 transition-colors focus-within:border-brand-text hover:border-ink-3">
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

function Divider() {
  return <span className="hidden h-9 w-px shrink-0 bg-line sm:block" aria-hidden />
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
        {label}
      </span>
      {children}
    </label>
  )
}

function TimeInput({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <input
      type="time"
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="num bg-transparent text-[13px] text-ink focus:outline-none"
    />
  )
}

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}
