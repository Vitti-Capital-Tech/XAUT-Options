import { useState } from 'react'
import { useMarketTick } from '../lib/marketStore'
import { expiryIsLive, expiryOptions, type Expiry } from '../lib/delta'
import type { DeltaStrategyApi } from '../hooks/useDeltaStrategy'
import { greek, price } from '../lib/format'
import {
  CollapseToggle,
  DayPicker,
  Field,
  GroupRule,
  NumInput,
  RunSwitch,
  Select,
  TimePicker,
  useSticky,
} from './controls'

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
  const { config, setConfig, armed, setArmed, session, hasAccount, plan, error, refresh, entryLots, apply, cancel, dirty } =
    strategy
  const [refreshing, setRefreshing] = useState(false)
  // Open by default: a bar that starts folded hides the settings from someone who
  // has never seen them. Each tab remembers its own.
  const [collapsed, setCollapsed] = useSticky('delta-paper.delta.collapsed', false)

  const expiryChoices = expiryOptions(expiries, config.expiryLabel)
  const expiryLive = expiryIsLive(expiries, config.expiryLabel)
  // With nothing chosen the engine trades the nearest, so show that as selected
  // rather than an empty box — the displayed date is the one it will trade.
  const expiryValue = config.expiryLabel ?? expiries[0]?.label ?? ''
  // The plan is rebuilt on the engine's own cycle, but Δp moves with every tick;
  // subscribing keeps the band meter honest between cycles.
  useMarketTick()

  const dp = plan?.dp ?? null
  const gp = plan?.gp ?? null
  // The band the engine is actually judging Δp against — derived from Γp when a
  // multiplier is set, the typed-in pair otherwise. The meter and the breach
  // colour both read this rather than the config, or they would draw one band
  // while the strategy defended another.
  const band = plan?.band ?? { low: config.bandLow, high: config.bandHigh, derived: false }
  const callsLeft = Math.max(0, config.maxRolls - session.rollsUsedCall)
  const putsLeft = Math.max(0, config.maxRolls - session.rollsUsedPut)

  return (
    <div className="border-b border-line bg-raised">
      {/* Controls, in the order the rules are applied and a trader reasons: when it
          trades, what it sells at the open, the band it defends, how it rolls and
          corrects, where it exits, how often it looks. A hairline at each seam, since
          sixteen fields in one row otherwise read as a wall.

          Two zones rather than one wrapping row: the settings wrap among themselves
          on the left, the actions keep a rail of their own on the right. Wrapping
          them together is what stranded Cancel/Apply on a line of their own. */}
      <div className="flex items-center gap-x-5 px-5 py-3.5">
        {/* First in the bar, so it holds the same spot whether the settings are
            showing or not. Only the settings fold — the readout strips below stay,
            which is the point: folded, this bar is a monitor rather than a form. */}
        <CollapseToggle collapsed={collapsed} onToggle={() => setCollapsed(!collapsed)} />

        {!collapsed && (
        <div className="flex min-w-0 flex-1 flex-wrap items-start gap-x-6 gap-y-4">
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

          <GroupRule />

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

          {/* The one price rule the strategy has: every sale — the open, a roll
              replacement, a band correction — takes the strike quoted closest to
              this. A separate floor used to sit beside it and is gone: asking for
              the closest to a price already decides what may be sold. */}
          <Field
            label="Entry premium"
            help="The premium to aim for. It sells whichever strike is quoted closest to this — at the open, when rolling a leg further out, and when correcting the band."
          >
            <NumInput
              value={config.entryPremium}
              step={0.5}
              min={0}
              unit="$"
              width="w-20"
              onChange={(v) => setConfig({ entryPremium: v })}
            />
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

          {/* Size in XAUT, the way the auto tab expresses it, with the lots it works
              out to beside the box — lots are what Δp actually counts, so seeing them
              is the difference between a sane band and a permanently breached one. */}
          <Field
            label="Qty · XAUT"
            help="How much to sell of each option, in XAUT — the same idea as Quantity on the auto tab, and the spec's N expressed in XAUT rather than lots. Careful: position delta counts lots, so doubling this doubles the delta. Raise Target delta band by the same amount or it will sit outside it all day."
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

          <GroupRule />

          <Field
            label="Target delta band"
            help="The delta of everything you hold, added up. Inside this range it does nothing at all; outside it, it fixes the position. This is the whole position, not one option — so it can be any size, and negatives are fine. −2 to 1 is a valid range. With a gamma multiplier set, these two are only the fallback — the live band is derived instead."
          >
            {/* Two inputs while the numbers are yours; the range itself once gamma
                computes it. The field shows the band actually in force either way,
                which is also what keeps the fallback editable in exactly the case
                where the fallback is what is being used. */}
            {band.derived ? (
              <span className="num rounded border border-raised-3 bg-surface px-2.5 py-1 text-[13px] whitespace-nowrap text-brand-text">
                {greek(band.low, 2)} – {greek(band.high, 2)}
              </span>
            ) : (
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
            )}
          </Field>

          <Field
            label="Gamma multiplier"
            help="Ties the range's width to the position's own gamma instead of holding it fixed: the range becomes ± total gamma × this number, recomputed every cycle. At a total gamma of 0.5, a multiplier of 2 gives −1 to 1, and the range widens on its own as gamma grows. 0 switches it off and the two numbers above are used as typed."
          >
            {/* No arithmetic printed beside it: the band field above already shows
                the range this produces, and the same sum written twice in one row
                is noise. */}
            <NumInput
              value={config.gammaMultiplier}
              step={0.5}
              min={0}
              width="w-16"
              onChange={(v) => setConfig({ gammaMultiplier: v })}
            />
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

          <GroupRule />

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

          {/* A band-correction delta range used to sit here, picking the fresh sell
              by delta instead of by price. It is gone: corrections take the same
              Entry premium every other sale does, so there is one price rule on
              screen rather than two that have to be kept in step. */}

          <GroupRule />

          {/* Both brackets, as prices on the option's own mark: the take-profit fires
              as the mark falls, the stop as it rises. Zero on either arms nothing —
              which for the stop is the rules document's own behaviour. */}
          <Field
            label="TP mark"
            help="Any option it sold is bought back once its price falls to this — the take-profit. At $0.70, a leg sold for $4 closes at 70 cents and you keep most of the premium. It is a price on the option's own mark, not a percentage. Zero arms no take-profit."
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

          <Field
            label="SL mark"
            help="The other way: a sold option is bought back once its price rises to this. A leg sold for $4 with SL 8 closes at $8, giving back the whole premium. Zero arms no stop — which is what the rules document specifies, since the roll budget and exit-only mode are meant to be the risk control. Set it generously if at all: a losing leg is the one the roll logic exists to fix, and a stop closes it instead."
          >
            <NumInput
              value={config.stopLossMark}
              step={0.5}
              min={0}
              unit="$"
              width="w-16"
              onChange={(v) => setConfig({ stopLossMark: v })}
            />
          </Field>

          <GroupRule />

          {/* The margin guard. Every rule above answers to Δp; these two answer to
              equity, and they outrank the lot — because the band correction sells a
              fresh leg nothing ever pairs off, so margin ratchets up on its own while
              losses pull equity down. Cut-at fires the cut, cut-to releases it, and
              the gap between them is what stops the control flapping. */}
          <Field
            label="Cut at"
            help="Once the margin your open positions block passes this share of your equity, the strategy stops selling and starts closing legs instead — deepest in-the-money first, preferring the side that pulls delta back into the band, and booking the loss. 100% means it acts the moment margin exceeds equity. Zero switches the guard off entirely."
          >
            <NumInput
              value={config.marginCapPct}
              step={5}
              min={0}
              unit="%"
              width="w-16"
              onChange={(v) => setConfig({ marginCapPct: v })}
            />
          </Field>

          <Field
            label="Cut to"
            help="How far a cut goes: it closes just enough to bring margin down to this share of equity, and no more, so the realised loss is the smallest one that clears the breach. Between this and Cut at the book is held — no new entry and no band correction — but rolls carry on, since a roll closes and re-sells the same size and so cannot grow the book."
          >
            <NumInput
              value={config.marginTargetPct}
              step={5}
              min={0}
              unit="%"
              width="w-16"
              onChange={(v) => setConfig({ marginTargetPct: v })}
            />
          </Field>

          <GroupRule />

          {/* The interval, plus a way to skip the wait. The button clears the spacing
              the engine checks, so its next tick acts — the engine runs once a minute,
              so this brings a cycle forward to within that, not to this instant. */}
          <Field
            label="Refresh"
            help="How often it looks at the position and acts. One action per check, never several at once. The engine itself wakes every 5 seconds, so 5 is as fast as this goes — set it higher to make it act less often. The button skips the wait, so the next check happens within about 5 seconds rather than instantly."
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

        </div>
        )}

        {/* Folded away, the settings zone stops carrying flex-1, so the rail would
            slide left against the toggle. This keeps it out on the right. */}
        {collapsed && <div className="min-w-0 flex-1" />}

        {/* The action rail: what you do to the settings, then whether the strategy is
            live. Held out of the wrap and behind a hairline so it reads as its own
            zone rather than one more field — the same rail the auto strategy wears.
            Never folded — pausing a live strategy must not be behind a disclosure. */}
        <div className="flex shrink-0 items-center gap-3 self-center border-l border-line pl-5">
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={cancel}
              disabled={!dirty}
              title="Discard the unsaved changes and go back to the saved settings"
              className="flex h-9 shrink-0 items-center rounded-md border border-raised-3 bg-surface px-3.5 text-[12px] font-medium text-ink-2 transition-colors hover:border-ink-3 hover:text-ink disabled:pointer-events-none disabled:opacity-40"
            >
              Cancel
            </button>
            <button
              type="button"
              onClick={() => void apply()}
              disabled={!dirty}
              title="Save every changed field and apply the TP/SL to open positions"
              className="flex h-9 shrink-0 items-center rounded-md border border-pos-on-muted bg-pos-muted px-3.5 text-[12px] font-medium text-pos transition-colors hover:border-pos hover:bg-pos-on-muted disabled:pointer-events-none disabled:opacity-40"
            >
              Apply
            </button>
          </div>
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

      {/* Readout, in two strips.

          Δp is the one number this strategy is actually about, so it leads at a size
          nothing else competes with, and the band meter sits directly under it as
          part of the same reading rather than as a sixth equal statistic. The old
          `Band` figure is gone: the meter prints those two numbers at its ends now,
          and a readout that repeats its neighbour is noise.

          The next action is a sentence, not a statistic, so it gets its own strip
          and the full width — right-aligned in the stat row it truncated exactly
          when it had most to say.

          Folded away with the settings. This bar sits on top of the chain, so
          "collapsed" has to mean the bar is out of the way — leaving three strips
          behind gave back only the shortest of the rows it was taking. What stays
          is the rail and, below, any error: one is how you stop the strategy, the
          other is the thing you must not have to go looking for. */}
      {!collapsed && (
      <>
      <div className="flex flex-wrap items-center gap-x-7 gap-y-4 border-t border-line px-5 py-3">
        {/* The hero: Δp over its own meter. */}
        <div className="flex items-end gap-4">
          <div className="flex flex-col gap-0.5">
            <span className="text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
              Net Δp
            </span>
            <span
              className={`num text-[26px] leading-none font-semibold tracking-tight ${
                plan?.breach ? 'text-brand-text' : 'text-ink'
              }`}
            >
              {dp === null ? '—' : greek(dp, 2)}
            </span>
          </div>
          <BandMeter low={band.low} high={band.high} dp={dp} derived={band.derived} />
        </div>

        <GroupRule />

        {/* Γp, beside the band it now sets. Shown whenever the multiplier is on,
            including while Γp is still missing — the band being derived is the
            fact worth surfacing, and an em dash says the derivation has not run
            yet rather than hiding that it is meant to. */}
        {config.gammaMultiplier > 0 && (
          <Readout label={`Net Γp × ${config.gammaMultiplier}`} tone={band.derived ? 'ok' : 'warn'}>
            {gp === null ? '—' : greek(gp, 3)}
          </Readout>
        )}

        {/* State: what the session is doing and what it has spent. */}
        <PhaseChip label={plan ? phaseLabel(plan.phase, plan.tradingDay) : '—'} open={plan?.phase === 'open'} />
        <Readout label="ITM queue">{plan ? plan.queue.length : '—'}</Readout>
        <Readout label="Rolls left C / P" tone={callsLeft === 0 || putsLeft === 0 ? 'warn' : 'ok'}>
          {callsLeft} / {putsLeft}
        </Readout>

        <GroupRule />

        {/* The two marks every short is bought back at, take-profit then stop. An
            em dash when neither is armed, rather than the word "none" twice. */}
        <Readout label="TP / SL">
          {config.takeProfitMark <= 0 && config.stopLossMark <= 0 ? (
            '—'
          ) : (
            <>
              {config.takeProfitMark > 0 ? price(config.takeProfitMark, 2) : '—'}
              <span className="text-ink-4"> / </span>
              {config.stopLossMark > 0 ? price(config.stopLossMark, 2) : '—'}
            </>
          )}
        </Readout>

        {/* Blocked margin against equity — the guard's own number, so a trader can
            see a cut coming rather than only reading about it after the fact. Warn
            in the hold zone, bad once it is cutting; an em dash when equity is zero,
            because a ratio against nothing says nothing. */}
        <Readout
          label="Margin / equity"
          tone={plan?.margin?.cut ? 'bad' : plan?.margin?.hold ? 'warn' : 'ok'}
        >
          {plan?.margin == null
            ? '—'
            : plan.margin.pct === null
              ? 'over'
              : `${plan.margin.pct.toFixed(0)}%`}
        </Readout>
      </div>

      {/* What it is about to do, in its own strip so a long reason reads in full.
          Recomputed here every two seconds from the same rules the engine runs, so
          it also answers the question a log would — why nothing is happening: an
          entry held back by margin, a greek that has not arrived, a breach under
          one contract. Why it did something is on the row it produced, as Entry
          Reason in Positions and Exit Reason in Trade History. */}
      <div className="flex min-w-0 items-baseline gap-2.5 border-t border-line px-5 py-2">
        <span className="shrink-0 text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
          Next
        </span>
        <span className="truncate text-[12.5px] text-ink-2">{plan?.reason ?? 'Starting up…'}</span>
      </div>
      </>
      )}

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
  /** 'warn' is the brand highlight, as the roll budget uses it; 'bad' is the loss
   *  colour, kept for a reading that means the engine is closing at a loss now. */
  tone?: 'ok' | 'warn' | 'bad'
}) {
  const colour = tone === 'bad' ? 'text-neg' : tone === 'warn' ? 'text-brand-text' : 'text-ink'
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-[9px] font-semibold tracking-[0.14em] text-ink-3 uppercase">{label}</span>
      <span className={`num text-[13px] font-semibold ${colour}`}>{children}</span>
    </div>
  )
}

/**
 * Δp against its band, as a bar. The band fills the width and the marker is
 * clamped to the ends, so a breach reads as pinned to an edge rather than
 * disappearing off it.
 */
function BandMeter({
  low,
  high,
  dp,
  derived,
}: {
  low: number
  high: number
  dp: number | null
  /** Gamma set these ends, so they move on their own — marked, not just drawn. */
  derived: boolean
}) {
  const span = high - low
  const frac = dp === null || !(span > 0) ? null : Math.min(1, Math.max(0, (dp - low) / span))
  const breached = dp !== null && (dp < low || dp > high)

  // No eyebrow of its own: it sits under the Net Δp figure, which names it, and the
  // two end labels say what the track spans. A third label would only repeat one of
  // the other two.
  //
  // A derived band's ends are printed in the brand ink: they are a live reading
  // rather than a setting, and a number that moves by itself should not look the
  // same as one that was typed.
  const endInk = derived ? 'text-brand-text' : 'text-ink-3'
  return (
    <div
      className="flex w-56 items-center gap-2 pb-0.5"
      title={derived ? 'Band width is Γp × the gamma multiplier' : undefined}
    >
      <span className={`num shrink-0 text-[10px] ${endInk}`}>{price(low, 2)}</span>
      <div className="relative h-1.5 flex-1 rounded-full border border-raised-3 bg-surface">
        {/* The mid-point, so the marker's drift off centre reads at a glance. */}
        <span className="absolute top-1/2 left-1/2 h-2 w-px -translate-x-1/2 -translate-y-1/2 bg-raised-3" />
        {frac !== null && (
          <span
            className={`absolute top-1/2 h-3 w-[3px] -translate-x-1/2 -translate-y-1/2 rounded-full transition-all duration-300 ${
              breached ? 'bg-brand-text' : 'bg-pos-solid'
            }`}
            style={{ left: `${frac * 100}%` }}
          />
        )}
      </div>
      <span className={`num shrink-0 text-[10px] ${endInk}`}>{price(high, 2)}</span>
    </div>
  )
}

/**
 * The session's state as a chip rather than a label-and-value pair.
 *
 * It is the one readout that is a state rather than a number, and a live dot says
 * "trading" faster than the word does. Off day and Closed both read muted — the
 * distinction between them is in the word, not the colour, because neither is a
 * condition to act on.
 */
function PhaseChip({ label, open }: { label: string; open: boolean }) {
  return (
    <span
      className={`flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium ${
        open ? 'border-pos-on-muted bg-pos-muted text-pos' : 'border-raised-3 bg-raised-2 text-ink-3'
      }`}
    >
      <span
        className={`h-1.5 w-1.5 rounded-full ${open ? 'bg-pos-solid' : 'bg-ink-4'}`}
        aria-hidden
      />
      {label}
    </span>
  )
}

/**
 * Keep the two ends of the delta range the right way round.
 *
 * `band_low < band_high` — the doc's [L, U] — is a database constraint, and neither
 * box can police it
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
