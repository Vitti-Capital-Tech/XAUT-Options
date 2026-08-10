import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { StrategyApi } from '../hooks/useAutoStrategy'
import { Field, NumInput, RunSwitch, Select, TimePicker } from './controls'

/**
 * The auto-strategy's controls — a compact bar above its trades table. The rule
 * is fixed (sell a call on a red 1h candle, a put on a green, stop at twice
 * entry), so there is nothing to toggle there; only whether it runs, the strike,
 * the size and the window. The positions and trade history it produces sit in
 * the panel below, on the strategy's own account.
 *
 * The window is both ends of the day: the engine sells only inside it, and
 * flattens the account once past it, so nothing is carried overnight.
 */
export function StrategyTab({ strategy }: { strategy: StrategyApi }) {
  const { config, setConfig, armed, setArmed, hasAccount } = strategy
  // The one all-day window the pickers can express — it has no outside, so the
  // account is never force-closed.
  const allDay = config.windowStart === '00:00' && config.windowEnd === '23:59'

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-4 border-b border-line bg-raised px-5 py-3.5">
      <Field label="Strike">
        <Select
          value={config.moneyness}
          onChange={(m) => setConfig({ moneyness: m })}
          options={MONEYNESS_ORDER.map((m) => ({ value: m, label: label(m) }))}
        />
      </Field>

      <Field label="Quantity">
        <NumInput
          value={config.qty}
          min={1}
          step={1}
          unit="XAUT"
          width="w-24"
          onChange={(qty) => setConfig({ qty })}
        />
      </Field>

      <Field label="Window · IST">
        <div className="flex items-center gap-2">
          <TimePicker value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
          <span className="text-ink-4">–</span>
          <TimePicker value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
        </div>
      </Field>

      {/* Say which of the two the window is doing, since an all-day one gates
          nothing and never flattens. */}
      <span className="self-center text-[11px] text-ink-3">
        {allDay
          ? 'All day — nothing is force-closed'
          : `Flat outside ${config.windowStart}–${config.windowEnd}`}
      </span>

      {/* Run / pause, held to the right so the controls read left-to-right and
          the switch sits on its own. */}
      <div className="ml-auto flex items-center gap-3">
        <span className={`text-[15px] font-semibold ${armed ? 'text-pos' : 'text-ink-3'}`}>
          {armed ? 'Running' : 'Paused'}
        </span>
        <RunSwitch
          on={armed}
          onChange={setArmed}
          disabled={!hasAccount}
          title={
            hasAccount
              ? armed
                ? 'Pause auto-trade'
                : 'Run auto-trade'
              : 'Create an auto account first'
          }
        />
      </div>
    </div>
  )
}

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}
