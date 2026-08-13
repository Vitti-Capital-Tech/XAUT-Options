import { useSyncExternalStore } from 'react'
import { toasts, type Toast } from '../lib/toastStore'

/**
 * The toast stack. Mounted once, at the app root.
 *
 * Bottom-right, above everything, and never in the way of the chain or the
 * ticket — the two things a trader is actually reading when one of these fires.
 * Newest at the bottom, so a burst pushes older ones up and out of the way
 * rather than shifting the one just written.
 */
export function Toasts() {
  const items = useSyncExternalStore(toasts.subscribe, toasts.snapshot, toasts.snapshot)
  if (items.length === 0) return null

  return (
    // pointer-events-none on the column, auto on each card: the empty space in
    // this corner stays clickable, the cards themselves stay dismissable.
    <div
      className="pointer-events-none fixed right-5 bottom-5 z-50 flex flex-col gap-2"
      role="status"
      aria-live="polite"
    >
      {items.map((t) => (
        <Card key={t.id} toast={t} />
      ))}
    </div>
  )
}

function Card({ toast }: { toast: Toast }) {
  const bad = toast.kind === 'error'
  return (
    <button
      type="button"
      onClick={() => toasts.dismiss(toast.id)}
      title="Dismiss"
      className={`pointer-events-auto flex max-w-sm items-start gap-2.5 rounded-md border px-3.5 py-2.5 text-left text-[12.5px] shadow-delta-sm transition-colors ${
        bad
          ? 'border-neg-on-muted bg-neg-muted text-neg hover:border-neg'
          : 'border-pos-on-muted bg-pos-muted text-pos hover:border-pos'
      }`}
    >
      {/* A shape as well as a colour, so the two kinds are not told apart by hue
          alone — the same reason the P&L columns carry signs. */}
      <span aria-hidden className="mt-px shrink-0 font-semibold">
        {bad ? '!' : '✓'}
      </span>
      <span className="min-w-0">{toast.text}</span>
    </button>
  )
}
