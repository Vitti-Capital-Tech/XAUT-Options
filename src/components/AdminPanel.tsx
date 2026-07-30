import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Account } from '../hooks/useAccounts'
import { supabase } from '../lib/supabase'
import { dateTime, pnlClass, signedUsd, usd } from '../lib/format'

interface Props {
  accounts: Account[]
  selectedId: string | null
  email: string | undefined
  onClose: () => void
  onCreate: (name: string, startingBalance: number) => Promise<void>
}

interface Counts {
  positions: number
  trades: number
  openOrders: number
}

/**
 * Admin surface for creating paper accounts and reviewing their state.
 *
 * Read-and-create only, by design: no rename, reset, archive or delete. Those
 * are destructive on a live system and were easy to hit by accident from a table
 * row. Switching the active account stays in the top-bar switcher.
 *
 * Everything here is the signed-in user's own data — row-level security means
 * these queries cannot see anyone else's rows, so the panel needs no privileged
 * role.
 */
export function AdminPanel({ accounts, selectedId, email, onClose, onCreate }: Props) {
  const [counts, setCounts] = useState<Record<string, Counts>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const [showNew, setShowNew] = useState(false)
  const [newName, setNewName] = useState('')
  const [newBalance, setNewBalance] = useState('10000')
  const [showArchived, setShowArchived] = useState(false)

  // Positions, fills and open orders for every account in three queries,
  // grouped here rather than one count query per account.
  const loadCounts = useCallback(async () => {
    const [pos, fills, orders] = await Promise.all([
      supabase.from('positions').select('account_id'),
      supabase.from('fills').select('account_id'),
      supabase.from('orders').select('account_id').eq('status', 'open'),
    ])
    const next: Record<string, Counts> = {}
    const bump = (id: string, key: keyof Counts) => {
      next[id] = next[id] ?? { positions: 0, trades: 0, openOrders: 0 }
      next[id][key] += 1
    }
    for (const r of pos.data ?? []) bump(r.account_id, 'positions')
    for (const r of fills.data ?? []) bump(r.account_id, 'trades')
    for (const r of orders.data ?? []) bump(r.account_id, 'openOrders')
    setCounts(next)
  }, [])

  useEffect(() => {
    void loadCounts()
  }, [loadCounts, accounts])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])

  const visible = useMemo(
    () => accounts.filter((a) => showArchived || !a.is_archived),
    [accounts, showArchived],
  )
  const archivedCount = accounts.filter((a) => a.is_archived).length
  const activeCount = accounts.length - archivedCount

  const totals = useMemo(() => {
    const active = accounts.filter((a) => !a.is_archived)
    return {
      allocated: active.reduce((s, a) => s + Number(a.starting_balance), 0),
      balance: active.reduce((s, a) => s + Number(a.cash_balance), 0),
      pnl: active.reduce((s, a) => s + Number(a.cash_balance) - Number(a.starting_balance), 0),
    }
  }, [accounts])

  const submitNew = async () => {
    const balance = Number(newBalance)
    if (!newName.trim()) return setError('Give the account a name')
    if (!Number.isFinite(balance) || balance <= 0) return setError('Starting balance must be positive')

    setBusy(true)
    setError(null)
    try {
      await onCreate(newName, balance)
      setNewName('')
      setNewBalance('10000')
      setShowNew(false)
      await loadCounts()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not create the account')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-surface">
      <header className="flex shrink-0 items-center gap-3 border-b border-line bg-raised px-4 py-2.5">
        <span className="text-sm font-bold tracking-tight text-brand-text">ADMIN</span>
        <span className="rounded bg-brand-muted px-1.5 py-0.5 text-[10px] font-bold tracking-wider text-brand-text uppercase">
          Paper accounts
        </span>
        <span className="text-[12px] text-ink-3">{email}</span>

        <div className="ml-auto flex items-center gap-5 text-[12px]">
          <Stat label="Accounts" value={String(activeCount)} />
          <Stat label="Allocated" value={usd(totals.allocated)} />
          <Stat label="Balance" value={usd(totals.balance)} />
          <Stat label="Net P&L" value={signedUsd(totals.pnl)} className={pnlClass(totals.pnl)} />
        </div>

        <button
          onClick={onClose}
          className="rounded border border-raised-3 px-3 py-1.5 text-xs text-ink hover:border-ink-3"
        >
          Back to terminal <span className="ml-1 text-ink-4">Esc</span>
        </button>
      </header>

      <div className="flex shrink-0 items-center gap-2 border-b border-line px-4 py-2">
        <button
          onClick={() => {
            setShowNew((v) => !v)
            setError(null)
          }}
          className="rounded bg-brand px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-hover"
        >
          + New paper account
        </button>
        {archivedCount > 0 && (
          <label className="flex cursor-pointer items-center gap-1.5 text-[12px] text-ink-2">
            <input
              type="checkbox"
              checked={showArchived}
              onChange={(e) => setShowArchived(e.target.checked)}
            />
            Show archived ({archivedCount})
          </label>
        )}
        {error && (
          <span className="ml-auto rounded bg-neg-muted px-2 py-1 text-[12px] text-neg">{error}</span>
        )}
      </div>

      {showNew && (
        <div className="flex shrink-0 items-end gap-3 border-b border-line bg-raised px-4 py-3">
          <label className="block">
            <span className="mb-1 block text-[10px] tracking-wider text-ink-3 uppercase">Name</span>
            <input
              value={newName}
              onChange={(e) => setNewName(e.target.value)}
              placeholder="e.g. Straddle test"
              autoFocus
              onKeyDown={(e) => e.key === 'Enter' && void submitNew()}
              className="w-56 rounded border border-raised-3 bg-surface px-2 py-1.5 text-[12px] text-ink focus:border-ink-3 focus:outline-none"
            />
          </label>
          <label className="block">
            <span className="mb-1 block text-[10px] tracking-wider text-ink-3 uppercase">
              Starting balance (USD)
            </span>
            <input
              type="number"
              value={newBalance}
              onChange={(e) => setNewBalance(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && void submitNew()}
              className="num w-40 rounded border border-raised-3 bg-surface px-2 py-1.5 text-right text-[12px] text-ink focus:border-ink-3 focus:outline-none"
            />
          </label>
          <button
            onClick={submitNew}
            disabled={busy}
            className="rounded bg-pos-solid px-4 py-1.5 text-xs font-semibold text-white hover:bg-pos-hover disabled:opacity-40"
          >
            {busy ? 'Creating…' : 'Create'}
          </button>
          <button
            onClick={() => setShowNew(false)}
            className="rounded border border-raised-3 px-3 py-1.5 text-xs text-ink-2 hover:border-ink-3"
          >
            Cancel
          </button>
        </div>
      )}

      <div className="min-h-0 flex-1 overflow-auto">
        <table className="w-full text-[12px]">
          <thead>
            <tr>
              <Th align="left">Account</Th>
              <Th align="left">Created</Th>
              <Th>Starting</Th>
              <Th>Balance</Th>
              <Th>Realized P&L</Th>
              <Th>Positions</Th>
              <Th>Open orders</Th>
              <Th>Trades</Th>
              <Th align="left">Status</Th>
            </tr>
          </thead>
          <tbody>
            {visible.map((a) => {
              const c = counts[a.id] ?? { positions: 0, trades: 0, openOrders: 0 }
              const pnl = Number(a.cash_balance) - Number(a.starting_balance)
              const isActive = a.id === selectedId

              return (
                <tr key={a.id} className="border-b border-line hover:bg-raised/50">
                  <Td align="left">
                    <span className="flex items-center gap-1.5">
                      {isActive && <span className="text-[10px] text-brand-text">●</span>}
                      <span className="font-medium text-ink">{a.name}</span>
                    </span>
                  </Td>
                  <Td align="left" className="text-ink-3">
                    {dateTime(a.created_at)}
                  </Td>
                  <Td className="text-ink-2">{usd(Number(a.starting_balance))}</Td>
                  <Td className="text-ink">{usd(Number(a.cash_balance))}</Td>
                  <Td className={pnlClass(pnl)}>{signedUsd(pnl)}</Td>
                  <Td className={c.positions ? 'text-ink' : 'text-ink-4'}>{c.positions}</Td>
                  <Td className={c.openOrders ? 'text-ink' : 'text-ink-4'}>{c.openOrders}</Td>
                  <Td className={c.trades ? 'text-ink' : 'text-ink-4'}>{c.trades}</Td>
                  <Td align="left">
                    {a.is_archived ? (
                      <span className="rounded bg-raised-2 px-1.5 py-0.5 text-[10px] text-ink-3">
                        Archived
                      </span>
                    ) : isActive ? (
                      <span className="rounded bg-brand-muted px-1.5 py-0.5 text-[10px] text-brand-text">
                        Active
                      </span>
                    ) : (
                      <span className="text-[10px] text-ink-3">Idle</span>
                    )}
                  </Td>
                </tr>
              )
            })}
          </tbody>
        </table>

        {visible.length === 0 && (
          <p className="px-4 py-8 text-center text-[12px] text-ink-3">No accounts to show.</p>
        )}

        <p className="border-t border-line px-4 py-3 text-[10px] text-ink-4">
          Switch the active account from the switcher in the top bar.
        </p>
      </div>
    </div>
  )
}

function Stat({
  label,
  value,
  className,
}: {
  label: string
  value: string
  className?: string
}) {
  return (
    <div className="text-right">
      <div className="text-[10px] tracking-wider text-ink-3 uppercase">{label}</div>
      <div className={`num font-semibold ${className ?? 'text-ink'}`}>{value}</div>
    </div>
  )
}

function Th({ children, align = 'right' }: { children: React.ReactNode; align?: 'left' | 'right' }) {
  return (
    <th
      className={`sticky top-0 z-10 bg-raised px-3 py-2 text-[10px] font-semibold tracking-wider text-ink-3 uppercase ${
        align === 'left' ? 'text-left' : 'text-right'
      }`}
    >
      {children}
    </th>
  )
}

function Td({
  children,
  align = 'right',
  className = '',
}: {
  children?: React.ReactNode
  align?: 'left' | 'right'
  className?: string
}) {
  return (
    <td className={`num px-3 py-2 ${align === 'left' ? 'text-left' : 'text-right'} ${className}`}>
      {children}
    </td>
  )
}
