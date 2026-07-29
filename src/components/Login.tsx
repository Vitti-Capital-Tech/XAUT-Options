import { useState } from 'react'
import { supabase } from '../lib/supabase'

export function Login() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
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

        <form
          onSubmit={submit}
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
              required
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
              required
              minLength={6}
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
