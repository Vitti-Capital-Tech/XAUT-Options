import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { market } from '../lib/marketStore'
import type { Expiry, Product } from '../lib/delta'
import type { PositionRow } from '../engine/paper'
import {
  DEFAULT_DELTA_CONFIG,
  EMPTY_SESSION,
  pickExpiry,
  planCycle,
  sessionPhase,
  type CyclePlan,
  type DeltaConfig,
  type ExpiryPick,
  type RollCounts,
  type SessionState,
  type TargetLanding,
  type TieBreak,
} from '../lib/deltaStrategy'

const SYNC_MS = 15_000
/** How soon to run again after acting, so a multi-step correction is not paced
 *  by the cycle interval. */
const FOLLOW_UP_MS = 1_500

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
  /** Last engine error. Cleared by the next cycle that acts cleanly. */
  error: string | null
}

export interface DeltaEngineDeps {
  positions: PositionRow[]
  expiries: Expiry[]
  productsBySymbol: Map<string, Product>
  placeOrder: (args: {
    product: Product
    side: 'buy' | 'sell'
    orderType: 'market'
    qty: number
    limitPrice: null
    reduceOnly?: boolean
  }) => Promise<unknown>
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
  pairs: number
  tie_break: string
  expiry_pick: string
  cycle_seconds: number
  session_day: string | null
  rolls_used_call: number
  rolls_used_put: number
  entered_day: string | null
  flattened_day: string | null
}

const COLS =
  'account_id, armed, session_open, session_close, band_low, band_high, target_landing, band_buffer, itm_trigger, max_rolls, roll_counts, entry_premium, min_premium, band_delta_low, band_delta_high, pairs, tie_break, expiry_pick, cycle_seconds, session_day, rolls_used_call, rolls_used_put, entered_day, flattened_day'

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
    pairs: row.pairs,
    tieBreak: row.tie_break as TieBreak,
    expiryPick: row.expiry_pick as ExpiryPick,
    cycleSeconds: row.cycle_seconds,
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
    pairs: cfg.pairs,
    tie_break: cfg.tieBreak,
    expiry_pick: cfg.expiryPick,
    cycle_seconds: cfg.cycleSeconds,
  }
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

// ---------------------------------------------------------------------------
// Acting on a planned cycle
// ---------------------------------------------------------------------------

/** Mutable per-pass bookkeeping the plan reads and the executor writes. */
interface PassState {
  /** Strikes already acted on in this corrective pass — touched at most once. */
  touched: Set<string>
  /** Whether a corrective run is under way, for the 'pass' roll-budget reading. */
  open: boolean
}

/**
 * Place the orders one planned action calls for, then charge the roll budget.
 *
 * Every order is a market order, exactly as the ticket places them, so it is
 * the same paper fill engine throughout — nothing here reaches a real venue.
 */
async function executeAction(
  plan: CyclePlan,
  deps: DeltaEngineDeps,
  cfg: DeltaConfig,
  session: SessionState,
  patch: (p: Partial<SessionState>) => Promise<void>,
  pass: PassState,
): Promise<void> {
  const action = plan.action
  if (!action) return

  if (action.type === 'flatten') {
    for (const pos of action.positions) {
      const product = deps.productsBySymbol.get(pos.symbol)
      if (!product) continue
      await deps.placeOrder({
        product,
        side: pos.net_qty > 0 ? 'sell' : 'buy',
        orderType: 'market',
        qty: Math.abs(pos.net_qty),
        limitPrice: null,
        reduceOnly: true,
      })
    }
    pass.touched.clear()
    pass.open = false
    await patch({ flattenedDay: plan.day })
    return
  }

  if (action.type === 'entry') {
    for (const leg of action.legs) {
      await deps.placeOrder({
        product: leg.product,
        side: 'sell',
        orderType: 'market',
        qty: leg.qty,
        limitPrice: null,
      })
    }
    await patch({ enteredDay: plan.day })
    return
  }

  if (action.type === 'band') {
    // Section 5.4: band-correction sells are fresh positions, not replacements,
    // so they draw on neither side's roll budget.
    await deps.placeOrder({
      product: action.product,
      side: 'sell',
      orderType: 'market',
      qty: action.qty,
      limitPrice: null,
    })
    return
  }

  // Partial exit and replace.
  const product = deps.productsBySymbol.get(action.leg.position.symbol)
  if (!product) throw new Error(`No product loaded for ${action.leg.position.symbol}`)

  // Buy the ITM quantity back first, then sell the replacement — never the other
  // way round, so the book is never briefly bigger than intended.
  await deps.placeOrder({
    product,
    side: 'buy',
    orderType: 'market',
    qty: action.exitQty,
    limitPrice: null,
    reduceOnly: true,
  })

  if (action.replace) {
    await deps.placeOrder({
      product: action.replace.product,
      side: 'sell',
      orderType: 'market',
      qty: action.replace.qty,
      limitPrice: null,
    })
  }

  pass.touched.add(action.leg.position.symbol)

  // A full exit under exit-only has no budget left to spend, so only a genuine
  // roll is charged. 'strike' charges every strike touched; 'pass' charges the
  // corrective run once, on its first.
  if (action.replace) {
    const chargeable = cfg.rollCounts === 'strike' || !pass.open
    pass.open = true
    if (chargeable) {
      await patch(
        action.side === 'call'
          ? { rollsUsedCall: session.rollsUsedCall + 1 }
          : { rollsUsedPut: session.rollsUsedPut + 1 },
      )
    }
  }
}

// ---------------------------------------------------------------------------

/**
 * The Delta Management Strategy for one delta account: its settings, its
 * session-scoped state, and the loop that acts on them.
 *
 * Unlike the auto strategy — whose entries run on pg_cron, so they need no tab —
 * this engine runs here, in the browser. Every cycle prices the whole book off
 * per-strike greeks from the live ticker feed, and those only exist client-side,
 * so the strategy advances only while a tab is open and armed. The settings and
 * the counters live in the database regardless, so an arm survives a reload and
 * two tabs cannot disagree about how much roll budget a side has left.
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
        setError(err.message)
      }
    },
    [accountId],
  )

  const setConfig = useCallback(
    (patch: Partial<DeltaConfig>) => {
      setConfigState((prev) => {
        const next = { ...prev, ...patch }
        void persist(configToRow(next))
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

  const patchSession = useCallback(
    async (patch: Partial<SessionState>) => {
      setSession((prev) => ({ ...prev, ...patch }))
      const row: Record<string, unknown> = {}
      if ('sessionDay' in patch) row.session_day = patch.sessionDay
      if ('rollsUsedCall' in patch) row.rolls_used_call = patch.rollsUsedCall
      if ('rollsUsedPut' in patch) row.rolls_used_put = patch.rollsUsedPut
      if ('enteredDay' in patch) row.entered_day = patch.enteredDay
      if ('flattenedDay' in patch) row.flattened_day = patch.flattenedDay
      await persist(row)
    },
    [persist],
  )

  // ---- The loop ------------------------------------------------------------
  // Everything a cycle reads goes through this ref, so a market tick or a config
  // edit does not tear the timer down and rebuild it. Assigned during render, the
  // same way the trading and accounts hooks pin their callbacks.
  const ctx = useRef({ config, armed, session, deps, patchSession })
  ctx.current = { config, armed, session, deps, patchSession }

  const pass = useRef<PassState>({ touched: new Set(), open: false })

  useEffect(() => {
    if (!accountId) return

    let stopped = false
    let timer: number | null = null
    let busy = false

    const cycle = async () => {
      if (stopped) return
      if (busy) return schedule(1_000)
      busy = true

      const { config: cfg, armed: on, session: sess, deps: d, patchSession: patch } = ctx.current
      let delay = Math.max(5, cfg.cycleSeconds) * 1_000

      try {
        const now = new Date()
        const { day } = sessionPhase(now, cfg)

        // A new session day wipes the counters and the touched flags before
        // anything is planned against them. Re-plan immediately after.
        if (sess.sessionDay !== day) {
          pass.current.touched.clear()
          pass.current.open = false
          await patch({
            sessionDay: day,
            rollsUsedCall: 0,
            rollsUsedPut: 0,
            enteredDay: null,
            flattenedDay: null,
          })
          delay = 250
          return
        }

        const expiry = pickExpiry(d.expiries, cfg.expiryPick)

        const next = planCycle({
          now,
          cfg,
          session: sess,
          positions: d.positions,
          expiry,
          spot: market.spot,
          tickerFor: (symbol) => market.get(symbol),
          touched: pass.current.touched,
        })
        setPlan(next)

        if (!on || !next.action) {
          // Δp back inside the band ends the pass: the touched set is released,
          // so the next breach may revisit the same strikes.
          if (!next.breach && pass.current.open) {
            pass.current.open = false
            pass.current.touched.clear()
          }
          return
        }

        await executeAction(next, d, cfg, sess, patch, pass.current)
        setError(null)
        // Act again shortly, so a multi-step correction converges without
        // waiting a whole cycle — Δp is re-read off fresh marks first either way.
        //
        // Not after a band correction, though: that is the one action with no
        // touched-strike guard behind it, so it gets the full cycle to let the
        // fills land and the greeks refresh before it is allowed to size another.
        // Otherwise a stale delta could have it sell into the same breach twice.
        if (next.action.type !== 'band') delay = FOLLOW_UP_MS
      } catch (err) {
        setError(err instanceof Error ? err.message : String(err))
      } finally {
        busy = false
        schedule(delay)
      }
    }

    const schedule = (ms: number) => {
      if (stopped) return
      timer = setTimeout(() => void cycle(), ms) as unknown as number
    }

    void cycle()
    return () => {
      stopped = true
      if (timer !== null) clearTimeout(timer)
    }
    // Keyed on the account alone: everything else is read through ctx at cycle
    // time, so an edit lands on the next cycle rather than restarting the loop.
  }, [accountId])

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
    }),
    [config, setConfig, armed, setArmed, session, accountId, loading, plan, error],
  )
}
