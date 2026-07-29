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
          <div className="text-2xl font-bold tracking-tight text-amber-400">XAUT Options</div>
          <div className="mt-1 text-xs text-zinc-500">Paper trading terminal · Delta Exchange data</div>
        </div>

        <form
          onSubmit={submit}
          className="space-y-3 rounded-lg border border-zinc-800 bg-zinc-900/60 p-5"
        >
          <div className="mb-4 flex gap-1 rounded bg-zinc-800/60 p-0.5">
            {(['signin', 'signup'] as const).map((m) => (
              <button
                key={m}
                type="button"
                onClick={() => {
                  setMode(m)
                  setError(null)
                }}
                className={`flex-1 rounded py-1.5 text-xs font-medium transition-colors ${
                  mode === m ? 'bg-zinc-700 text-zinc-100' : 'text-zinc-500 hover:text-zinc-300'
                }`}
              >
                {m === 'signin' ? 'Sign in' : 'Create account'}
              </button>
            ))}
          </div>

          <label className="block">
            <span className="mb-1 block text-[11px] text-zinc-400">Email</span>
            <input
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              className="w-full rounded border border-zinc-700 bg-zinc-950 px-2.5 py-2 text-sm text-zinc-100 focus:border-zinc-500 focus:outline-none"
            />
          </label>

          <label className="block">
            <span className="mb-1 block text-[11px] text-zinc-400">Password</span>
            <input
              type="password"
              required
              minLength={6}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
              className="w-full rounded border border-zinc-700 bg-zinc-950 px-2.5 py-2 text-sm text-zinc-100 focus:border-zinc-500 focus:outline-none"
            />
          </label>

          {error && (
            <p className="rounded bg-rose-500/10 px-2 py-1.5 text-[11px] text-rose-400">{error}</p>
          )}
          {notice && (
            <p className="rounded bg-emerald-500/10 px-2 py-1.5 text-[11px] text-emerald-400">
              {notice}
            </p>
          )}

          <button
            type="submit"
            disabled={busy}
            className="w-full rounded bg-amber-600 py-2.5 text-sm font-semibold text-white hover:bg-amber-500 disabled:opacity-40"
          >
            {busy ? 'Working…' : mode === 'signin' ? 'Sign in' : 'Create account'}
          </button>
        </form>

        <p className="mt-4 text-center text-[10px] leading-relaxed text-zinc-600">
          Simulated trading only. Prices are live from Delta Exchange's public API,
          <br />
          but no order ever reaches the exchange.
        </p>
      </div>
    </div>
  )
}
