import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { market } from '../lib/marketStore'
import { isPerp, type Expiry } from '../lib/delta'
import { summarizeAccount, type PositionRow } from '../engine/paper'
import { toast } from '../lib/toastStore'
import {
  DEFAULT_DELTA_CONFIG,
  EMPTY_SESSION,
  entryLots as entryLotsFor,
  pickExpiry,
  planCycle,
  type CyclePlan,
  type DeltaConfig,
  type ExpiryPick,
  type HedgeMode,
  type RollCounts,
  type SessionState,
  type TargetLanding,
  type TieBreak,
} from '../lib/deltaStrategy'

const SYNC_MS = 15_000
/** How often the readout re-prices the book. Cosmetic — the engine is elsewhere. */
const READOUT_MS = 2_000
const EMPTY_TOUCHED: ReadonlySet<string> = new Set()

export interface DeltaStrategyApi {
  config: DeltaConfig
  setConfig: (patch: Partial<DeltaConfig>) => void
  armed: boolean
  setArmed: (on: boolean) => void
  session: SessionState
  hasAccount: boolean
  loading: boolean
  /** The latest planned cycle — Δp, the ITM queue and what it is about to do.
   *  Computed whether or not it is armed, so the readout is live while paused. */
  plan: CyclePlan | null
  /**
   * Why the last settings read or write failed, in the field's own terms. Not an
   * engine error — the engine runs server-side and reports through its own logs.
   */
  error: string | null
  /**
   * Run a cycle now rather than waiting out the refresh interval: clears
   * `last_cycle`, which is the only thing holding the engine back, and re-reads the
   * row. The engine's own tick is every 5 seconds, so this brings the next cycle
   * forward to within that — it cannot make the engine act this instant.
   */
  refresh: () => Promise<void>
  /**
   * Lots one entry leg resolves to at the current `qty`, off the traded
   * expiry's own contract value. Null until an expiry is listed — better than
   * showing a number computed against an assumed contract size.
   */
  entryLots: number | null
  /** Write every staged filter change and arm the open shorts — the Apply button.
   *  Resolves once the write has landed; the draft is kept if it was refused. */
  apply: () => Promise<void>
  /** Drop the staged edits and snap back to the saved config — the Cancel button. */
  cancel: () => void
  /** The draft has unsaved edits — enables Apply and Cancel. */
  dirty: boolean
}

/** What the readout needs to price the book. Nothing here places an order. */
export interface DeltaEngineDeps {
  positions: PositionRow[]
  expiries: Expiry[]
  /**
   * The delta account's realized cash. Equity is this plus unrealized, which is
   * what the margin guard measures blocked margin against — so without it the
   * readout can price Δp but cannot say whether the book is over its cap.
   */
  cashBalance: number
  /**
   * Per-symbol initial-margin rate, from the venue's own product data. Omitted
   * for a contract no longer listed, which is the one case paper.ts's fallback
   * rate is there for.
   */
  imRateFor?: (symbol: string) => number | undefined
}

// ---------------------------------------------------------------------------
// Row <-> config
// ---------------------------------------------------------------------------

interface Row {
  account_id: string
  armed: boolean
  session_open: string
  session_close: string
  band_low: string | number
  band_high: string | number
  target_landing: string
  gamma_multiplier: string | number
  band_buffer: string | number
  itm_trigger: string | number
  max_rolls: number
  roll_counts: string
  entry_premium: string | number
  qty: string | number
  max_notional_per_strike: string | number
  tie_break: string
  expiry_pick: string
  expiry_label: string | null
  cycle_seconds: number
  take_profit_mark: string | number | null
  stop_loss_mark: string | number
  margin_cap_pct: string | number
  margin_target_pct: string | number
  hedge_leverage: string | number
  trade_days: number[] | null
  session_day: string | null
  rolls_used_call: number
  rolls_used_put: number
  entered_day: string | null
  flattened_day: string | null
}

const COLS =
  'account_id, armed, session_open, session_close, band_low, band_high, gamma_multiplier, target_landing, band_buffer, itm_trigger, max_rolls, roll_counts, entry_premium, qty, max_notional_per_strike, tie_break, expiry_pick, expiry_label, cycle_seconds, take_profit_mark, stop_loss_mark, margin_cap_pct, margin_target_pct, hedge_leverage, trade_days, session_day, rolls_used_call, rolls_used_put, entered_day, flattened_day'

// Postgres numerics come back as strings over PostgREST.
const n = (v: string | number) => Number(v)

function rowToConfig(row: Row): DeltaConfig {
  return {
    sessionOpen: row.session_open,
    sessionClose: row.session_close,
    bandLow: n(row.band_low),
    bandHigh: n(row.band_high),
    gammaMultiplier: n(row.gamma_multiplier),
    targetLanding: row.target_landing as TargetLanding,
    bandBuffer: n(row.band_buffer),
    itmTrigger: n(row.itm_trigger),
    maxRolls: row.max_rolls,
    rollCounts: row.roll_counts as RollCounts,
    entryPremium: n(row.entry_premium),
    qty: n(row.qty),
    maxNotionalPerStrike: n(row.max_notional_per_strike),
    tieBreak: row.tie_break as TieBreak,
    expiryPick: row.expiry_pick as ExpiryPick,
    expiryLabel: row.expiry_label,
    cycleSeconds: row.cycle_seconds,
    // Null is the column's "no take-profit"; the config carries that as 0.
    takeProfitMark: row.take_profit_mark === null ? 0 : n(row.take_profit_mark),
    stopLossMark: n(row.stop_loss_mark),
    marginCapPct: n(row.margin_cap_pct),
    marginTargetPct: n(row.margin_target_pct),
    hedgeLeverage: n(row.hedge_leverage),
    // A null column is the engine's "every day"; carry that as the full week
    // rather than an empty selection, which would read as "never".
    tradeDays:
      row.trade_days === null ? [...DEFAULT_DELTA_CONFIG.tradeDays] : row.trade_days.map(Number),
  }
}

function configToRow(cfg: DeltaConfig) {
  return {
    session_open: cfg.sessionOpen,
    session_close: cfg.sessionClose,
    band_low: cfg.bandLow,
    band_high: cfg.bandHigh,
    gamma_multiplier: cfg.gammaMultiplier,
    target_landing: cfg.targetLanding,
    band_buffer: cfg.bandBuffer,
    itm_trigger: cfg.itmTrigger,
    max_rolls: cfg.maxRolls,
    roll_counts: cfg.rollCounts,
    entry_premium: cfg.entryPremium,
    qty: cfg.qty,
    max_notional_per_strike: cfg.maxNotionalPerStrike,
    tie_break: cfg.tieBreak,
    expiry_pick: cfg.expiryPick,
    expiry_label: cfg.expiryLabel,
    cycle_seconds: cfg.cycleSeconds,
    take_profit_mark: cfg.takeProfitMark > 0 ? cfg.takeProfitMark : null,
    stop_loss_mark: cfg.stopLossMark,
    margin_cap_pct: cfg.marginCapPct,
    margin_target_pct: cfg.marginTargetPct,
    hedge_leverage: cfg.hedgeLeverage,
    trade_days: cfg.tradeDays,
  }
}

/**
 * A rejected settings write, said in the field's own terms.
 *
 * Postgres names the constraint, not the control: "violates check constraint
 * delta_qty_chk" tells a trader nothing about which box to fix. The inputs are
 * bounded so these should be unreachable from the UI, but a stale tab or a hand-
 * written row can still trip one, and then the message is all there is to go on.
 */
function settingsError(message: string): string {
  if (message.includes('delta_qty_chk')) return 'Qty must be more than zero.'
  if (message.includes('delta_stop_loss_mark_chk')) return 'SL mark cannot be negative.'
  if (message.includes('delta_band_chk'))
    return 'Target delta band needs the left number below the right one.'
  if (message.includes('delta_cycle_chk')) return 'Refresh must be between 5 and 3600 seconds.'
  if (message.includes('delta_margin_pct_chk'))
    return 'Margin cut-at must be at or above cut-to, and neither can be negative.'
  if (message.includes('delta_hedge_leverage_chk'))
    return 'Hedge leverage must be above zero and no more than the 100x the venue offers.'
  if (message.includes('delta_expiry_label_chk')) return 'That expiry is not a valid date.'
  if (message.includes('delta_target_landing_chk')) return 'That is not a landing point the engine accepts.'
  if (message.includes('delta_roll_counts_chk')) return 'That is not a roll count the engine accepts.'
  if (message.includes('delta_tie_break_chk')) return 'That is not a tie-break the engine accepts.'
  if (message.includes('delta_expiry_pick_chk')) return 'That is not an expiry rule the engine accepts.'
  return message
}

function rowToSession(row: Row): SessionState {
  return {
    sessionDay: row.session_day,
    rollsUsedCall: row.rolls_used_call,
    rollsUsedPut: row.rolls_used_put,
    enteredDay: row.entered_day,
    flattenedDay: row.flattened_day,
  }
}

/**
 * The Delta Management Strategy's settings for one account, plus a read-only
 * view of what the engine is doing.
 *
 * Drives both books. `mode` says how this one defends its band — `options` on a
 * delta account, the rules document's roll-and-sell; `futures` on a futures
 * account, one trade in the XAUT perpetual instead. The engine reads the same
 * distinction off `accounts.kind`, so the two cannot disagree, and everything
 * else on the row means the same thing to both.
 *
 * The engine itself runs server-side on pg_cron (see 0012_delta_strategy_engine),
 * the way the auto strategy's does, so the strategy trades with no tab open.
 * /v2/tickers carries greeks.delta and the touch on every symbol, which is what
 * makes that possible — the whole cycle can be priced in SQL.
 *
 * This hook therefore reads and writes the row that engine watches, and runs
 * `planCycle` locally for the readout alone: Δp against the band, the ITM queue,
 * and the line saying what is about to happen. It never places an order. Two
 * engines on one book would double every correction.
 */
export function useDeltaStrategy(
  accountId: string | null,
  deps: DeltaEngineDeps,
  reloadPositions: () => void | Promise<void> = () => {},
  mode: HedgeMode = 'options',
): DeltaStrategyApi {
  // What to call this book in a toast. Both strategies arm independently and the
  // toast stack is app-wide, so "Strategy running" alone would not say which.
  const name = mode === 'futures' ? 'Futures strategy' : 'Delta strategy'
  // `config` is the editable draft; `savedConfig` is what the database holds.
  // Every field is staged here and only written on Apply, so nothing reaches the
  // engine mid-edit — the gap between the two is what lights the Apply button.
  const [config, setConfigState] = useState<DeltaConfig>(DEFAULT_DELTA_CONFIG)
  const [savedConfig, setSavedConfig] = useState<DeltaConfig>(DEFAULT_DELTA_CONFIG)
  const [armed, setArmedState] = useState(false)
  const [session, setSession] = useState<SessionState>(EMPTY_SESSION)
  const [loading, setLoading] = useState(true)
  const [plan, setPlan] = useState<CyclePlan | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Skip a background sync right after Apply, so an in-flight write is not
  // clobbered by a stale read.
  const lastEditRef = useRef(0)
  // The open book and its reloader, through refs so applying a change sees the
  // current shorts and refreshes them without making the callbacks depend on either.
  const positionsRef = useRef(deps.positions)
  positionsRef.current = deps.positions
  const reloadRef = useRef(reloadPositions)
  reloadRef.current = reloadPositions

  // Unsaved edits: the draft differs from the database. Through a ref so applyRow
  // can leave the draft alone while it is dirty even as it takes armed/session.
  const dirty = !sameConfig(config, savedConfig)
  const dirtyRef = useRef(dirty)
  dirtyRef.current = dirty

  const applyRow = useCallback((row: Row) => {
    // Armed and the session counters are the engine's to report, so they always
    // land; the config is the trader's draft, so a live row updates the saved
    // baseline but only overwrites what they see when they have no unsaved edits.
    setSavedConfig(rowToConfig(row))
    setArmedState(row.armed)
    setSession(rowToSession(row))
    if (!dirtyRef.current) setConfigState(rowToConfig(row))
  }, [])

  // ---- Load, seeding a default row for a delta account that has none -------
  useEffect(() => {
    let active = true
    if (!accountId) {
      setLoading(false)
      return
    }
    setLoading(true)

    void (async () => {
      const { data, error: err } = await supabase
        .from('delta_strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (!active) return

      if (data) {
        applyRow(data as Row)
      } else if (err) {
        setError(err.message)
      } else {
        const { data: created, error: insertErr } = await supabase
          .from('delta_strategy_settings')
          .upsert(
            { account_id: accountId, ...configToRow(DEFAULT_DELTA_CONFIG) },
            { onConflict: 'account_id' },
          )
          .select(COLS)
          .single()
        if (!active) return
        if (insertErr) setError(insertErr.message)
        else applyRow(created as Row)
      }
      setLoading(false)
    })()

    return () => {
      active = false
    }
  }, [accountId, applyRow])

  // ---- Keep every open tab in sync ----------------------------------------
  useEffect(() => {
    if (!accountId) return
    const refetch = async () => {
      if (Date.now() - lastEditRef.current < 3000) return
      const { data } = await supabase
        .from('delta_strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (data) applyRow(data as Row)
    }
    const id = setInterval(() => void refetch(), SYNC_MS)
    // Best-effort realtime over the interval fallback — never let it blank the app.
    try {
      const channel = supabase
        .channel(`delta-strategy-${accountId}`)
        .on(
          'postgres_changes',
          {
            event: '*',
            schema: 'public',
            table: 'delta_strategy_settings',
            filter: `account_id=eq.${accountId}`,
          },
          () => void refetch(),
        )
        .subscribe()
      return () => {
        clearInterval(id)
        void supabase.removeChannel(channel)
      }
    } catch (err) {
      console.error('delta strategy realtime failed; falling back to poll:', err)
      return () => clearInterval(id)
    }
  }, [accountId, applyRow])

  // Upsert rather than update: a plain update silently no-ops if the row is
  // missing, which is exactly how an arm gets lost.
  //
  // Returns the rejection in the field's own terms, or null when the write
  // landed. Callers need the outcome, not just the side effect: confirming a save
  // that was refused is worse than confirming nothing.
  const persist = useCallback(
    async (patch: Record<string, unknown>): Promise<string | null> => {
      if (!accountId) return 'No delta account selected.'
      lastEditRef.current = Date.now()
      const { error: err } = await supabase
        .from('delta_strategy_settings')
        .upsert(
          { account_id: accountId, ...patch, updated_at: new Date().toISOString() },
          { onConflict: 'account_id' },
        )
      if (err) {
        console.error('delta_strategy_settings write failed:', err.message)
        const said = settingsError(err.message)
        setError(said)
        return said
      }
      setError(null)
      return null
    },
    [accountId],
  )

  // Stage an edit into the draft only — nothing is written until Apply.
  const setConfig = useCallback(
    (patch: Partial<DeltaConfig>) => {
      setConfigState((prev) => ({ ...prev, ...patch }))
    },
    [],
  )

  // Arming is an action, not a filter, so it saves at once rather than waiting on
  // Apply — a pause you have to remember to confirm is a pause that does not happen.
  const setArmed = useCallback(
    (on: boolean) => {
      setArmedState(on)
      void persist({ armed: on }).then((err) => {
        // A refused arm is the failure worth shouting about: the switch already
        // moved, so without this the strategy reads as running until the next sync
        // quietly puts it back.
        if (err) {
          setArmedState(!on)
          toast.error(`${name} — could not ${on ? 'start' : 'pause'}: ${err}`)
          return
        }
        // Named, because the toast stack is app-wide and both strategies arm
        // independently — "Strategy running" alone would not say which one.
        toast.ok(on ? `${name} running.` : `${name} paused.`)
      })
    },
    [persist, name],
  )

  // Apply: write every staged field, and push the marks onto the open shorts,
  // which delta_sell only ever arms at fill time. `savedConfig` catches up to the
  // draft, so the button goes dark until the next edit.
  //
  // `savedConfig` only catches up once the write has landed. Moving it first — as
  // this used to — darkened the buttons on a write that was then refused, leaving
  // the panel looking saved with the draft unrecoverable. Staying dirty on failure
  // keeps the edits on screen and Apply live to retry.
  const apply = useCallback(async () => {
    if (loading) return
    const err = await persist(configToRow(config))
    if (err) {
      toast.error(`${name} — settings not saved: ${err}`)
      return
    }
    setSavedConfig(config)
    const { failed } = await rearmOpenPositions(positionsRef.current, config, reloadRef.current)
    // The settings did land, so this is not a failed Apply — but the marks on
    // those legs are not what the panel now shows, and that has to be said.
    if (failed > 0) {
      toast.error(`${name} — settings saved, but TP/SL did not update on ${failed} position(s).`)
      return
    }
    toast.ok(`${name} — settings applied.`)
  }, [config, loading, persist, name])

  // Cancel: throw the draft away and snap back to what the database holds. Local
  // only, so there is nothing that can fail here.
  const cancel = useCallback(() => {
    setConfigState(savedConfig)
    toast.ok(`${name} — changes discarded.`)
  }, [savedConfig, name])

  // Clearing last_cycle is all a manual refresh can do from here: the engine is
  // server-side and its spacing check is the one gate the client owns. The row is
  // then re-read directly rather than waiting on the background sync, which the
  // write we just made would have skipped anyway.
  const refresh = useCallback(async () => {
    if (!accountId) return
    await persist({ last_cycle: null })
    const { data } = await supabase
      .from('delta_strategy_settings')
      .select(COLS)
      .eq('account_id', accountId)
      .maybeSingle()
    if (data) applyRow(data as Row)
  }, [accountId, persist, applyRow])

  // The session counters are the engine's to write, not ours: it owns the roll
  // budget, the touched strikes and which day has been entered. They arrive here
  // through the realtime subscription above, read-only.

  // ---- Readout -------------------------------------------------------------
  // The same plan the server-side engine computes, recomputed here purely to
  // show it. Everything it reads goes through a ref so a market tick does not
  // tear the timer down and rebuild it.
  const ctx = useRef({ config, session, deps, mode })
  ctx.current = { config, session, deps, mode }

  useEffect(() => {
    if (!accountId) return

    // Named apart from the exported `refresh`, which pokes the engine rather than
    // recomputing the readout.
    const recompute = () => {
      const { config: cfg, session: sess, deps: d, mode: m } = ctx.current
      const tickerFor = (symbol: string) => market.get(symbol)
      // Only `marginBlocked` and `equity` are read from this, so the starting
      // balance is passed as zero — `realized` belongs to the header, which
      // computes its own summary off the account it has selected.
      const summary = summarizeAccount(
        d.cashBalance,
        0,
        d.positions,
        tickerFor,
        market.spot,
        d.imRateFor,
      )
      setPlan(
        planCycle({
          now: new Date(),
          cfg,
          mode: m,
          session: sess,
          positions: d.positions,
          expiry: pickExpiry(d.expiries, cfg),
          spot: market.spot,
          tickerFor,
          // The engine's touched set lives in the database and is its business.
          // The readout only ever describes the next unstarted step.
          touched: EMPTY_TOUCHED,
          marginBlocked: summary.marginBlocked,
          equity: summary.equity,
          imRateFor: d.imRateFor,
        }),
      )
    }

    recompute()
    const id = setInterval(recompute, READOUT_MS)
    return () => clearInterval(id)
  }, [accountId])

  // Any listed contract of the traded expiry answers this — they share a contract
  // value — so the readout uses the venue's number rather than assuming one.
  const entryLots = useMemo(() => {
    const expiry = pickExpiry(deps.expiries, config)
    const product = expiry?.calls.values().next().value ?? expiry?.puts.values().next().value
    return product ? entryLotsFor(product, config) : null
  }, [deps.expiries, config])

  return useMemo(
    () => ({
      config,
      setConfig,
      armed,
      setArmed,
      session,
      hasAccount: accountId !== null,
      loading,
      plan,
      error,
      refresh,
      entryLots,
      apply,
      cancel,
      dirty,
    }),
    [config, setConfig, armed, setArmed, session, accountId, loading, plan, error, refresh, entryLots, apply, cancel, dirty],
  )
}

/** Two configs equal field-for-field, order-independent, for the dirty check. */
function sameConfig(a: DeltaConfig, b: DeltaConfig): boolean {
  const keys = Object.keys(a).sort()
  return JSON.stringify(a, keys) === JSON.stringify(b, keys)
}

/**
 * Re-arm every open short's bracket to the current marks. delta_sell adds an
 * avg-entry guard at fill time — a take-profit only below the entry, a stop only
 * above it — but a trader moving the fields means exactly the level typed, the
 * same as the position's own TP/SL editor, so we set the marks straight: each on
 * when it is set, cleared (null) when it is zero. Then reload so it shows at once.
 */
async function rearmOpenPositions(
  positions: PositionRow[],
  config: DeltaConfig,
  reload: () => void | Promise<void>,
): Promise<{ failed: number }> {
  // Short options only. The perpetual hedge is deliberately unbracketed — a
  // take-profit on it would close the hedge on a move in the book's favour and
  // leave the option legs uncovered, which is the one thing it is there to
  // prevent — so Apply must not arm one either.
  const open = positions.filter((p) => p.net_qty < 0 && !isPerp(p.contract_type))
  if (open.length === 0) return { failed: 0 }
  // Counted, not just logged: a leg left on the old marks is a leg whose exit
  // levels differ from what the panel says, and Apply has to be able to say so.
  const results = await Promise.all(
    open.map((p) =>
      supabase
        .rpc('set_position_tpsl', {
          p_position_id: p.id,
          p_take_profit: config.takeProfitMark > 0 ? config.takeProfitMark : null,
          p_stop_loss: config.stopLossMark > 0 ? config.stopLossMark : null,
          p_trigger: 'mark',
        })
        .then(({ error }) => {
          if (error) console.error('delta re-arm failed:', error.message)
          return Boolean(error)
        }),
    ),
  )
  await reload()
  return { failed: results.filter(Boolean).length }
}
