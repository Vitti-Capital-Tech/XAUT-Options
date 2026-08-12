import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { market } from '../lib/marketStore'
import type { Expiry } from '../lib/delta'
import type { PositionRow } from '../engine/paper'
import {
  DEFAULT_DELTA_CONFIG,
  EMPTY_SESSION,
  entryLots as entryLotsFor,
  pickExpiry,
  planCycle,
  type CyclePlan,
  type DeltaConfig,
  type ExpiryPick,
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
   * row. The engine's own tick is every minute, so this brings the next cycle
   * forward to within that — it cannot make the engine act this instant.
   */
  refresh: () => Promise<void>
  /**
   * Lots one entry leg resolves to at the current `qty`, off the traded
   * expiry's own contract value. Null until an expiry is listed — better than
   * showing a number computed against an assumed contract size.
   */
  entryLots: number | null
}

/** What the readout needs to price the book. Nothing here places an order. */
export interface DeltaEngineDeps {
  positions: PositionRow[]
  expiries: Expiry[]
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
  band_buffer: string | number
  itm_trigger: string | number
  max_rolls: number
  roll_counts: string
  entry_premium: string | number
  min_premium: string | number
  band_delta_low: string | number
  band_delta_high: string | number
  qty: string | number
  tie_break: string
  expiry_pick: string
  expiry_label: string | null
  cycle_seconds: number
  take_profit_mark: string | number | null
  stop_loss_mark: string | number
  trade_days: number[] | null
  session_day: string | null
  rolls_used_call: number
  rolls_used_put: number
  entered_day: string | null
  flattened_day: string | null
}

const COLS =
  'account_id, armed, session_open, session_close, band_low, band_high, target_landing, band_buffer, itm_trigger, max_rolls, roll_counts, entry_premium, min_premium, band_delta_low, band_delta_high, qty, tie_break, expiry_pick, expiry_label, cycle_seconds, take_profit_mark, stop_loss_mark, trade_days, session_day, rolls_used_call, rolls_used_put, entered_day, flattened_day'

// Postgres numerics come back as strings over PostgREST.
const n = (v: string | number) => Number(v)

function rowToConfig(row: Row): DeltaConfig {
  return {
    sessionOpen: row.session_open,
    sessionClose: row.session_close,
    bandLow: n(row.band_low),
    bandHigh: n(row.band_high),
    targetLanding: row.target_landing as TargetLanding,
    bandBuffer: n(row.band_buffer),
    itmTrigger: n(row.itm_trigger),
    maxRolls: row.max_rolls,
    rollCounts: row.roll_counts as RollCounts,
    entryPremium: n(row.entry_premium),
    minPremium: n(row.min_premium),
    bandDeltaLow: n(row.band_delta_low),
    bandDeltaHigh: n(row.band_delta_high),
    qty: n(row.qty),
    tieBreak: row.tie_break as TieBreak,
    expiryPick: row.expiry_pick as ExpiryPick,
    expiryLabel: row.expiry_label,
    cycleSeconds: row.cycle_seconds,
    // Null is the column's "no take-profit"; the config carries that as 0.
    takeProfitMark: row.take_profit_mark === null ? 0 : n(row.take_profit_mark),
    stopLossMark: n(row.stop_loss_mark),
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
    target_landing: cfg.targetLanding,
    band_buffer: cfg.bandBuffer,
    itm_trigger: cfg.itmTrigger,
    max_rolls: cfg.maxRolls,
    roll_counts: cfg.rollCounts,
    entry_premium: cfg.entryPremium,
    min_premium: cfg.minPremium,
    band_delta_low: cfg.bandDeltaLow,
    band_delta_high: cfg.bandDeltaHigh,
    qty: cfg.qty,
    tie_break: cfg.tieBreak,
    expiry_pick: cfg.expiryPick,
    expiry_label: cfg.expiryLabel,
    cycle_seconds: cfg.cycleSeconds,
    take_profit_mark: cfg.takeProfitMark > 0 ? cfg.takeProfitMark : null,
    stop_loss_mark: cfg.stopLossMark,
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
 * The Delta Management Strategy's settings for one delta account, plus a
 * read-only view of what the engine is doing.
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
export function useDeltaStrategy(accountId: string | null, deps: DeltaEngineDeps): DeltaStrategyApi {
  const [config, setConfigState] = useState<DeltaConfig>(DEFAULT_DELTA_CONFIG)
  const [armed, setArmedState] = useState(false)
  const [session, setSession] = useState<SessionState>(EMPTY_SESSION)
  const [loading, setLoading] = useState(true)
  const [plan, setPlan] = useState<CyclePlan | null>(null)
  const [error, setError] = useState<string | null>(null)

  // Skip a background sync right after a local edit, so an in-flight write is
  // not clobbered by a stale read.
  const lastEditRef = useRef(0)
  // The open book, through a ref so re-arming on a TP/SL edit sees the current
  // shorts without making setConfig depend on them.
  const positionsRef = useRef(deps.positions)
  positionsRef.current = deps.positions

  const applyRow = useCallback((row: Row) => {
    setConfigState(rowToConfig(row))
    setArmedState(row.armed)
    setSession(rowToSession(row))
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
  const persist = useCallback(
    async (patch: Record<string, unknown>) => {
      if (!accountId) return
      lastEditRef.current = Date.now()
      const { error: err } = await supabase
        .from('delta_strategy_settings')
        .upsert(
          { account_id: accountId, ...patch, updated_at: new Date().toISOString() },
          { onConflict: 'account_id' },
        )
      if (err) {
        console.error('delta_strategy_settings write failed:', err.message)
        setError(settingsError(err.message))
      }
    },
    [accountId],
  )

  const setConfig = useCallback(
    (patch: Partial<DeltaConfig>) => {
      setConfigState((prev) => {
        const next = { ...prev, ...patch }
        void persist(configToRow(next))
        // delta_sell only arms brackets at fill time, so a moved mark would never
        // reach the shorts already open. Push it onto them here.
        if (next.takeProfitMark !== prev.takeProfitMark || next.stopLossMark !== prev.stopLossMark) {
          rearmOpenPositions(positionsRef.current, next)
        }
        return next
      })
    },
    [persist],
  )

  const setArmed = useCallback(
    (on: boolean) => {
      setArmedState(on)
      void persist({ armed: on })
    },
    [persist],
  )

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
  const ctx = useRef({ config, session, deps })
  ctx.current = { config, session, deps }

  useEffect(() => {
    if (!accountId) return

    // Named apart from the exported `refresh`, which pokes the engine rather than
    // recomputing the readout.
    const recompute = () => {
      const { config: cfg, session: sess, deps: d } = ctx.current
      setPlan(
        planCycle({
          now: new Date(),
          cfg,
          session: sess,
          positions: d.positions,
          expiry: pickExpiry(d.expiries, cfg),
          spot: market.spot,
          tickerFor: (symbol) => market.get(symbol),
          // The engine's touched set lives in the database and is its business.
          // The readout only ever describes the next unstarted step.
          touched: EMPTY_TOUCHED,
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
    }),
    [config, setConfig, armed, setArmed, session, accountId, loading, plan, error, refresh, entryLots],
  )
}

/**
 * Re-arm every open short's bracket to the current marks, mirroring delta_sell:
 * absolute levels, each armed only when set and only on the side the entry can
 * still reach — a take-profit below the entry, a stop above it — and cleared
 * (null) otherwise.
 */
function rearmOpenPositions(positions: PositionRow[], config: DeltaConfig): void {
  for (const p of positions) {
    if (p.net_qty >= 0) continue
    const avg = Number(p.avg_entry_price)
    void supabase.rpc('set_position_tpsl', {
      p_position_id: p.id,
      p_take_profit: config.takeProfitMark > 0 && avg > config.takeProfitMark ? config.takeProfitMark : null,
      p_stop_loss: config.stopLossMark > 0 && avg < config.stopLossMark ? config.stopLossMark : null,
      p_trigger: 'mark',
    })
  }
}
