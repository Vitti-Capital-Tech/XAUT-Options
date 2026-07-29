import { useEffect, useRef, useState } from 'react'
import type { Account } from '../hooks/useAccounts'
import type { AccountSummary } from '../engine/paper'
import { market, useMarketTick } from '../lib/marketStore'
import { pnlClass, price, signedUsd, usd } from '../lib/format'
import { supabase } from '../lib/supabase'

interface Props {
  accounts: Account[]
  selected: Account | null
  summary: AccountSummary
  email: string | undefined
  onSelect: (id: string) => void
  onCreate: (name: string, startingBalance: number) => Promise<void>
  onReset: (id: string) => Promise<void>
  onArchive: (id: string) => Promise<void>
}

export function TopBar({
  accounts,
  selected,
  summary,
  email,
  onSelect,
  onCreate,
  onReset,
  onArchive,
}: Props) {
  useMarketTick()
  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')
  const [newBalance, setNewBalance] = useState('10000')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const menuRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!menuOpen) return
    const onDown = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) {
        setMenuOpen(false)
        setCreating(false)
        setError(null)
      }
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [menuOpen])

  const status = market.status

  const submitCreate = async () => {
    const balance = Number(newBalance)
    if (!newName.trim()) return setError('Give the account a name')
    if (!Number.isFinite(balance) || balance <= 0) return setError('Starting balance must be positive')
    setBusy(true)
    setError(null)
    try {
      await onCreate(newName, balance)
      setNewName('')
      setNewBalance('10000')
      setCreating(false)
      setMenuOpen(false)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create account')
    } finally {
      setBusy(false)
    }
  }

  return (
    <header className="flex shrink-0 items-center gap-4 border-b border-zinc-800 bg-zinc-900/60 px-3 py-2">
      <div className="flex items-center gap-2">
        <span className="text-sm font-bold tracking-tight text-amber-400">XAUT</span>
        <span className="rounded bg-amber-500/15 px-1.5 py-0.5 text-[9px] font-bold tracking-wider text-amber-500 uppercase">
          Paper
        </span>
      </div>

      <div className="flex items-baseline gap-1.5">
        <span className="num text-base font-semibold text-zinc-100">{price(market.spot)}</span>
        <span className="text-[10px] text-zinc-500">SPOT</span>
      </div>

      <div className="flex items-center gap-1.5" title={`Market data: ${status}`}>
        <span
          className={`h-1.5 w-1.5 rounded-full ${
            status === 'live' ? 'bg-emerald-500' : status === 'connecting' ? 'bg-amber-500' : 'bg-rose-500 animate-pulse'
          }`}
        />
        <span className="text-[10px] text-zinc-500 capitalize">{status}</span>
      </div>

      <div className="ml-auto flex items-center gap-5 text-[11px]">
        <Stat label="Balance" value={usd(summary.balance)} />
        <Stat
          label="Unrealized"
          value={signedUsd(summary.unrealized, 4)}
          className={pnlClass(summary.unrealized)}
        />
        <Stat label="Equity" value={usd(summary.equity)} emphasis />
        <Stat label="Margin" value={usd(summary.marginBlocked, 4)} />
        <Stat
          label="Available"
          value={usd(summary.available)}
          className={summary.available < 0 ? 'text-rose-400' : undefined}
        />
      </div>

      <div className="relative" ref={menuRef}>
        <button
          onClick={() => setMenuOpen((v) => !v)}
          className="flex items-center gap-2 rounded border border-zinc-700 px-2.5 py-1.5 text-xs text-zinc-200 hover:border-zinc-500"
        >
          <span className="font-medium">{selected?.name ?? 'No account'}</span>
          <span className="text-zinc-500">▾</span>
        </button>

        {menuOpen && (
          <div className="absolute right-0 z-50 mt-1 w-72 overflow-hidden rounded-lg border border-zinc-700 bg-zinc-900 shadow-2xl">
            <div className="border-b border-zinc-800 px-3 py-2 text-[10px] tracking-wider text-zinc-500 uppercase">
              Paper accounts
            </div>

            <div className="max-h-60 overflow-y-auto">
              {accounts.map((a) => {
                const isActive = a.id === selected?.id
                const pnl = Number(a.cash_balance) - Number(a.starting_balance)
                return (
                  <div
                    key={a.id}
                    className={`flex items-center gap-2 px-3 py-2 ${isActive ? 'bg-zinc-800/60' : 'hover:bg-zinc-800/30'}`}
                  >
                    <button
                      onClick={() => {
                        onSelect(a.id)
                        setMenuOpen(false)
                      }}
                      className="min-w-0 flex-1 text-left"
                    >
                      <div className="flex items-center gap-1.5">
                        {isActive && <span className="text-[9px] text-amber-500">●</span>}
                        <span className="truncate text-xs font-medium text-zinc-200">{a.name}</span>
                      </div>
                      <div className="num mt-0.5 flex gap-2 text-[10px]">
                        <span className="text-zinc-400">{usd(Number(a.cash_balance))}</span>
                        <span className={pnlClass(pnl)}>{signedUsd(pnl)}</span>
                      </div>
                    </button>
                    <button
                      onClick={async () => {
                        if (!confirm(`Reset "${a.name}"? This deletes its positions, orders and trade history, and restores the starting balance.`)) return
                        setBusy(true)
                        try {
                          await onReset(a.id)
                        } finally {
                          setBusy(false)
                        }
                      }}
                      disabled={busy}
                      title="Reset to starting balance"
                      className="rounded p-1 text-[10px] text-zinc-500 hover:bg-zinc-700 hover:text-amber-400 disabled:opacity-40"
                    >
                      ↺
                    </button>
                    {accounts.length > 1 && (
                      <button
                        onClick={async () => {
                          if (!confirm(`Archive "${a.name}"? It is hidden from the switcher but its history is kept.`)) return
                          setBusy(true)
                          try {
                            await onArchive(a.id)
                          } finally {
                            setBusy(false)
                          }
                        }}
                        disabled={busy}
                        title="Archive account"
                        className="rounded p-1 text-[10px] text-zinc-500 hover:bg-zinc-700 hover:text-rose-400 disabled:opacity-40"
                      >
                        ✕
                      </button>
                    )}
                  </div>
                )
              })}
            </div>

            {creating ? (
              <div className="space-y-2 border-t border-zinc-800 p-3">
                <input
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                  placeholder="Account name"
                  autoFocus
                  className="w-full rounded border border-zinc-700 bg-zinc-950 px-2 py-1 text-xs text-zinc-100 focus:border-zinc-500 focus:outline-none"
                />
                <div>
                  <label className="mb-1 block text-[10px] text-zinc-500">Starting balance (USD)</label>
                  <input
                    type="number"
                    value={newBalance}
                    onChange={(e) => setNewBalance(e.target.value)}
                    className="num w-full rounded border border-zinc-700 bg-zinc-950 px-2 py-1 text-right text-xs text-zinc-100 focus:border-zinc-500 focus:outline-none"
                  />
                </div>
                {error && <p className="text-[10px] text-rose-400">{error}</p>}
                <div className="flex gap-2">
                  <button
                    onClick={submitCreate}
                    disabled={busy}
                    className="flex-1 rounded bg-amber-600 py-1 text-xs font-medium text-white hover:bg-amber-500 disabled:opacity-40"
                  >
                    Create
                  </button>
                  <button
                    onClick={() => {
                      setCreating(false)
                      setError(null)
                    }}
                    className="rounded border border-zinc-700 px-3 py-1 text-xs text-zinc-400 hover:border-zinc-500"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <button
                onClick={() => setCreating(true)}
                className="w-full border-t border-zinc-800 px-3 py-2 text-left text-xs text-amber-400 hover:bg-zinc-800/40"
              >
                + New paper account
              </button>
            )}

            <div className="flex items-center justify-between border-t border-zinc-800 bg-zinc-950/60 px-3 py-2">
              <span className="truncate text-[10px] text-zinc-500">{email}</span>
              <button
                onClick={() => void supabase.auth.signOut()}
                className="text-[10px] text-zinc-400 hover:text-rose-400"
              >
                Sign out
              </button>
            </div>
          </div>
        )}
      </div>
    </header>
  )
}

function Stat({
  label,
  value,
  className,
  emphasis = false,
}: {
  label: string
  value: string
  className?: string
  emphasis?: boolean
}) {
  return (
    <div className="text-right">
      <div className="text-[9px] tracking-wider text-zinc-500 uppercase">{label}</div>
      <div
        className={`num font-semibold ${className ?? (emphasis ? 'text-zinc-100' : 'text-zinc-300')}`}
      >
        {value}
      </div>
    </div>
  )
}
