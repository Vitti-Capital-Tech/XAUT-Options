import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { StrategyApi } from '../hooks/useAutoStrategy'

/**
 * The auto-strategy's controls — a thin filter bar above its trades table. The
 * rule itself is fixed (sell a call on a red 1h candle, a put on a green, stop
 * at twice entry), so there is nothing to toggle there; only the strike, the
 * size, the window and the arm switch. The positions and trade history it
 * produces sit in the panel below this, on the strategy's own account.
 */
export function StrategyTab({ strategy }: { strategy: StrategyApi }) {
  const { config, setConfig, armed, setArmed, hasAccount } = strategy

  return (
    <div className="flex flex-wrap items-end gap-x-5 gap-y-3 border-b border-line bg-surface px-4 py-3 text-[13px]">
      <div className="flex items-center gap-2">
        <ArmSwitch armed={armed} onChange={setArmed} disabled={!hasAccount} />
        <span className={`text-[12px] font-medium ${armed ? 'text-brand-text' : 'text-ink-3'}`}>
          {armed ? 'Armed' : 'Idle'}
        </span>
      </div>

      <Field label="Strike">
        <select
          value={config.moneyness}
          onChange={(e) => setConfig({ moneyness: e.target.value as Moneyness })}
          className="num rounded border border-raised-3 bg-raised px-2 py-1.5 text-[12px] text-ink hover:border-ink-3 focus:border-ink-3 focus:outline-none"
        >
          {MONEYNESS_ORDER.map((m) => (
            <option key={m} value={m}>
              {label(m)}
            </option>
          ))}
        </select>
      </Field>

      <Field label="Quantity">
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
            className="num step-own w-24 rounded border border-raised-3 bg-raised px-2.5 py-1.5 text-right text-[12px] text-ink focus:border-ink-3 focus:outline-none"
          />
          <span className="text-[12px] text-ink-3">XAUT</span>
        </div>
      </Field>

      <Field label="Window (IST)">
        <div className="flex items-center gap-2">
          <TimeInput value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
          <span className="text-ink-3">–</span>
          <TimeInput value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
        </div>
      </Field>
    </div>
  )
}

// ---------------------------------------------------------------------------

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

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="mb-1 text-[11px] tracking-wider text-ink-4 uppercase">{label}</div>
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

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}
