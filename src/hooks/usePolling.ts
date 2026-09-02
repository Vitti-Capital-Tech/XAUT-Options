import { useCallback, useEffect, useRef } from 'react'

/**
 * Timers that only run while the tab is being looked at.
 *
 * Every poll in this app is a reconciliation fallback, not the primary path —
 * realtime delivers the change the moment it lands, and the limit-fill engine is
 * driven by the market websocket rather than by any of these intervals. So a
 * hidden tab has nothing to gain from polling, and a dashboard left open all day
 * on a second monitor was spending the bulk of the app's Supabase egress on
 * re-reading rows nobody could see.
 */

/** Is the document being displayed? True in any environment without the API. */
function visible(): boolean {
  return typeof document === 'undefined' || document.visibilityState === 'visible'
}

/**
 * Call `fn` every `ms`, but only while the tab is visible, and once immediately
 * on becoming visible again so nothing is stale by more than the switch back.
 *
 * `fn` goes through a ref, so passing a fresh closure each render does not tear
 * the timer down and restart it.
 */
export function useVisiblePoll(fn: () => void, ms: number, enabled = true): void {
  const ref = useRef(fn)
  ref.current = fn

  useEffect(() => {
    if (!enabled) return

    let id: ReturnType<typeof setInterval> | null = null
    const start = () => {
      if (id === null) id = setInterval(() => ref.current(), ms)
    }
    const stop = () => {
      if (id !== null) {
        clearInterval(id)
        id = null
      }
    }

    const onVisibility = () => {
      if (visible()) {
        // Catch up first, then resume the cadence — coming back to a stale book
        // and waiting out a full interval is the one thing this must not do.
        ref.current()
        start()
      } else {
        stop()
      }
    }

    if (visible()) start()
    document.addEventListener('visibilitychange', onVisibility)
    return () => {
      stop()
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [ms, enabled])
}

/**
 * A stable callback that runs `fn` once, `ms` after the last call.
 *
 * The realtime handlers need this: one engine cycle lands an order insert, an
 * order update, a fill and a position update in the space of a few milliseconds,
 * and each of those used to trigger its own full re-read. Collapsing the burst
 * into one pass costs nothing anybody can perceive.
 */
export function useDebouncedCallback(fn: () => void, ms: number): () => void {
  const ref = useRef(fn)
  ref.current = fn
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(
    () => () => {
      if (timer.current !== null) clearTimeout(timer.current)
    },
    [],
  )

  return useCallback(() => {
    if (timer.current !== null) clearTimeout(timer.current)
    timer.current = setTimeout(() => {
      timer.current = null
      ref.current()
    }, ms)
  }, [ms])
}
