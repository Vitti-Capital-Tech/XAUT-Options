import { useCallback, useEffect, useMemo, useState } from 'react'
import type { Account } from '../hooks/useAccounts'
import { supabase } from '../lib/supabase'
import { dateTime, pnlClass, signedUsd, usd } from '../lib/format'

interface Props {
  accounts: Account[]
  selectedId: string | null
  email: string | undefined
  onClose: () => void
  onSelect: (id: string) => void
  onCreate: (name: string, startingBalance: number) => Promise<void>
  onRename: (id: string, name: string) => Promise<void>
  onSetStartingBalance: (id: string, value: number) => Promise<void>
  onReset: (id: string) => Promise<void>
  onSetArchived: (id: string, archived: boolean) => Promise<void>
  onDelete: (id: string) => Promise<void>
}

interface Counts {
  positions: number
  trades: number
  openOrders: number
}

/** One row of `account_counts` (0063). Counts arrive as bigint, so as strings
 *  over PostgREST on a large enough number — read through `Number`. */
interface AccountCountRow {
  acct_id: string
  position_count: number | string
  fill_count: number | string
  open_order_count: number | string
}

/**
 * Admin surface for managing paper accounts, opened by typing the admin keyword.
 *
 * Everything here operates on the signed-in user's own accounts. Row-level
 * security means the queries below cannot see or touch anyone else's rows, so
 * the panel needs no privileged role — it is a fuller management view, not an
 * escalation.
 */
export function AdminPanel({
  accounts,
  selectedId,
  email,
  onClose,
  onSelect,
  onCreate,
  onRename,
  onSetStartingBalance,
  onReset,
  onSetArchived,
  onDelete,
}: Props) {
  const [counts, setCounts] = useState<Record<string, Counts>>({})
  const [busyId, setBusyId] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [confirmDelete, setConfirmDelete] = useState<string | null>(null)
  const [editing, setEditing] = useState<string | null>(null)
  const [draftName, setDraftName] = useState('')
  const [draftBalance, setDraftBalance] = useState('')

  const [showNew, setShowNew] = useState(false)
  const [newName, setNewName] = useState('')
  const [newBalance, setNewBalance] = useState('10000')
  const [showArchived, setShowArchived] = useState(false)

  /**
   * Positions, trades and resting orders per account, counted in the database.
   *
   * This used to fetch every row of all three tables and count them here, which
   * meant shipping the entire ledger — a table that only grows — to render three
   * two-digit numbers. `account_counts` (0063) does the counting off the
   * account_id indexes and returns one row per account. It runs as the caller,
   * so RLS scopes it to this user's own books exactly as the old queries were.
   */
  const loadCounts = useCallback(async () => {
    const { data, error: err } = await supabase.rpc('account_counts')
    if (err) {
      // Not worth blocking the panel over: the accounts themselves are already
      // on screen and every action here works without a count beside it.
      console.error('account_counts failed:', err.message)
      return
    }
    const next: Record<string, Counts> = {}
    for (const r of (data ?? []) as AccountCountRow[]) {
      next[r.acct_id] = {
        positions: Number(r.position_count),
        trades: Number(r.fill_count),
        openOrders: Number(r.open_order_count),
      }
    }
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

  /** Wrap a mutation with busy state and error surfacing. */
  const run = async (id: string, fn: () => Promise<void>) => {
    setBusyId(id)
    setError(null)
    try {
      await fn()
      await loadCounts()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Something went wrong')
    } finally {
      setBusyId(null)
    }
  }

  const submitNew = async () => {
    const balance = Number(newBalance)
    if (!newName.trim()) return setError('Give the account a name')
    if (!Number.isFinite(balance) || balance <= 0) return setError('Starting balance must be positive')
    await run('new', async () => {
      await onCreate(newName, balance)
      setNewName('')
      setNewBalance('10000')
      setShowNew(false)
    })
  }

  const startEdit = (a: Account) => {
    setEditing(a.id)
    setDraftName(a.name)
    setDraftBalance(String(Number(a.starting_balance)))
    setConfirmDelete(null)
    setError(null)
  }

  const saveEdit = async (a: Account) => {
    const balance = Number(draftBalance)
    await run(a.id, async () => {
      if (draftName.trim() && draftName.trim() !== a.name) await onRename(a.id, draftName)
      if (Number.isFinite(balance) && balance > 0 && balance !== Number(a.starting_balance)) {
        await onSetStartingBalance(a.id, balance)
      }
      setEditing(null)
    })
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
            disabled={busyId === 'new'}
            className="rounded bg-pos-solid px-4 py-1.5 text-xs font-semibold text-white hover:bg-pos-hover disabled:opacity-40"
          >
            {busyId === 'new' ? 'Creating…' : 'Create'}
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
              <Th align="right">Actions</Th>
            </tr>
          </thead>
          <tbody>
            {visible.map((a) => {
              const c = counts[a.id] ?? { positions: 0, trades: 0, openOrders: 0 }
              const pnl = Number(a.cash_balance) - Number(a.starting_balance)
              const isActive = a.id === selectedId
              const busy = busyId === a.id
              const isEditing = editing === a.id

              return (
                <tr key={a.id} className="border-b border-line hover:bg-raised/50">
                  <Td align="left">
                    {isEditing ? (
                      <input
                        value={draftName}
                        onChange={(e) => setDraftName(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && void saveEdit(a)}
                        autoFocus
                        className="w-44 rounded border border-raised-3 bg-surface px-1.5 py-1 text-[12px] text-ink focus:border-ink-3 focus:outline-none"
                      />
                    ) : (
                      <span className="flex items-center gap-1.5">
                        {isActive && <span className="text-[10px] text-brand-text">●</span>}
                        <span className="font-medium text-ink">{a.name}</span>
                      </span>
                    )}
                  </Td>
                  <Td align="left" className="text-ink-3">
                    {dateTime(a.created_at)}
                  </Td>
                  <Td>
                    {isEditing ? (
                      <input
                        type="number"
                        value={draftBalance}
                        onChange={(e) => setDraftBalance(e.target.value)}
                        onKeyDown={(e) => e.key === 'Enter' && void saveEdit(a)}
                        className="num w-28 rounded border border-raised-3 bg-surface px-1.5 py-1 text-right text-[12px] text-ink focus:border-ink-3 focus:outline-none"
                      />
                    ) : (
                      <span className="text-ink-2">{usd(Number(a.starting_balance))}</span>
                    )}
                  </Td>
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
                  <Td align="right">
                    {confirmDelete === a.id ? (
                      <div className="flex items-center justify-end gap-1.5">
                        <span className="text-[10px] text-neg">
                          Delete with {c.trades} trades?
                        </span>
                        <Action
                          tone="danger"
                          busy={busy}
                          onClick={() => run(a.id, () => onDelete(a.id))}
                        >
                          Yes, delete
                        </Action>
                        <Action onClick={() => setConfirmDelete(null)}>No</Action>
                      </div>
                    ) : isEditing ? (
                      <div className="flex items-center justify-end gap-1.5">
                        <Action tone="ok" busy={busy} onClick={() => saveEdit(a)}>
                          Save
                        </Action>
                        <Action onClick={() => setEditing(null)}>Cancel</Action>
                      </div>
                    ) : (
                      <div className="flex items-center justify-end gap-1.5">
                        {!a.is_archived && !isActive && (
                          <Action onClick={() => onSelect(a.id)}>Use</Action>
                        )}
                        <Action onClick={() => startEdit(a)}>Edit</Action>
                        <Action
                          busy={busy}
                          title="Restore the starting balance and delete this account's positions, orders and trade history"
                          onClick={() => run(a.id, () => onReset(a.id))}
                        >
                          Reset
                        </Action>
                        <Action
                          busy={busy}
                          onClick={() => run(a.id, () => onSetArchived(a.id, !a.is_archived))}
                        >
                          {a.is_archived ? 'Restore' : 'Archive'}
                        </Action>
                        <Action tone="danger" onClick={() => setConfirmDelete(a.id)}>
                          Delete
                        </Action>
                      </div>
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

        <p className="border-t border-line px-4 py-3 text-[10px] leading-relaxed text-ink-4">
          Reset restores the starting balance and clears that account's positions, orders and trade
          history. Delete removes the account and all of its records permanently — there is no undo.
          Editing a starting balance keeps the realized P&L that account has already made.
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

function Action({
  children,
  onClick,
  tone,
  busy = false,
  title,
}: {
  children: React.ReactNode
  onClick: () => void
  tone?: 'danger' | 'ok'
  busy?: boolean
  title?: string
}) {
  const border =
    tone === 'danger'
      ? 'border-raised-3 text-ink-2 hover:border-neg hover:text-neg'
      : tone === 'ok'
        ? 'border-pos text-pos hover:bg-pos-muted'
        : 'border-raised-3 text-ink-2 hover:border-ink-3 hover:text-ink'

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={busy}
      title={title}
      className={`rounded border px-2 py-0.5 text-[10px] whitespace-nowrap transition-colors disabled:opacity-40 ${border}`}
    >
      {busy ? '…' : children}
    </button>
  )
}
