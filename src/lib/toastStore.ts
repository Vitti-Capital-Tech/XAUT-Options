/**
 * Transient confirmations, in one place.
 *
 * The app had no way to say "that worked". Apply's only feedback was the button
 * going dark, which is indistinguishable from a click that did nothing, and a
 * rejected write reached the trader as a console line and — on the auto strategy
 * — not at all. So a settings save could fail silently while the panel looked
 * saved. That is the gap this fills.
 *
 * A module-level store rather than context: toasts are pushed from hooks and
 * effects, not only from inside components, and threading a provider through
 * every caller to say one sentence is not worth it. Subscribers are notified
 * synchronously — unlike `marketStore`, whose throttle exists because quotes
 * arrive hundreds of times a second; a toast is a discrete human-scale event and
 * delaying it would only make the UI feel late.
 */

export type ToastKind = 'ok' | 'error'

export interface Toast {
  id: number
  kind: ToastKind
  text: string
}

/**
 * How long each kind stays up. An error outlives a confirmation because it is the
 * one a trader has to read and may need to act on, and losing it to a four-second
 * timer puts them back to guessing.
 */
const LIFETIME_MS: Record<ToastKind, number> = { ok: 3500, error: 9000 }

/** Beyond this the oldest is dropped, so a burst cannot paper over the screen. */
const MAX_VISIBLE = 4

class ToastStore {
  private items: readonly Toast[] = []
  private subs = new Set<() => void>()
  private timers = new Map<number, ReturnType<typeof setTimeout>>()
  private seq = 0

  subscribe = (fn: () => void): (() => void) => {
    this.subs.add(fn)
    return () => {
      this.subs.delete(fn)
    }
  }

  /** Stable between changes, which is what `useSyncExternalStore` requires: the
   *  array is replaced on every mutation and never edited in place. */
  snapshot = (): readonly Toast[] => this.items

  push(kind: ToastKind, text: string): number {
    const id = ++this.seq
    const next = [...this.items, { id, kind, text }]
    // Drop from the front, and clear the dropped ones' timers with them so a
    // burst cannot leave callbacks firing against ids that are already gone.
    while (next.length > MAX_VISIBLE) {
      const dropped = next.shift()
      if (dropped) this.clearTimer(dropped.id)
    }
    this.items = next
    this.timers.set(
      id,
      setTimeout(() => this.dismiss(id), LIFETIME_MS[kind]),
    )
    this.emit()
    return id
  }

  dismiss(id: number): void {
    this.clearTimer(id)
    const next = this.items.filter((t) => t.id !== id)
    if (next.length === this.items.length) return
    this.items = next
    this.emit()
  }

  private clearTimer(id: number): void {
    const timer = this.timers.get(id)
    if (timer !== undefined) clearTimeout(timer)
    this.timers.delete(id)
  }

  private emit(): void {
    for (const fn of this.subs) fn()
  }
}

export const toasts = new ToastStore()

/** What callers use. `toast.error` takes the message already in the field's own
 *  terms — the store does no phrasing of its own. */
export const toast = {
  ok: (text: string) => toasts.push('ok', text),
  error: (text: string) => toasts.push('error', text),
}
