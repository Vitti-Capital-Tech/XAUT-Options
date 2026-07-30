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

/**
 * Escape hatch for running the shortcut outside the dev server — `npm run
 * preview`, a self-hosted build, a LAN box. Opt-in, because switching it on
 * means the admin password really is inlined into the bundle: the branch
 * becomes reachable, so dead-code elimination no longer strips it.
 */
const ALLOW_OUTSIDE_DEV = import.meta.env.VITE_ALLOW_KEYWORD_LOGIN === 'true'

/** True when the shortcut is permitted here and both credentials are configured. */
export const quickLoginAvailable =
  (import.meta.env.DEV || ALLOW_OUTSIDE_DEV) && Boolean(QUICK_EMAIL && QUICK_PASSWORD)

/** Why the shortcut is unavailable, for a useful message instead of silence. */
export function quickLoginUnavailableReason(): string | null {
  if (!import.meta.env.DEV && !ALLOW_OUTSIDE_DEV) {
    return `This is a production build, where keyword sign-in is off by default. Run "npm run dev" instead, or set VITE_ALLOW_KEYWORD_LOGIN=true to allow it here — be aware that publishes the admin password inside the bundle.`
  }
  if (!QUICK_EMAIL || !QUICK_PASSWORD) {
    return `Set VITE_ADMIN_EMAIL and VITE_ADMIN_PASSWORD in .env.local to use "${ADMIN_KEYWORD}" as a password, then restart the server.`
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
