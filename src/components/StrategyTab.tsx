import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { StrategyApi } from '../hooks/useAutoStrategy'
import { DayPicker, Field, NumInput, RunSwitch, Select, TimePicker } from './controls'

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

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-4 border-b border-line bg-raised px-5 py-3.5">
      <Field
        label="Strike"
        help="How far out of the money to sell, stepping off the listed strike nearest spot. Clamped to the listed wings rather than skipping the trade."
      >
        <Select
          value={config.moneyness}
          onChange={(m) => setConfig({ moneyness: m })}
          options={MONEYNESS_ORDER.map((m) => ({ value: m, label: label(m) }))}
        />
      </Field>

      <Field
        label="Quantity"
        help="Underlying units sold each time it fires, converted to lots at placement."
      >
        <NumInput
          value={config.qty}
          min={1}
          step={1}
          unit="XAUT"
          width="w-24"
          onChange={(qty) => setConfig({ qty })}
        />
      </Field>

      <Field
        label="Window · IST"
        help="Trading hours on the IST clock. Inside it the strategy sells; past the end it stops and flattens whatever it holds, so nothing is carried overnight."
      >
        <div className="flex items-center gap-2">
          <TimePicker value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
          <span className="text-ink-4">–</span>
          <TimePicker value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
        </div>
      </Field>

      <Field
        label="Days · IST"
        help="Weekdays it trades. A day switched off is treated as out of session, so the flatten covers it — it can never be left holding a position through a day it does not trade."
      >
        <DayPicker value={config.tradeDays} onChange={(tradeDays) => setConfig({ tradeDays })} />
      </Field>

      {/* Which expiry an entry lands in. 'Today only' skips the bar when XAUT
          lists no same-day contract, or once the same-day one has settled at
          21:30 IST — deliberately, since selling a multi-day option in its place
          is what the rule exists to stop. */}
      <Field
        label="Expiry"
        help="Today only sells the same-day contract and skips the bar when there is none — XAUT does not list one every day, and the same-day contract settles at 21:30 IST. Nearest live takes the nearest unsettled expiry instead, whatever its date."
      >
        <Select
          value={config.expiryRule}
          width="w-32"
          onChange={(expiryRule) => setConfig({ expiryRule })}
          options={[
            { value: 'today', label: 'Today only' },
            { value: 'nearest', label: 'Nearest live' },
          ]}
        />
      </Field>

      {/* The premium floor: a bar whose strike is bid under this is skipped
          rather than sold. Zero turns the filter off. */}
      <Field
        label="Min premium"
        help="Floor on the bid. A bar whose strike is bid below this is skipped, not sold — it never hunts for a richer strike, since the strike is the Strike setting's to choose."
      >
        <NumInput
          value={config.minPremium}
          min={0}
          step={0.5}
          unit="$"
          width="w-16"
          onChange={(minPremium) => setConfig({ minPremium })}
        />
      </Field>

      {/* No days selected disables the strategy outright, which is worth saying
          out loud — the run switch still reads "Running". */}
      {config.tradeDays.length === 0 && (
        <span className="self-center text-[11px] text-warn">No days selected — nothing will trade</span>
      )}

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
