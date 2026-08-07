import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { DEFAULT_CONFIG, type Moneyness, type StrategyConfig } from '../lib/strategy'

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
}

const COLS = 'account_id, armed, moneyness, qty, window_start, window_end'

export function useAutoStrategy(accountId: string | null): StrategyApi {
  const [config, setConfigState] = useState<StrategyConfig>(DEFAULT_CONFIG)
  const [armed, setArmedState] = useState(false)
  const [loading, setLoading] = useState(true)
  // When the user last changed something here, so a background sync does not
  // overwrite a write that may still be in flight.
  const lastEditRef = useRef(0)

  const applyRow = useCallback((row: Row) => {
    setConfigState({
      moneyness: row.moneyness as Moneyness,
      qty: Number(row.qty),
      windowStart: row.window_start,
      windowEnd: row.window_end,
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

  // Keep every open tab in sync — re-read the row on an interval, skipping a
  // tick right after a local edit so an in-flight write is not clobbered.
  useEffect(() => {
    if (!accountId) return
    const id = setInterval(async () => {
      if (Date.now() - lastEditRef.current < 3000) return
      const { data } = await supabase
        .from('strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (data) applyRow(data as Row)
    }, SYNC_MS)
    return () => clearInterval(id)
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

  return { config, setConfig, armed, setArmed, hasAccount: accountId !== null, loading }
}
