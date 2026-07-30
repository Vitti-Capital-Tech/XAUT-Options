/**
 * Admin entry points.
 *
 * Two ways in, both convenience rather than security:
 *
 *   1. Typing `ADMIN_KEYWORD` anywhere in the terminal, once signed in.
 *   2. Typing it into the password box on the login screen, which signs in with
 *      the credentials in `.env.local` and lands straight on the panel.
 *
 * The second is an auth shortcut, so it is restricted to development builds.
 * Vite inlines `import.meta.env` values into the output bundle, which means a
 * deployed production build carrying VITE_ADMIN_PASSWORD would hand that
 * password to anyone who opened the site. `import.meta.env.DEV` is false in
 * `vite build`, so the shortcut cannot ship even if the variables are set.
 */

import { supabase } from './supabase'

export const ADMIN_KEYWORD = import.meta.env.VITE_ADMIN_KEYWORD || 'trade'

const QUICK_EMAIL = import.meta.env.VITE_ADMIN_EMAIL
const QUICK_PASSWORD = import.meta.env.VITE_ADMIN_PASSWORD

/** True only in a dev server, and only when both credentials are configured. */
export const quickLoginAvailable = import.meta.env.DEV && Boolean(QUICK_EMAIL && QUICK_PASSWORD)

/** Why the shortcut is unavailable, for a useful message instead of silence. */
export function quickLoginUnavailableReason(): string | null {
  if (!import.meta.env.DEV) {
    return 'Keyword sign-in is disabled in production builds. Sign in with your email and password.'
  }
  if (!QUICK_EMAIL || !QUICK_PASSWORD) {
    return `Set VITE_ADMIN_EMAIL and VITE_ADMIN_PASSWORD in .env.local to use "${ADMIN_KEYWORD}" as a password, then restart the dev server.`
  }
  return null
}

/**
 * Sign in with the configured admin credentials.
 *
 * Deliberately does not create the user when it is missing — an account that
 * appears by itself is worse than a clear error. Sign up once with these
 * credentials first.
 */
export async function quickLogin(): Promise<void> {
  const reason = quickLoginUnavailableReason()
  if (reason) throw new Error(reason)

  const { error } = await supabase.auth.signInWithPassword({
    email: QUICK_EMAIL!,
    password: QUICK_PASSWORD!,
  })

  if (error) {
    if (/invalid login credentials/i.test(error.message)) {
      throw new Error(
        `No account matches VITE_ADMIN_EMAIL (${QUICK_EMAIL}). Create it once via "Create account", then the keyword will work.`,
      )
    }
    throw new Error(error.message)
  }
}

// ---------------------------------------------------------------------------
// Handoff: the login screen asks for the panel, the terminal opens it.
// sessionStorage rather than state because a sign-in remounts the tree.
// ---------------------------------------------------------------------------

const INTENT_KEY = 'delta-paper.open-admin'

export function requestAdminPanel(): void {
  sessionStorage.setItem(INTENT_KEY, '1')
}

/**
 * Drop a pending request. Needed when keyword sign-in fails: the flag is set
 * before the attempt, and leaving it behind would make the panel spring open
 * during an unrelated sign-in later in the session.
 */
export function clearAdminRequest(): void {
  sessionStorage.removeItem(INTENT_KEY)
}

/** Read the request and clear it, so it opens the panel exactly once. */
export function consumeAdminRequest(): boolean {
  const pending = sessionStorage.getItem(INTENT_KEY)
  if (pending) sessionStorage.removeItem(INTENT_KEY)
  return Boolean(pending)
}
