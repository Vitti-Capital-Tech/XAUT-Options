import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  DEFAULT_CONFIG,
  stopMultiple,
  takeProfitMultiple,
  type ExpiryRule,
  type Moneyness,
  type StrategyConfig,
} from '../lib/strategy'
import type { PositionRow } from '../engine/paper'

const SYNC_MS = 15_000

/**
 * The auto-strategy's settings for one auto account, backed by the database.
 *
 * The engine that acts on these — reading the 1h candle, selling the option,
 * arming the stop — now runs server-side on pg_cron (see 0008_strategy_engine),
 * so it works with the tab closed. This hook only reads and writes the row that
 * engine watches: whether it is armed, the strike, the size and the window.
 */
export interface StrategyApi {
  config: StrategyConfig
  setConfig: (patch: Partial<StrategyConfig>) => void
  armed: boolean
  setArmed: (on: boolean) => void
  hasAccount: boolean
  loading: boolean
}

interface Row {
  account_id: string
  armed: boolean
  moneyness: string
  qty: number
  window_start: string
  window_end: string
  trade_days: number[] | null
  min_premium: string | number
  expiry_rule: string
  expiry_label: string | null
  stop_loss_pct: string | number
  take_profit_pct: string | number
}

const COLS =
  'account_id, armed, moneyness, qty, window_start, window_end, trade_days, min_premium, expiry_rule, expiry_label, stop_loss_pct, take_profit_pct'

export function useAutoStrategy(
  accountId: string | null,
  positions: PositionRow[] = [],
  reloadPositions: () => void | Promise<void> = () => {},
): StrategyApi {
  const [config, setConfigState] = useState<StrategyConfig>(DEFAULT_CONFIG)
  const [armed, setArmedState] = useState(false)
  const [loading, setLoading] = useState(true)
  // When the user last changed something here, so a background sync does not
  // overwrite a write that may still be in flight.
  const lastEditRef = useRef(0)
  // The open book and its reloader, read through refs so re-arming on a TP/SL
  // edit sees the current positions and refreshes them without making setConfig
  // depend on either.
  const positionsRef = useRef(positions)
  positionsRef.current = positions
  const reloadRef = useRef(reloadPositions)
  reloadRef.current = reloadPositions

  const applyRow = useCallback((row: Row) => {
    setConfigState({
      moneyness: row.moneyness as Moneyness,
      qty: Number(row.qty),
      windowStart: row.window_start,
      windowEnd: row.window_end,
      // A null column is the engine's "every day"; carry that as the full week
      // rather than an empty selection, which would read as "never".
      tradeDays: row.trade_days === null ? [...DEFAULT_CONFIG.tradeDays] : row.trade_days.map(Number),
      // Postgres numerics come back as strings over PostgREST.
      minPremium: Number(row.min_premium),
      expiryRule: row.expiry_rule as ExpiryRule,
      expiryLabel: row.expiry_label,
      stopLossPct: Number(row.stop_loss_pct),
      takeProfitPct: Number(row.take_profit_pct),
    })
    setArmedState(row.armed)
  }, [])

  // Initial load — and seed a default row for the cron if this auto account has
  // none yet.
  useEffect(() => {
    let active = true
    if (!accountId) {
      setLoading(false)
      return
    }
    setLoading(true)

    void (async () => {
      const { data } = await supabase
        .from('strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (!active) return

      if (data) {
        applyRow(data as Row)
      } else {
        const def: Row = {
          account_id: accountId,
          armed: false,
          moneyness: DEFAULT_CONFIG.moneyness,
          qty: DEFAULT_CONFIG.qty,
          window_start: DEFAULT_CONFIG.windowStart,
          window_end: DEFAULT_CONFIG.windowEnd,
          trade_days: DEFAULT_CONFIG.tradeDays,
          min_premium: DEFAULT_CONFIG.minPremium,
          expiry_rule: DEFAULT_CONFIG.expiryRule,
          expiry_label: DEFAULT_CONFIG.expiryLabel,
          stop_loss_pct: DEFAULT_CONFIG.stopLossPct,
          take_profit_pct: DEFAULT_CONFIG.takeProfitPct,
        }
        await supabase.from('strategy_settings').upsert(def, { onConflict: 'account_id' })
        if (!active) return
        applyRow(def)
      }
      setLoading(false)
    })()

    return () => {
      active = false
    }
  }, [accountId, applyRow])

  // Keep every open tab in sync. Realtime pushes a change the moment it lands;
  // the interval is the fallback. Both skip a beat right after a local edit so
  // an in-flight write is not clobbered by a stale read.
  useEffect(() => {
    if (!accountId) return
    const refetch = async () => {
      if (Date.now() - lastEditRef.current < 3000) return
      const { data } = await supabase
        .from('strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (data) applyRow(data as Row)
    }
    const id = setInterval(refetch, SYNC_MS)
    // Best-effort realtime over the interval fallback — never let it blank the app.
    try {
      const channel = supabase
        .channel(`strategy-${accountId}`)
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'strategy_settings', filter: `account_id=eq.${accountId}` },
          () => void refetch(),
        )
        .subscribe()
      return () => {
        clearInterval(id)
        void supabase.removeChannel(channel)
      }
    } catch (err) {
      console.error('strategy realtime failed; falling back to poll:', err)
      return () => clearInterval(id)
    }
  }, [accountId, applyRow])

  // Upsert, not update: a plain update silently no-ops if the row is somehow
  // missing, which would lose an arm. Upsert always lands the write.
  const persist = useCallback(
    (patch: Record<string, unknown>) => {
      if (!accountId) return
      lastEditRef.current = Date.now()
      void supabase
        .from('strategy_settings')
        .upsert(
          { account_id: accountId, ...patch, updated_at: new Date().toISOString() },
          { onConflict: 'account_id' },
        )
        .then(({ error }) => {
          // Surface a rejected write rather than swallowing it — a silent failure
          // here is exactly what makes an armed toggle spring back on refresh.
          if (error) console.error('strategy_settings write failed:', error.message)
        })
    },
    [accountId],
  )

  const setConfig = useCallback(
    (patch: Partial<StrategyConfig>) => {
      setConfigState((prev) => {
        const next = { ...prev, ...patch }
        persist({
          moneyness: next.moneyness,
          qty: next.qty,
          window_start: next.windowStart,
          window_end: next.windowEnd,
          trade_days: next.tradeDays,
          min_premium: next.minPremium,
          expiry_rule: next.expiryRule,
          expiry_label: next.expiryLabel,
          stop_loss_pct: next.stopLossPct,
          take_profit_pct: next.takeProfitPct,
        })
        return next
      })
    },
    [persist],
  )

  const setArmed = useCallback(
    (on: boolean) => {
      setArmedState(on)
      persist({ armed: on })
    },
    [persist],
  )

  // Re-arm the open shorts whenever the trader moves TP/SL. The engine only ever
  // arms a bracket at fill time, so without this a changed stop or take-profit
  // never reaches a position already open. A ref of the last-applied values keeps
  // this to real edits: it stays quiet on load and on a plain positions refresh.
  const armedForRef = useRef<{ sl: number; tp: number } | null>(null)
  useEffect(() => {
    if (loading) return
    const now = { sl: config.stopLossPct, tp: config.takeProfitPct }
    const was = armedForRef.current
    armedForRef.current = now
    // First settle after a load adopts the values without touching positions;
    // only a subsequent change is a trader moving the fields.
    if (was === null || (was.sl === now.sl && was.tp === now.tp)) return
    void rearmOpenPositions(positionsRef.current, config, reloadRef.current)
  }, [config, loading])

  return { config, setConfig, armed, setArmed, hasAccount: accountId !== null, loading }
}

/**
 * Re-arm every open short's bracket to the current TP/SL, mirroring what the
 * engine writes at fill time: stop and take-profit as avg_entry × the multiple,
 * on the mark, with a zero percent clearing that side (null, never a level at 0).
 * Then reload the book so the change shows at once rather than on the next poll.
 */
async function rearmOpenPositions(
  positions: PositionRow[],
  config: StrategyConfig,
  reload: () => void | Promise<void>,
): Promise<void> {
  const stop = stopMultiple(config.stopLossPct)
  const take = takeProfitMultiple(config.takeProfitPct)
  const open = positions.filter((p) => p.net_qty !== 0)
  if (open.length === 0) return
  await Promise.all(
    open.map((p) => {
      const avg = Number(p.avg_entry_price)
      return supabase
        .rpc('set_position_tpsl', {
          p_position_id: p.id,
          p_take_profit: take === null ? null : avg * take,
          p_stop_loss: stop === null ? null : avg * stop,
          p_trigger: 'mark',
        })
        .then(({ error }) => {
          if (error) console.error('auto re-arm failed:', error.message)
        })
    }),
  )
  await reload()
}
