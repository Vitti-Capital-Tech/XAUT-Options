import { useMarketTick } from '../lib/marketStore'
import type { DeltaStrategyApi } from '../hooks/useDeltaStrategy'
import { greek, price } from '../lib/format'
import { DayPicker, Field, NumInput, RunSwitch, Select, TimePicker } from './controls'

/**
 * The Delta Management Strategy's controls — the same shape of bar the auto
 * strategy wears, with the parameters the rules spec actually names: the Sydney
 * session, the delta band and where a correction lands in it, the ITM trigger
 * and roll budget, the entry and floor premiums, and the delta range fresh
 * out-of-the-money sells are picked from.
 *
 * Below the controls sits the readout — net portfolio delta against the band,
 * the roll budget each side has left, and the one line saying what the engine is
 * about to do next. The positions and trade history it produces are in the panel
 * under this, on the strategy's own delta account.
 *
 * The engine runs server-side on pg_cron, so the switch here arms it and it
 * trades with the tab closed. Every default is the spec's own figure; the nine
 * items the spec leaves OPEN are the controls with no number in the document —
 * target_landing, what counts as a roll, N, the strike tie-break, expiry
 * selection and the cycle frequency — so the choice is on screen rather than
 * buried in an engine.
 */
export function DeltaStrategyTab({ strategy }: { strategy: DeltaStrategyApi }) {
  const { config, setConfig, armed, setArmed, session, hasAccount, plan, error } = strategy
  // The plan is rebuilt on the engine's own cycle, but Δp moves with every tick;
  // subscribing keeps the band meter honest between cycles.
  useMarketTick()

  const dp = plan?.dp ?? null
  const callsLeft = Math.max(0, config.maxRolls - session.rollsUsedCall)
  const putsLeft = Math.max(0, config.maxRolls - session.rollsUsedPut)

  return (
    <div className="border-b border-line bg-raised">
      {/* Controls. One wrapping row, the way the auto strategy's is — there are
          simply more of them here. */}
      <div className="flex flex-wrap items-start gap-x-6 gap-y-4 px-5 py-3.5">
        <Field label="Session · Sydney">
          <div className="flex items-center gap-2">
            <TimePicker value={config.sessionOpen} onChange={(v) => setConfig({ sessionOpen: v })} />
            <span className="text-ink-4">–</span>
            <TimePicker value={config.sessionClose} onChange={(v) => setConfig({ sessionClose: v })} />
          </div>
        </Field>

        {/* The days the session runs, on the session's own clock. A day left out
            reads as a closed session: the book is flattened and nothing new is
            opened. The readout's Session field says which it is. */}
        <Field label="Days · Sydney">
          <DayPicker value={config.tradeDays} onChange={(tradeDays) => setConfig({ tradeDays })} />
        </Field>

        <Field label="Band L / U">
          <div className="flex items-center gap-2">
            <NumInput value={config.bandLow} step={0.1} width="w-16" onChange={(v) => setConfig({ bandLow: v })} />
            <span className="text-ink-4">–</span>
            <NumInput value={config.bandHigh} step={0.1} width="w-16" onChange={(v) => setConfig({ bandHigh: v })} />
          </div>
        </Field>

        <Field label="Lands on">
          <Select
            value={config.targetLanding}
            width="w-32"
            onChange={(v) => setConfig({ targetLanding: v })}
            options={[
              { value: 'edge', label: 'Breached edge' },
              { value: 'mid', label: 'Band midpoint' },
            ]}
          />
        </Field>

        <Field label="Buffer B">
          <NumInput
            value={config.bandBuffer}
            step={0.05}
            min={0}
            width="w-16"
            onChange={(v) => setConfig({ bandBuffer: v })}
          />
        </Field>

        <Field label="ITM trigger">
          <NumInput
            value={config.itmTrigger}
            step={1}
            min={0}
            unit="pts"
            width="w-16"
            onChange={(v) => setConfig({ itmTrigger: v })}
          />
        </Field>

        <Field label="Max rolls / side">
          <NumInput
            value={config.maxRolls}
            step={1}
            min={0}
            width="w-16"
            onChange={(v) => setConfig({ maxRolls: Math.round(v) })}
          />
        </Field>

        <Field label="A roll is">
          <Select
            value={config.rollCounts}
            width="w-32"
            onChange={(v) => setConfig({ rollCounts: v })}
            options={[
              { value: 'pass', label: 'One pass' },
              { value: 'strike', label: 'Per strike' },
            ]}
          />
        </Field>

        <Field label="Entry / floor $">
          <div className="flex items-center gap-2">
            <NumInput
              value={config.entryPremium}
              step={0.5}
              min={0}
              width="w-16"
              onChange={(v) => setConfig({ entryPremium: v })}
            />
            <span className="text-ink-4">/</span>
            <NumInput
              value={config.minPremium}
              step={0.5}
              min={0}
              width="w-16"
              onChange={(v) => setConfig({ minPremium: v })}
            />
          </div>
        </Field>

        <Field label="Band Δ range">
          <div className="flex items-center gap-2">
            <NumInput
              value={config.bandDeltaLow}
              step={0.05}
              min={0}
              width="w-16"
              onChange={(v) => setConfig({ bandDeltaLow: v })}
            />
            <span className="text-ink-4">–</span>
            <NumInput
              value={config.bandDeltaHigh}
              step={0.05}
              min={0}
              width="w-16"
              onChange={(v) => setConfig({ bandDeltaHigh: v })}
            />
          </div>
        </Field>

        <Field label="N pairs">
          <NumInput
            value={config.pairs}
            step={1}
            min={0}
            width="w-16"
            onChange={(v) => setConfig({ pairs: Math.round(v) })}
          />
        </Field>

        <Field label="Tie-break">
          <Select
            value={config.tieBreak}
            width="w-32"
            onChange={(v) => setConfig({ tieBreak: v })}
            options={[
              { value: 'closest', label: 'Absolute closest' },
              { value: 'above', label: 'Nearest above' },
              { value: 'below', label: 'Nearest below' },
            ]}
          />
        </Field>

        <Field label="Expiry">
          <Select
            value={config.expiryPick}
            width="w-28"
            onChange={(v) => setConfig({ expiryPick: v })}
            options={[
              { value: 'nearest', label: 'Nearest' },
              { value: 'next', label: 'Next out' },
            ]}
          />
        </Field>

        <Field label="Cycle">
          <NumInput
            value={config.cycleSeconds}
            step={5}
            min={5}
            unit="s"
            width="w-16"
            onChange={(v) => setConfig({ cycleSeconds: Math.round(v) })}
          />
        </Field>

        {/* Take profit as a price on the option's own mark — 0.7 buys any short
            leg back at $0.70, whatever it sold for. No stop is ever set. */}
        <Field label="TP mark">
          <NumInput
            value={config.takeProfitMark}
            step={0.05}
            min={0}
            unit="$"
            width="w-16"
            onChange={(v) => setConfig({ takeProfitMark: v })}
          />
        </Field>

        {/* Run / pause, held to the right so the controls read left-to-right and
            the switch sits on its own — the same place the auto strategy's is. */}
        <div className="ml-auto flex items-center gap-3 self-center">
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
                  ? 'Pause the delta strategy'
                  : 'Run the delta strategy'
                : 'Create a delta account first'
            }
          />
        </div>
      </div>

      {/* Readout. Where Δp sits, what the session has spent, and the next move. */}
      <div className="flex flex-wrap items-center gap-x-6 gap-y-3 border-t border-line px-5 py-2.5">
        <Readout label="Net Δp" tone={plan?.breach ? 'warn' : 'ok'}>
          {dp === null ? '—' : greek(dp, 2)}
        </Readout>
        <Readout label="Band">
          {price(config.bandLow, 2)} – {price(config.bandHigh, 2)}
        </Readout>
        <Readout label="ITM queue">{plan ? plan.queue.length : '—'}</Readout>
        <Readout label="Rolls left C / P" tone={callsLeft === 0 || putsLeft === 0 ? 'warn' : 'ok'}>
          {callsLeft} / {putsLeft}
        </Readout>
        <Readout label="Session">
          {plan ? phaseLabel(plan.phase, plan.tradingDay) : '—'}
        </Readout>
        {/* The mark every short is bought back at. No stop, so there is nothing
            to show beside it. */}
        <Readout label="TP / SL">
          {config.takeProfitMark > 0 ? `${price(config.takeProfitMark, 2)} / none` : 'none / none'}
        </Readout>

        <BandMeter low={config.bandLow} high={config.bandHigh} dp={dp} />

        <div className="ml-auto flex min-w-0 items-center gap-2">
          <span className="shrink-0 text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
            Next
          </span>
          <span className="truncate text-[12px] text-ink-2">{plan?.reason ?? 'Starting up…'}</span>
        </div>
      </div>

      {error && (
        <div className="border-t border-line px-5 py-2 text-[12px] text-neg">Engine error — {error}</div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------

function Readout({
  label,
  children,
  tone = 'ok',
}: {
  label: string
  children: React.ReactNode
  tone?: 'ok' | 'warn'
}) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">{label}</span>
      <span className={`num text-[13px] font-semibold ${tone === 'warn' ? 'text-brand-text' : 'text-ink'}`}>
        {children}
      </span>
    </div>
  )
}

/**
 * Δp against its band, as a bar. The band fills the width and the marker is
 * clamped to the ends, so a breach reads as pinned to an edge rather than
 * disappearing off it.
 */
function BandMeter({ low, high, dp }: { low: number; high: number; dp: number | null }) {
  const span = high - low
  const frac = dp === null || !(span > 0) ? null : Math.min(1, Math.max(0, (dp - low) / span))
  const breached = dp !== null && (dp < low || dp > high)

  return (
    <div className="flex w-40 flex-col gap-1">
      <span className="text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">Δp in band</span>
      <div className="relative h-2 rounded-full border border-raised-3 bg-surface">
        {frac !== null && (
          <span
            className={`absolute top-1/2 h-3 w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-full ${
              breached ? 'bg-brand-text' : 'bg-pos-solid'
            }`}
            style={{ left: `${frac * 100}%` }}
          />
        )}
      </div>
    </div>
  )
}

function phaseLabel(phase: 'before' | 'open' | 'closed', tradingDay: boolean): string {
  // A day left out of the filter reports 'closed'; say which kind of closed it
  // is, so a deselected weekday does not read as a session that has just ended.
  if (!tradingDay) return 'Off day'
  if (phase === 'open') return 'Open'
  return phase === 'before' ? 'Pre-open' : 'Closed'
}
