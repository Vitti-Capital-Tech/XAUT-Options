import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'
import { DEFAULT_CONFIG, type Moneyness, type StrategyConfig } from '../lib/strategy'

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

  useEffect(() => {
    let active = true
    if (!accountId) {
      setLoading(false)
      return
    }
    setLoading(true)

    const apply = (row: Row) => {
      setConfigState({
        moneyness: row.moneyness as Moneyness,
        qty: Number(row.qty),
        windowStart: row.window_start,
        windowEnd: row.window_end,
      })
      setArmedState(row.armed)
    }

    void (async () => {
      const { data } = await supabase
        .from('strategy_settings')
        .select(COLS)
        .eq('account_id', accountId)
        .maybeSingle()
      if (!active) return

      if (data) {
        apply(data as Row)
      } else {
        // First visit for this auto account — seed a default row for the cron.
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
        apply(def)
      }
      setLoading(false)
    })()

    return () => {
      active = false
    }
  }, [accountId])

  const persist = useCallback(
    (patch: Record<string, unknown>) => {
      if (!accountId) return
      void supabase
        .from('strategy_settings')
        .update({ ...patch, updated_at: new Date().toISOString() })
        .eq('account_id', accountId)
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
