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
  /** Write every staged filter change and arm the open shorts — the Apply button. */
  apply: () => void
  /** Drop the staged edits and snap back to the saved config — the Cancel button. */
  cancel: () => void
  /** The draft has unsaved edits — enables Apply and Cancel. */
  dirty: boolean
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
  // `config` is the editable draft; `savedConfig` is what is actually in the
  // database. Every field is staged here and only written on Apply, so nothing
  // reaches the engine mid-edit — the difference between the two is what lights
  // the Apply button.
  const [config, setConfigState] = useState<StrategyConfig>(DEFAULT_CONFIG)
  const [savedConfig, setSavedConfig] = useState<StrategyConfig>(DEFAULT_CONFIG)
  const [armed, setArmedState] = useState(false)
  const [loading, setLoading] = useState(true)
  // When the user last applied, so a background sync does not overwrite a write
  // that may still be in flight.
  const lastEditRef = useRef(0)
  // The open book and its reloader, read through refs so re-arming on a TP/SL
  // edit sees the current positions and refreshes them without making setConfig
  // depend on either.
  const positionsRef = useRef(positions)
  positionsRef.current = positions
  const reloadRef = useRef(reloadPositions)
  reloadRef.current = reloadPositions

  // Unsaved edits: the draft differs from the database. A ref of it lets the sync
  // effect below skip a refetch while the trader is mid-edit, so a poll never
  // wipes changes they have not applied yet.
  const dirty = !sameConfig(config, savedConfig)
  const dirtyRef = useRef(dirty)
  dirtyRef.current = dirty

  const applyRow = useCallback((row: Row) => {
    const cfg: StrategyConfig = {
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
    }
    // Reset the draft to what the database holds — the two are equal right after a
    // load, so the Apply button stays dark until the trader changes something.
    setConfigState(cfg)
    setSavedConfig(cfg)
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
      // Hold off while there are unsaved edits or a just-applied write may still be
      // in flight, so neither clobbers the draft the trader is looking at.
      if (dirtyRef.current || Date.now() - lastEditRef.current < 3000) return
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

  // Stage an edit into the draft only — nothing is written until Apply.
  const setConfig = useCallback((patch: Partial<StrategyConfig>) => {
    setConfigState((prev) => ({ ...prev, ...patch }))
  }, [])

  // Arming is an action, not a filter, so it saves at once rather than waiting on
  // Apply — a pause you have to remember to confirm is a pause that does not happen.
  const setArmed = useCallback(
    (on: boolean) => {
      setArmedState(on)
      persist({ armed: on })
    },
    [persist],
  )

  // Apply: write every staged field, and push the bracket onto the open shorts,
  // which the engine only ever arms at fill time. `savedConfig` catches up to the
  // draft, so the button goes dark until the next edit.
  const apply = useCallback(() => {
    if (loading) return
    setSavedConfig(config)
    persist({
      moneyness: config.moneyness,
      qty: config.qty,
      window_start: config.windowStart,
      window_end: config.windowEnd,
      trade_days: config.tradeDays,
      min_premium: config.minPremium,
      expiry_rule: config.expiryRule,
      expiry_label: config.expiryLabel,
      stop_loss_pct: config.stopLossPct,
      take_profit_pct: config.takeProfitPct,
    })
    void rearmOpenPositions(positionsRef.current, config, reloadRef.current)
  }, [config, loading, persist])

  // Cancel: throw the draft away and snap back to what the database holds.
  const cancel = useCallback(() => {
    setConfigState(savedConfig)
  }, [savedConfig])

  return {
    config,
    setConfig,
    armed,
    setArmed,
    hasAccount: accountId !== null,
    loading,
    apply,
    cancel,
    dirty,
  }
}

/** Two configs equal field-for-field, order-independent, for the dirty check. */
function sameConfig(a: StrategyConfig, b: StrategyConfig): boolean {
  const keys = Object.keys(a).sort()
  return JSON.stringify(a, keys) === JSON.stringify(b, keys)
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
