import { MONEYNESS_ORDER, stopMultiple, takeProfitMultiple, type Moneyness } from '../lib/strategy'
import { expiryIsLive, expiryOptions, type Expiry } from '../lib/delta'
import type { StrategyApi } from '../hooks/useAutoStrategy'
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
 * The auto-strategy's controls — a compact bar above its trades table. The signal
 * is fixed (sell a call on a red 1h candle, a put on a green), so there is nothing
 * to toggle there; what is here is when it may trade, what it sells, and where the
 * bracket sits. The positions and trade history it produces are in the panel below,
 * on the strategy's own account.
 *
 * Trading hours are both ends of the day: it sells only inside them, and buys back
 * whatever it holds once past them, so nothing is carried overnight.
 *
 * The bar is grouped the way the delta strategy's is, and in the same order — when it
 * may trade, what it sells, then the bracket — so moving between the two tabs does
 * not mean relearning where anything is.
 *
 * Where a label needed explaining it says what the setting does; where the trading
 * term was already the clearest name — Strike, Quantity, Stop loss, Take profit —
 * it keeps it. Either way the `?` carries the explanation, because this bar is read
 * under time pressure and a wrong guess here costs money.
 */
export function StrategyTab({
  strategy,
  expiries,
}: {
  strategy: StrategyApi
  expiries: Expiry[]
}) {
  const { config, setConfig, armed, setArmed, hasAccount, apply, cancel, dirty } = strategy
  // Open by default: a bar that starts folded hides the settings from someone who
  // has never seen them. Each tab remembers its own.
  const [collapsed, setCollapsed] = useSticky('delta-paper.auto.collapsed', false)
  const mult = stopMultiple(config.stopLossPct)
  const tpMult = takeProfitMultiple(config.takeProfitPct)

  const expiryChoices = expiryOptions(expiries, config.expiryLabel)
  const expiryLive = expiryIsLive(expiries, config.expiryLabel)
  // With nothing chosen the engine falls back to its rule, whose usual answer is
  // the nearest listed expiry — so show that rather than an empty box.
  const expiryValue = config.expiryLabel ?? expiries[0]?.label ?? ''

  return (
    // Two zones, not one wrapping row: the settings wrap among themselves on the
    // left, and the actions keep a rail of their own on the right. Wrapping them
    // together is what stranded Cancel/Apply on a line of their own with the whole
    // bar's width of empty space beside them.
    <div className="flex items-center gap-x-5 border-b border-line bg-raised px-5 py-3.5">
      {/* First in the bar, so it holds the same spot whether the settings are
          showing or not — a toggle that moves when you use it is one you have to
          hunt for twice. */}
      <CollapseToggle collapsed={collapsed} onToggle={() => setCollapsed(!collapsed)} />

      {!collapsed && (
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-x-6 gap-y-4">
        <Field
          label="Session · IST"
          help="When it trades, on the IST clock. Inside these hours it sells; past the end it stops and buys back whatever it holds, so nothing is held overnight."
        >
          <div className="flex items-center gap-2">
            <TimePicker value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
            <span className="text-ink-4">–</span>
            <TimePicker value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
          </div>
        </Field>

        <Field
          label="Trading days"
          help="Which days it trades. A day switched off is treated as closed, so it buys back what it holds — it can never be left carrying a position through a day it does not trade."
        >
          <DayPicker value={config.tradeDays} onChange={(tradeDays) => setConfig({ tradeDays })} />
        </Field>

        <GroupRule />

        {/* The listed expiries by date, as the chain's tabs show them. A date does not
            roll: once the chosen one settles the strategy skips its bars rather than
            selling a contract nobody picked, so the stale case is called out. */}
        <Field
          label="Expiry"
          help="Which expiry to sell, by date. The date does not move on its own — once that expiry is gone, trading stops until you pick a new one. It will never quietly sell a different one. Today's expiry finishes at 21:30 IST."
        >
          <div className="flex items-center gap-2">
            <Select
              value={expiryValue}
              width="w-32"
              onChange={(expiryLabel) => setConfig({ expiryLabel })}
              options={expiryChoices}
            />
            {!expiryLive && (
              <span className="text-[11px] whitespace-nowrap text-warn">Settled — pick a date</span>
            )}
          </div>
        </Field>

        <Field
          label="Strike"
          help="How far from gold's price to sell. ATM is the listed strike nearest spot; OTM 2 is two strikes further out, ITM 1 one strike closer in. If it runs out of listed strikes it takes the furthest one rather than skipping the trade."
        >
          <Select
            value={config.moneyness}
            onChange={(m) => setConfig({ moneyness: m })}
            options={MONEYNESS_ORDER.map((m) => ({ value: m, label: label(m) }))}
          />
        </Field>

        {/* The premium floor: a bar whose strike is bid under this is skipped
            rather than sold. Zero turns the filter off. */}
        <Field
          label="Min premium"
          help="A price floor. If the strike it would sell is bid under this, that hour is skipped rather than sold. It will not go looking for a better-paying strike — which strike to sell is the Strike setting's to decide."
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

        <Field
          label="Quantity"
          help="How much to sell each time it fires, in XAUT. It is turned into lots when the order is placed."
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

        <GroupRule />

        {/* The stop, as a share of the premium collected. The multiple it works out
            to sits beside the box, since that is the form it is easiest to check —
            and it keeps the old hardcoded 2× recognisable. */}
        <Field
          label="Stop loss"
          help="How much of the premium you are willing to give back before it closes the position, watched on the option's own price. 100% closes a $4 sale at $8 — the whole premium given back. 50% closes it at $6. At 0 there is no stop at all, and only the end of the trading hours or the expiry will close it."
        >
          <div className="flex items-center gap-2">
            <NumInput
              value={config.stopLossPct}
              min={0}
              step={25}
              unit="%"
              width="w-16"
              onChange={(stopLossPct) => setConfig({ stopLossPct })}
            />
            <span className="text-[11px] whitespace-nowrap text-ink-3">
              {mult === null ? 'no stop' : `${mult.toFixed(2)}× entry`}
            </span>
          </div>
        </Field>

        {/* The other half of the bracket: the stop is the premium given back, this is
            the premium kept. Same shape, same mark, opposite direction. */}
        <Field
          label="Take profit"
          help="How much of the premium you want to keep before it closes the position, watched on the option's own price. 70% buys a $4 sale back at $1.20, keeping 70% of it. 50% buys it back at $2.00. At 0 there is no take-profit."
        >
          <div className="flex items-center gap-2">
            <NumInput
              value={config.takeProfitPct}
              min={0}
              max={95}
              step={10}
              unit="%"
              width="w-16"
              onChange={(takeProfitPct) => setConfig({ takeProfitPct })}
            />
            <span className="text-[11px] whitespace-nowrap text-ink-3">
              {tpMult === null ? 'no TP' : `${tpMult.toFixed(2)}× entry`}
            </span>
          </div>
        </Field>

          {/* No days selected disables the strategy outright, which is worth saying
              out loud — the run switch still reads "Running". */}
          {config.tradeDays.length === 0 && (
            <span className="self-center text-[11px] text-warn">No trading days picked — nothing will trade</span>
          )}
      </div>
      )}

      {/* Folded away, the settings zone stops carrying flex-1, so the rail would
          slide left against the toggle. This keeps it out on the right. */}
      {collapsed && <div className="min-w-0 flex-1" />}

      {/* The action rail: what you do to the settings, then whether the strategy is
          live. Held out of the wrap and behind a hairline so it reads as its own
          zone rather than one more field. Never folded — pausing a live strategy
          must not be behind a disclosure. */}
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
            title="Save every changed field and apply the stop/take-profit to open positions"
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
