import { useEffect, useRef } from 'react'

/** How long a partial match survives before the buffer resets. */
const IDLE_RESET_MS = 1500

/** Fields where typing must never be interpreted as the keyword. */
function isTextEntry(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  const tag = target.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT'
}

/**
 * Fire `onTrigger` when the user types `keyword` anywhere in the page.
 *
 * Keystrokes inside inputs are ignored, so naming an account "trade desk" does
 * not spring the panel open mid-word. The buffer only ever holds as many
 * characters as the keyword is long, and clears after a pause, so unrelated
 * typing cannot accumulate into a false match.
 *
 * This is a convenience shortcut, not a security boundary: the comparison
 * happens in browser code that anyone can read. Access to the data behind the
 * panel is protected by Supabase auth and row-level security, not by this.
 */
export function useKeywordTrigger(keyword: string, onTrigger: () => void, enabled = true) {
  const buffer = useRef('')
  const lastKeyAt = useRef(0)
  // Held in a ref so a re-created callback does not detach the listener.
  const handler = useRef(onTrigger)
  handler.current = onTrigger

  useEffect(() => {
    const target = keyword.toLowerCase()
    if (!enabled || target.length === 0) return

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.metaKey || e.altKey) return
      if (isTextEntry(e.target)) return
      // Ignore anything that is not a single printable character.
      if (e.key.length !== 1) return

      const now = Date.now()
      if (now - lastKeyAt.current > IDLE_RESET_MS) buffer.current = ''
      lastKeyAt.current = now

      buffer.current = (buffer.current + e.key.toLowerCase()).slice(-target.length)

      if (buffer.current === target) {
        buffer.current = ''
        handler.current()
      }
    }

    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [keyword, enabled])
}
