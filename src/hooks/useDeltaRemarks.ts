import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'

/**
 * What the engine decided, and why.
 *
 * One row per decision, written server-side by `apply_delta_strategy` (see
 * [`0033`](../../supabase/migrations/0033_delta_remarks.sql)) at the moment it
 * acts — or at the moment it deliberately does not. Read-only here: the table
 * grants select and nothing else, because a journal the trader can edit is not
 * a journal.
 */
export type DeltaRemarkAction =
  /** The session's opening pair. */
  | 'entry'
  /** Partial exit of an in-the-money short, replaced further out. */
  | 'roll'
  /** Full close with the side's roll budget spent — the loss booked. */
  | 'exit'
  /** Fresh out-of-the-money sell, with nothing left to roll. */
  | 'band'
  /** Margin over the cap: lots closed outright. */
  | 'cut'
  /** Session close, or a day the strategy does not trade. */
  | 'flatten'
  /** Margin over cut-to: something was deliberately not done. */
  | 'hold'
  /** Could not act — a missing greek, an unlisted expiry, nothing quoted. */
  | 'wait'

export interface DeltaRemarkRow {
  id: string
  action: DeltaRemarkAction
  /** Postgres numerics arrive as strings over PostgREST; all of these are nullable. */
  spot: string | null
  /** Δp when the book was checked. Null when a greek was missing. */
  dp_before: string | null
  /** Where the correction was aiming. Null for a cut, a flatten or a no-op. */
  dp_target: string | null
  /** Δp once the action had gone through — what it actually made. */
  dp_after: string | null
  band_low: string | null
  band_high: string | null
  /** The leg acted on, where there was a single one. */
  symbol: string | null
  qty: number | null
  note: string
  created_at: string
}

const COLS =
  'id, action, spot, dp_before, dp_target, dp_after, band_low, band_high, symbol, qty, note, created_at'

/** Deep enough to cover a week of a busy book without paging the query itself —
 *  the table below it pages what is already in hand. */
const LIMIT = 300
const POLL_MS = 15_000

/**
 * The delta engine's remarks for one account, newest first.
 *
 * Realtime with a poll behind it, the same arrangement `useTrading` uses: the
 * engine runs on pg_cron with no tab open, so a remark can appear at any moment
 * and nothing on this side triggers a re-read.
 */
export function useDeltaRemarks(accountId: string | null): DeltaRemarkRow[] {
  const [remarks, setRemarks] = useState<DeltaRemarkRow[]>([])

  const reload = useCallback(async () => {
    if (!accountId) {
      setRemarks([])
      return
    }
    const { data, error } = await supabase
      .from('delta_remarks')
      .select(COLS)
      .eq('account_id', accountId)
      .order('created_at', { ascending: false })
      .limit(LIMIT)
    if (!error) setRemarks((data ?? []) as DeltaRemarkRow[])
  }, [accountId])

  useEffect(() => {
    void reload()
  }, [reload])

  useEffect(() => {
    if (!accountId) return
    const id = setInterval(() => void reload(), POLL_MS)
    return () => clearInterval(id)
  }, [accountId, reload])

  // Through a ref so a new `reload` identity does not tear the subscription down
  // and rebuild it.
  const reloadRef = useRef(reload)
  reloadRef.current = reload
  useEffect(() => {
    if (!accountId) return
    // Best-effort, as everywhere else: a failed subscription must never blank the
    // app — the poll above still reconciles.
    try {
      const channel = supabase
        .channel(`delta-remarks-${accountId}`)
        .on(
          'postgres_changes',
          {
            event: 'INSERT',
            schema: 'public',
            table: 'delta_remarks',
            filter: `account_id=eq.${accountId}`,
          },
          () => void reloadRef.current(),
        )
        .subscribe()
      return () => {
        void supabase.removeChannel(channel)
      }
    } catch (err) {
      console.error('delta remarks realtime failed; falling back to poll:', err)
    }
  }, [accountId])

  return remarks
}
