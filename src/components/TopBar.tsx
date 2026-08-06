import { useEffect, useRef, useState } from 'react'
import type { Account } from '../hooks/useAccounts'
import type { AccountSummary } from '../engine/paper'
import { market, useMarketTick } from '../lib/marketStore'
import { pnlClass, signedUsd, usd } from '../lib/format'
import { supabase } from '../lib/supabase'
import { Logo } from './Logo'

export type Page = 'chain' | 'strategy'

interface Props {
  accounts: Account[]
  selected: Account | null
  summary: AccountSummary
  email: string | undefined
  /** The page showing now, and how to switch. */
  page: Page
  onNavigate: (page: Page) => void
  onSelect: (id: string) => void
  onCreate: (name: string, startingBalance: number) => Promise<void>
  /**
   * Rebase the balance, keeping whatever the account has already made or lost —
   * unlike a reset, which throws the history away along with the P&L.
   */
  onSetBalance: (id: string, startingBalance: number) => Promise<void>
  onReset: (id: string) => Promise<void>
  onArchive: (id: string) => Promise<void>
  onOpenAdmin: () => void
  /** Shown in the menu so the shortcut is discoverable rather than folklore. */
  adminKeyword: string
}

export function TopBar({
  accounts,
  selected,
  summary,
  email,
  page,
  onNavigate,
  onSelect,
  onCreate,
  onSetBalance,
  onReset,
  onArchive,
  onOpenAdmin,
  adminKeyword,
}: Props) {
  // Subscribed in its own right, not merely repainted by the summary prop:
  // setStatus flushes the moment the socket drops, and that is precisely when
  // no ticks are arriving to repaint us. A stale 'Live' is worse than no badge.
  useMarketTick()
  const status = market.status

  const [menuOpen, setMenuOpen] = useState(false)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')
  const [newBalance, setNewBalance] = useState('10000')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  // The account whose balance is being edited in place, and the draft figure.
  const [editingId, setEditingId] = useState<string | null>(null)
  const [draftBalance, setDraftBalance] = useState('')
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
      {/* Mark, wordmark, and the one badge that matters: none of this is real
          money. Spot lives in the chain header, where the strikes it is being
          read against are. */}
      <div className="flex items-center gap-2.5">
        <Logo />
        <div className="leading-none">
          <div className="logo-word text-[15px] font-bold tracking-tight">XAUT</div>
          <div className="mt-[3px] text-[9px] font-semibold tracking-[0.18em] text-ink-3 uppercase">
            Options
          </div>
        </div>
        <span className="self-start rounded-sm border border-brand-text/40 bg-brand-muted px-1.5 py-0.5 text-[9px] font-bold tracking-wider text-brand-text uppercase">
          Paper
        </span>
      </div>

      {/* The pages. Two for now — the chain and the bot — read as the section
          nav, in the same weight the expiry pills use below. */}
      <nav className="ml-3 flex items-center gap-1">
        <NavLink label="Option Chain" active={page === 'chain'} onClick={() => onNavigate('chain')} />
        <NavLink
          label="Auto Strategy"
          active={page === 'strategy'}
          onClick={() => onNavigate('strategy')}
        />
      </nav>

      <div className="ml-auto flex items-center gap-5 text-[12px]">
        <Stat label="Balance" value={usd(summary.balance)} />
        <Stat
          label="Unrealized"
          value={signedUsd(summary.unrealized, 4)}
          className={pnlClass(summary.unrealized)}
        />
        {/* Everything the account has made since it opened, booked and open. */}
        <Stat
          label="Total P&L"
          value={signedUsd(summary.totalPnl, 4)}
          className={pnlClass(summary.totalPnl)}
          emphasis
        />
        <Stat label="Equity" value={usd(summary.equity)} emphasis />
        <Stat label="Margin" value={usd(summary.marginBlocked, 4)} />
        <Stat
          label="Available"
          value={usd(summary.available)}
          className={summary.available < 0 ? 'text-neg' : undefined}
        />
      </div>

      {/* Feed health belongs with the session chrome, beside the account it is
          a property of the connection rather than of the branding or the money.
          Dead feeds pulse, because a still red dot is easy to read past. */}
      <div
        className="flex items-center gap-1.5 rounded border border-raised-3 px-2 py-1"
        title={`Market data: ${status}`}
      >
        <span
          className={`h-1.5 w-1.5 shrink-0 rounded-full ${
            status === 'live'
              ? 'bg-pos-solid'
              : status === 'connecting'
                ? 'bg-brand'
                : 'animate-pulse bg-neg-solid'
          }`}
        />
        <span className="text-[10px] font-semibold tracking-wider text-ink-3 uppercase">
          {status}
        </span>
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

                // Editing takes the whole row: a number field this narrow next
                // to a name and two figures would be unreadable.
                if (editingId === a.id) {
                  const save = async () => {
                    const n = Number(draftBalance)
                    if (!Number.isFinite(n) || n <= 0) return setError('Balance must be positive')
                    setBusy(true)
                    setError(null)
                    try {
                      await onSetBalance(a.id, n)
                      setEditingId(null)
                    } catch (err) {
                      setError(err instanceof Error ? err.message : 'Could not set balance')
                    } finally {
                      setBusy(false)
                    }
                  }
                  return (
                    <div key={a.id} className="space-y-1.5 border-b border-line bg-sub px-3 py-2">
                      <div className="text-[10px] tracking-wider text-ink-3 uppercase">
                        Balance · {a.name}
                      </div>
                      <input
                        type="number"
                        value={draftBalance}
                        onChange={(e) => setDraftBalance(e.target.value)}
                        onKeyDown={(e) => {
                          if (e.key === 'Enter') void save()
                          if (e.key === 'Escape') setEditingId(null)
                        }}
                        autoFocus
                        className="num w-full rounded border border-raised-3 bg-surface px-2 py-1 text-right text-xs text-ink focus:border-ink-3 focus:outline-none"
                      />
                      <p className="text-[10px] text-ink-3">
                        Keeps this account's {signedUsd(pnl)} of P&amp;L and its history — only the
                        baseline moves.
                      </p>
                      {error && <p className="text-[10px] text-neg">{error}</p>}
                      <div className="flex gap-2">
                        <button
                          onClick={save}
                          disabled={busy}
                          className="flex-1 rounded bg-brand py-1 text-xs font-medium text-white hover:bg-brand-hover disabled:opacity-40"
                        >
                          Save
                        </button>
                        <button
                          onClick={() => {
                            setEditingId(null)
                            setError(null)
                          }}
                          className="rounded border border-raised-3 px-3 py-1 text-xs text-ink-2 hover:border-ink-3"
                        >
                          Cancel
                        </button>
                      </div>
                    </div>
                  )
                }

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
                        {isActive && <span className="text-[10px] text-brand-text">●</span>}
                        <span className="truncate text-xs font-medium text-ink">{a.name}</span>
                      </div>
                      <div className="num mt-0.5 flex gap-2 text-[10px]">
                        <span className="text-ink-2">{usd(Number(a.cash_balance))}</span>
                        <span className={pnlClass(pnl)}>{signedUsd(pnl)}</span>
                      </div>
                    </button>
                    <button
                      onClick={() => {
                        setDraftBalance(String(Number(a.starting_balance)))
                        setEditingId(a.id)
                        setError(null)
                      }}
                      title="Edit balance, keeping P&L and history"
                      className="rounded p-1 text-[10px] text-ink-3 hover:bg-raised-3 hover:text-brand-text"
                    >
                      ✎
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
                      className="rounded p-1 text-[10px] text-ink-3 hover:bg-raised-3 hover:text-brand-text disabled:opacity-40"
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
                    className="flex-1 rounded bg-brand py-1 text-xs font-medium text-white hover:bg-brand-hover disabled:opacity-40"
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
                className="w-full border-t border-line px-3 py-2 text-left text-xs text-brand-text hover:bg-raised-2"
              >
                + New paper account
              </button>
            )}

            <button
              onClick={() => {
                setMenuOpen(false)
                onOpenAdmin()
              }}
              className="flex w-full items-center justify-between border-t border-line px-3 py-2 text-left text-xs text-ink-2 hover:bg-raised-2 hover:text-ink"
            >
              Manage accounts
              <span className="rounded bg-raised-2 px-1.5 py-0.5 text-[10px] text-ink-3">
                type {adminKeyword}
              </span>
            </button>

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

function NavLink({
  label,
  active,
  onClick,
}: {
  label: string
  active: boolean
  onClick: () => void
}) {
  return (
    <button
      onClick={onClick}
      className={`rounded px-3 py-1.5 text-[13px] font-medium transition-colors ${
        active ? 'bg-raised-2 text-ink' : 'text-ink-3 hover:text-ink'
      }`}
    >
      {label}
    </button>
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
        className={`num font-semibold ${emphasis ? 'text-[13px]' : ''} ${className ?? 'text-ink'}`}
      >
        {value}
      </div>
    </div>
  )
}
