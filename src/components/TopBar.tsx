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
    <header className="flex shrink-0 items-center gap-4 border-b border-line bg-raised px-3 py-2">
      <div className="flex items-center gap-2">
        <span className="text-sm font-bold tracking-tight text-warn">XAUT</span>
        <span className="rounded bg-warn-muted px-1.5 py-0.5 text-[10px] font-bold tracking-wider text-warn uppercase">
          Paper
        </span>
      </div>

      <div className="flex items-baseline gap-1.5">
        <span className="num text-base font-semibold text-ink">{price(market.spot)}</span>
        <span className="text-[10px] text-ink-3">SPOT</span>
      </div>

      <div className="flex items-center gap-1.5" title={`Market data: ${status}`}>
        <span
          className={`h-1.5 w-1.5 rounded-full ${
            status === 'live' ? 'bg-pos-solid' : status === 'connecting' ? 'bg-warn' : 'bg-neg-solid animate-pulse'
          }`}
        />
        <span className="text-[10px] text-ink-3 capitalize">{status}</span>
      </div>

      <div className="ml-auto flex items-center gap-5 text-[12px]">
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
          className={summary.available < 0 ? 'text-neg' : undefined}
        />
      </div>

      <div className="relative" ref={menuRef}>
        <button
          onClick={() => setMenuOpen((v) => !v)}
          className="flex items-center gap-2 rounded border border-raised-3 px-2.5 py-1.5 text-xs text-ink hover:border-ink-3"
        >
          <span className="font-medium">{selected?.name ?? 'No account'}</span>
          <span className="text-ink-3">▾</span>
        </button>

        {menuOpen && (
          <div className="absolute right-0 z-50 mt-1 w-72 overflow-hidden rounded-lg border border-raised-3 bg-raised shadow-2xl">
            <div className="border-b border-line px-3 py-2 text-[10px] tracking-wider text-ink-3 uppercase">
              Paper accounts
            </div>

            <div className="max-h-60 overflow-y-auto">
              {accounts.map((a) => {
                const isActive = a.id === selected?.id
                const pnl = Number(a.cash_balance) - Number(a.starting_balance)
                return (
                  <div
                    key={a.id}
                    className={`flex items-center gap-2 px-3 py-2 ${isActive ? 'bg-sub' : 'hover:bg-raised-2'}`}
                  >
                    <button
                      onClick={() => {
                        onSelect(a.id)
                        setMenuOpen(false)
                      }}
                      className="min-w-0 flex-1 text-left"
                    >
                      <div className="flex items-center gap-1.5">
                        {isActive && <span className="text-[10px] text-warn">●</span>}
                        <span className="truncate text-xs font-medium text-ink">{a.name}</span>
                      </div>
                      <div className="num mt-0.5 flex gap-2 text-[10px]">
                        <span className="text-ink-2">{usd(Number(a.cash_balance))}</span>
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
                      className="rounded p-1 text-[10px] text-ink-3 hover:bg-raised-3 hover:text-warn disabled:opacity-40"
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
                        className="rounded p-1 text-[10px] text-ink-3 hover:bg-raised-3 hover:text-neg disabled:opacity-40"
                      >
                        ✕
                      </button>
                    )}
                  </div>
                )
              })}
            </div>

            {creating ? (
              <div className="space-y-2 border-t border-line p-3">
                <input
                  value={newName}
                  onChange={(e) => setNewName(e.target.value)}
                  placeholder="Account name"
                  autoFocus
                  className="w-full rounded border border-raised-3 bg-surface px-2 py-1 text-xs text-ink focus:border-ink-3 focus:outline-none"
                />
                <div>
                  <label className="mb-1 block text-[10px] text-ink-3">Starting balance (USD)</label>
                  <input
                    type="number"
                    value={newBalance}
                    onChange={(e) => setNewBalance(e.target.value)}
                    className="num w-full rounded border border-raised-3 bg-surface px-2 py-1 text-right text-xs text-ink focus:border-ink-3 focus:outline-none"
                  />
                </div>
                {error && <p className="text-[10px] text-neg">{error}</p>}
                <div className="flex gap-2">
                  <button
                    onClick={submitCreate}
                    disabled={busy}
                    className="flex-1 rounded bg-gold py-1 text-xs font-medium text-white hover:bg-gold-hover disabled:opacity-40"
                  >
                    Create
                  </button>
                  <button
                    onClick={() => {
                      setCreating(false)
                      setError(null)
                    }}
                    className="rounded border border-raised-3 px-3 py-1 text-xs text-ink-2 hover:border-ink-3"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <button
                onClick={() => setCreating(true)}
                className="w-full border-t border-line px-3 py-2 text-left text-xs text-warn hover:bg-raised-2"
              >
                + New paper account
              </button>
            )}

            <div className="flex items-center justify-between border-t border-line bg-sub px-3 py-2">
              <span className="truncate text-[10px] text-ink-3">{email}</span>
              <button
                onClick={() => void supabase.auth.signOut()}
                className="text-[10px] text-ink-2 hover:text-neg"
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
      <div className="text-[10px] tracking-wider text-ink-3 uppercase">{label}</div>
      <div
        className={`num font-semibold ${className ?? (emphasis ? 'text-ink' : 'text-ink')}`}
      >
        {value}
      </div>
    </div>
  )
}
