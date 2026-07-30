import { useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import {
  ADMIN_KEYWORD,
  clearAdminRequest,
  quickLogin,
  quickLoginAvailable,
  quickLoginUnavailableReason,
  requestAdminPanel,
} from '../lib/admin'

export function Login() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  /**
   * Typing the admin keyword as the password signs in with the credentials from
   * `.env.local` and opens the admin panel — no email needed. Fires as soon as
   * the field matches, so there is nothing to submit.
   *
   * Guarded by a ref so a re-render cannot launch a second attempt.
   */
  const attempted = useRef(false)

  const runQuickLogin = async () => {
    if (attempted.current) return
    attempted.current = true
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      // Set before signing in: the auth state change swaps this view out.
      requestAdminPanel()
      await quickLogin()
    } catch (err) {
      // Undo the request so it cannot surface during a later normal sign-in.
      clearAdminRequest()
      setError(err instanceof Error ? err.message : 'Keyword sign-in failed')
      setBusy(false)
      attempted.current = false
    }
  }

  useEffect(() => {
    if (password !== ADMIN_KEYWORD) {
      // Let them correct a typo and try again.
      attempted.current = false
      return
    }
    if (quickLoginAvailable) {
      void runQuickLogin()
    } else {
      setError(quickLoginUnavailableReason())
    }
    // runQuickLogin closes over setters only; password is the real trigger.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [password])

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()

    // Pressing Enter with the keyword in the password box takes the same path,
    // which is why the form skips native validation for the empty email.
    if (password === ADMIN_KEYWORD) {
      if (quickLoginAvailable) return void runQuickLogin()
      return setError(quickLoginUnavailableReason())
    }

    if (!email.trim()) return setError('Enter your email address')

    setBusy(true)
    setError(null)
    setNotice(null)

    const { data, error: err } =
      mode === 'signin'
        ? await supabase.auth.signInWithPassword({ email, password })
        : await supabase.auth.signUp({ email, password })

    if (err) {
      setError(err.message)
    } else if (mode === 'signup' && !data.session) {
      // Email confirmation is on in the Supabase project.
      setNotice('Check your inbox to confirm the address, then sign in.')
      setMode('signin')
    }
    setBusy(false)
  }

  return (
    <div className="flex min-h-full items-center justify-center p-4">
      <div className="w-full max-w-sm">
        <div className="mb-6 text-center">
          <div className="text-2xl font-bold tracking-tight text-brand-text">XAUT Options</div>
          <div className="mt-1 text-xs text-ink-3">Paper trading terminal · Delta Exchange data</div>
        </div>

        {/* noValidate: the keyword path deliberately submits with no email, so
            validation happens in submit() instead of blocking on the browser's. */}
        <form
          onSubmit={submit}
          noValidate
          className="space-y-3 rounded-lg border border-line bg-raised p-5"
        >
          <div className="mb-4 flex gap-1 rounded bg-sub p-0.5">
            {(['signin', 'signup'] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => {
                  setMode(m)
                  setError(null)
                }}
                className={`flex-1 rounded py-1.5 text-xs font-medium transition-colors ${
                  mode === m ? 'bg-raised-3 text-ink' : 'text-ink-3 hover:text-ink'
                }`}
              >
                {m === 'signin' ? 'Sign in' : 'Create account'}
              </button>
            ))}
          </div>

          <label className="block">
            <span className="mb-1 block text-[12px] text-ink-2">Email</span>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              className="w-full rounded border border-raised-3 bg-surface px-2.5 py-2 text-sm text-ink focus:border-ink-3 focus:outline-none"
            />
          </label>

          <label className="block">
            <span className="mb-1 block text-[12px] text-ink-2">Password</span>
            <input
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
              className="w-full rounded border border-raised-3 bg-surface px-2.5 py-2 text-sm text-ink focus:border-ink-3 focus:outline-none"
            />
          </label>

          {error && (
            <p className="rounded bg-neg-muted px-2 py-1.5 text-[12px] text-neg">{error}</p>
          )}
          {notice && (
            <p className="rounded bg-pos-muted px-2 py-1.5 text-[12px] text-pos">
              {notice}
            </p>
          )}

          <button
            type="submit"
            disabled={busy}
            className="w-full rounded bg-brand py-2.5 text-sm font-semibold text-white hover:bg-brand-hover disabled:opacity-40"
          >
            {busy ? 'Working…' : mode === 'signin' ? 'Sign in' : 'Create account'}
          </button>

          {quickLoginAvailable && (
            <p className="border-t border-line pt-3 text-center text-[10px] text-ink-4">
              Or type <code className="text-brand-text">{ADMIN_KEYWORD}</code> as the password to
              open the admin panel — no email needed.
            </p>
          )}
        </form>

        <p className="mt-4 text-center text-[10px] leading-relaxed text-ink-4">
          Simulated trading only. Prices are live from Delta Exchange's public API,
          <br />
          but no order ever reaches the exchange.
        </p>
      </div>
    </div>
  )
}
