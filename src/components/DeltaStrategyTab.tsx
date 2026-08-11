import { useState } from 'react'
import { useMarketTick } from '../lib/marketStore'
import { expiryIsLive, expiryOptions, type Expiry } from '../lib/delta'
import type { DeltaStrategyApi } from '../hooks/useDeltaStrategy'
import { greek, price } from '../lib/format'
import { DayPicker, Field, NumInput, RunSwitch, Select, TimePicker } from './controls'

/**
 * The Delta Management Strategy's controls — the same shape of bar the auto
 * strategy wears, with the parameters the rules spec actually names: the trading
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
export function DeltaStrategyTab({
  strategy,
  expiries,
}: {
  strategy: DeltaStrategyApi
  expiries: Expiry[]
}) {
  const { config, setConfig, armed, setArmed, session, hasAccount, plan, error, refresh, entryLots } =
    strategy
  const [refreshing, setRefreshing] = useState(false)

  const expiryChoices = expiryOptions(expiries, config.expiryLabel)
  const expiryLive = expiryIsLive(expiries, config.expiryLabel)
  // With nothing chosen the engine trades the nearest, so show that as selected
  // rather than an empty box — the displayed date is the one it will trade.
  const expiryValue = config.expiryLabel ?? expiries[0]?.label ?? ''
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
        <Field
          label="Session · IST"
          help="When it trades, on the IST clock. It sells the pair at the start and buys everything back at the end, so nothing is held overnight."
        >
          <div className="flex items-center gap-2">
            <TimePicker value={config.sessionOpen} onChange={(v) => setConfig({ sessionOpen: v })} />
            <span className="text-ink-4">–</span>
            <TimePicker value={config.sessionClose} onChange={(v) => setConfig({ sessionClose: v })} />
          </div>
        </Field>

        {/* The days the session runs. A day left out reads as a closed session: the
            book is flattened and nothing new is opened. The readout's Session field
            says which it is. */}
        <Field
          label="Trading days"
          help="Which days it trades. A day switched off is treated as closed: everything is bought back and nothing new is opened."
        >
          <DayPicker value={config.tradeDays} onChange={(tradeDays) => setConfig({ tradeDays })} />
        </Field>

        <Field
          label="[L, U]"
          help="The delta of everything you hold, added up. Inside this range it does nothing at all; outside it, it fixes the position. This is the whole position, not one option — so it can be any size, and negatives are fine. −2 to 1 is a valid range."
        >
          <div className="flex items-center gap-2">
            <NumInput
              value={config.bandLow}
              step={0.1}
              width="w-16"
              onChange={(v) => setConfig({ bandLow: keepBelow(v, config.bandHigh) })}
            />
            <span className="text-ink-4">–</span>
            <NumInput
              value={config.bandHigh}
              step={0.1}
              width="w-16"
              onChange={(v) => setConfig({ bandHigh: keepAbove(v, config.bandLow) })}
            />
          </div>
        </Field>

        <Field
          label="Target landing"
          help="Once it starts fixing, where should the position delta end up — back at the edge you crossed, or all the way to the middle of the range? The middle moves the position a lot further."
        >
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

        <Field
          label="B (buffer)"
          help="How far back inside the range to come, rather than stopping on the line. At 0 it aims for the line itself, which usually works out to zero contracts and so does nothing — 0.4 is what makes fixes actually happen."
        >
          <NumInput
            value={config.bandBuffer}
            step={0.05}
            min={0}
            width="w-16"
            onChange={(v) => setConfig({ bandBuffer: v })}
          />
        </Field>

        <Field
          label="ITM trigger"
          help="How far past its strike gold must be before that sold option can be fixed. On its own this never starts anything — the position delta leaving its range is what does."
        >
          <NumInput
            value={config.itmTrigger}
            step={1}
            min={0}
            unit="pts"
            width="w-16"
            onChange={(v) => setConfig({ itmTrigger: v })}
          />
        </Field>

        <Field
          label="Max rolls per side"
          help="How many times a day the calls (or the puts) can be fixed by moving them further out. Once used up, the next problem on that side is closed in full and the loss taken. This is the risk control — there is no stop-loss."
        >
          <NumInput
            value={config.maxRolls}
            step={1}
            min={0}
            width="w-16"
            onChange={(v) => setConfig({ maxRolls: Math.round(v) })}
          />
        </Field>

        <Field
          label="Count rolls by"
          help="A fix buys back part of the option that is hurting and sells the same type further out. This decides whether one round of fixing counts as one, or every strike it touches counts as one."
        >
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

        <Field
          label="Entry premium / min premium"
          help="Left: the premium to aim for — it picks whichever strike is quoted closest to this. Right: a hard floor. Nothing is ever sold cheaper than this, anywhere."
        >
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

        <Field
          label="Band correction delta"
          help="When there is nothing left to fix and it has to sell a fresh option, this is how big that one option's delta should be — not the whole position's, which is [L, U]. Keep it small so each contract moves the position a little — 0.15 to 0.25. One option's delta is always between −1 and 1, so this can never be −2. Ignore the sign: 0.15–0.25 already matches a put at −0.20."
        >
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

        {/* Size in XAUT, the way the auto tab expresses it, with the lots it works
            out to beside the box — lots are what Δp actually counts, so seeing them
            is the difference between a sane band and a permanently breached one. */}
        <Field
          label="Qty · XAUT"
          help="How much to sell of each option, in XAUT — the same idea as Quantity on the auto tab, and the spec's N expressed in XAUT rather than lots. Careful: position delta counts lots, so doubling this doubles the delta. Raise [L, U] by the same amount or it will sit outside it all day."
        >
          <div className="flex items-center gap-2">
            <NumInput
              value={config.qty}
              step={0.001}
              min={0.001}
              width="w-20"
              onChange={(v) => setConfig({ qty: v })}
            />
            <span className="text-[11px] whitespace-nowrap text-ink-3">
              {entryLots === null ? '—' : `${entryLots} lot${entryLots === 1 ? '' : 's'} / leg`}
            </span>
          </div>
        </Field>

        <Field
          label="Tie goes to"
          help="When two strikes are priced about equally close to what you asked for, this decides which one wins."
        >
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

        {/* The listed expiries by date, as the chain's tabs show them. A date does
            not roll: once the chosen one settles the cycle stands down rather than
            moving to a contract nobody picked, so the stale case is called out. */}
        <Field
          label="Expiry"
          help="Which expiry to trade, by date. The date does not move on its own — once that expiry is gone, trading stops until you pick a new one. It will never quietly switch to a different one."
        >
          <div className="flex items-center gap-2">
            <Select
              value={expiryValue}
              width="w-32"
              onChange={(v) => setConfig({ expiryLabel: v })}
              options={expiryChoices}
            />
            {!expiryLive && (
              <span className="text-[11px] whitespace-nowrap text-warn">Settled — pick a date</span>
            )}
          </div>
        </Field>

        {/* The interval, plus a way to skip the wait. The button clears the spacing
            the engine checks, so its next tick acts — the engine runs once a minute,
            so this brings a cycle forward to within that, not to this instant. */}
        <Field
          label="Refresh"
          help="How often it looks at the position and acts. One action per check, never several at once. The button skips the wait so the next check happens sooner — it runs every minute, so that means within a minute, not instantly."
        >
          <div className="flex items-center gap-2">
            <NumInput
              value={config.cycleSeconds}
              step={5}
              min={5}
              unit="s"
              width="w-16"
              onChange={(v) => setConfig({ cycleSeconds: Math.round(v) })}
            />
            <button
              type="button"
              disabled={!hasAccount || refreshing}
              title={
                hasAccount
                  ? 'Run a cycle now — clears the wait so the next engine tick acts'
                  : 'Create a delta account first'
              }
              onClick={() => {
                setRefreshing(true)
                void refresh().finally(() => setRefreshing(false))
              }}
              className="flex h-9 items-center gap-1.5 rounded-md border border-raised-3 bg-surface px-2.5 text-[12px] text-ink-2 transition-colors hover:border-ink-3 hover:text-ink disabled:opacity-40"
            >
              <RefreshIcon spinning={refreshing} />
              {refreshing ? 'Queued' : 'Now'}
            </button>
          </div>
        </Field>

        {/* Take profit as a price on the option's own mark — 0.7 buys any short
            leg back at $0.70, whatever it sold for. No stop is ever set. */}
        <Field
          label="TP mark"
          help="Any option it sold is bought back once its price falls to this — the take-profit. At $0.70, a leg sold for $4 closes at 70 cents and you keep most of the premium. It is a price on the option's own mark, not a percentage. No stop-loss is ever set."
        >
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
        <div className="border-t border-line px-5 py-2 text-[12px] text-neg">Settings not saved — {error}</div>
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
    <div className="flex w-56 flex-col gap-1">
      <span className="text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">Δp in band</span>
      {/* The set range at each end, so the marker's position reads against real
          numbers rather than an unlabelled track. */}
      <div className="flex items-center gap-2">
        <span className="num shrink-0 text-[10px] text-ink-3">{price(low, 2)}</span>
        <div className="relative h-2 flex-1 rounded-full border border-raised-3 bg-surface">
          {frac !== null && (
            <span
              className={`absolute top-1/2 h-3 w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-full ${
                breached ? 'bg-brand-text' : 'bg-pos-solid'
              }`}
              style={{ left: `${frac * 100}%` }}
            />
          )}
        </div>
        <span className="num shrink-0 text-[10px] text-ink-3">{price(high, 2)}</span>
      </div>
    </div>
  )
}

/**
 * Keep the two ends of the delta range the right way round.
 *
 * `band_low < band_high` — the doc's [L, U] — is a database constraint, and neither
 * box can enforce it
 * alone — set the low end above the high one and the write is rejected *after* the
 * box already shows the new number, which reads as the app breaking rather than as
 * a value it will not take. Clamping to a step short of the other end keeps the
 * pair valid, and rounding kills the 0.30000000000000004 the subtraction produces.
 */
const STEP = 0.1

function keepBelow(v: number, high: number): number {
  return Math.round(Math.min(v, high - STEP) * 100) / 100
}

function keepAbove(v: number, low: number): number {
  return Math.round(Math.max(v, low + STEP) * 100) / 100
}

/** Circular arrow, spun while a manual refresh is in flight. */
function RefreshIcon({ spinning }: { spinning: boolean }) {
  return (
    <svg
      width="12"
      height="12"
      viewBox="0 0 16 16"
      fill="none"
      className={`shrink-0 ${spinning ? 'motion-safe:animate-spin' : ''}`}
      aria-hidden
    >
      <path
        d="M13.5 8a5.5 5.5 0 1 1-1.8-4.07"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
      <path d="M13.6 1.6v3h-3" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function phaseLabel(phase: 'before' | 'open' | 'closed', tradingDay: boolean): string {
  // A day left out of the filter reports 'closed'; say which kind of closed it
  // is, so a deselected weekday does not read as a session that has just ended.
  if (!tradingDay) return 'Off day'
  if (phase === 'open') return 'Open'
  return phase === 'before' ? 'Pre-open' : 'Closed'
}
