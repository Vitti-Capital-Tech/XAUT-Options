import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { useDebouncedCallback } from './usePolling'

/**
 * Manual accounts belong to the option chain, auto accounts to the auto
 * strategy, delta accounts to the delta management strategy. One kind per page,
 * so the three books never share a balance or a position.
 */
export type AccountKind = 'manual' | 'auto' | 'delta' | 'futures'

export interface Account {
  id: string
  name: string
  starting_balance: string
  cash_balance: string
  is_archived: boolean
  kind: AccountKind
  created_at: string
}

const COLS = 'id, name, starting_balance, cash_balance, is_archived, kind, created_at'
const SELECTED_KEY = 'delta-paper.selected-account'

/**
 * The user's paper sub-accounts of one kind, plus which one is active. The chain
 * and the strategy each call this with their own kind, so the two books keep
 * separate account lists, balances and selections.
 *
 * Archived accounts are loaded too — the terminal filters them out, but the
 * admin panel needs to see them in order to restore or delete them.
 *
 * A first account is created automatically so a page lands on a usable book
 * instead of an empty-state dead end.
 */
export function useAccounts(userId: string | undefined, kind: AccountKind = 'manual') {
  // Remember the selection per kind, so switching pages does not cross the two.
  const selectedKey = `${SELECTED_KEY}.${kind}`
  const [allAccounts, setAllAccounts] = useState<Account[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(() =>
    localStorage.getItem(selectedKey),
  )
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!userId) return
    const { data, error: err } = await supabase
      .from('accounts')
      .select(COLS)
      .eq('kind', kind)
      .order('created_at', { ascending: true })

    if (err) {
      setError(err.message)
      setLoading(false)
      return
    }

    let rows = (data ?? []) as Account[]

    // Only auto-create when this kind has genuinely nothing, archived included.
    if (rows.length === 0) {
      const { data: created, error: createErr } = await supabase
        .from('accounts')
        .insert({ user_id: userId, name: 'Primary', starting_balance: 10000, cash_balance: 10000, kind })
        .select(COLS)
        .single()
      if (createErr) {
        setError(createErr.message)
        setLoading(false)
        return
      }
      rows = [created as Account]
    }

    setAllAccounts(rows)
    setError(null)
    setLoading(false)

    // Keep the remembered selection if it is still active, else fall back.
    const active = rows.filter((r) => !r.is_archived)
    setSelectedId((current) =>
      current && active.some((r) => r.id === current) ? current : (active[0]?.id ?? null),
    )
  }, [userId, kind])

  useEffect(() => {
    void load()
  }, [load])

  // Realtime: a balance moving or an account being added/edited in one session
  // reflects in every other at once. load() through a ref so the subscription
  // survives renders.
  const loadRef = useRef(load)
  loadRef.current = load

  // Debounced because a single fill moves the balance once but can arrive
  // alongside the position and order writes of the same cycle.
  const bump = useDebouncedCallback(() => void loadRef.current(), 150)

  useEffect(() => {
    if (!userId) return
    // Best-effort: realtime is an enhancement, so a failure to subscribe must
    // never blank the app — swallow it and let an explicit reload cover.
    // Unique per kind: all four pages call this with the same userId, so a
    // shared channel name would be a duplicate subscription.
    try {
      const channel = supabase
        .channel(`accounts-${kind}-${userId}`)
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'accounts', filter: `user_id=eq.${userId}` },
          (payload) => {
            // Four instances of this hook are mounted at once, one per kind, and
            // every one of them is subscribed to the same `user_id` filter —
            // that filter is all Postgres can express. So each of them is told
            // about every account this user owns, and a single balance change
            // used to cost four fetches, three of them for books whose rows had
            // not moved. The kind is on the row: ignore what is not ours.
            //
            // A delete carries only the primary key unless the table is set to
            // REPLICA IDENTITY FULL, so `kind` is absent there and the reload
            // goes ahead — the safe way round, and rare enough not to matter.
            const row = (payload.new ?? payload.old) as { kind?: AccountKind } | undefined
            if (row?.kind && row.kind !== kind) return
            bump()
          },
        )
        .subscribe()
      return () => {
        void supabase.removeChannel(channel)
      }
    } catch (err) {
      console.error('accounts realtime failed:', err)
    }
  }, [userId, kind, bump])

  useEffect(() => {
    if (selectedId) localStorage.setItem(selectedKey, selectedId)
  }, [selectedId, selectedKey])

  const createAccount = useCallback(
    async (name: string, startingBalance: number) => {
      if (!userId) throw new Error('Not signed in')
      const { data, error: err } = await supabase
        .from('accounts')
        .insert({
          user_id: userId,
          name: name.trim(),
          starting_balance: startingBalance,
          cash_balance: startingBalance,
          kind,
        })
        .select(COLS)
        .single()
      if (err) throw new Error(err.message)
      setAllAccounts((prev) => [...prev, data as Account])
      setSelectedId((data as Account).id)
    },
    [userId, kind],
  )

  const renameAccount = useCallback(
    async (accountId: string, name: string) => {
      const trimmed = name.trim()
      if (!trimmed) throw new Error('Name cannot be empty')
      const { error: err } = await supabase
        .from('accounts')
        .update({ name: trimmed })
        .eq('id', accountId)
      if (err) throw new Error(err.message)
      await load()
    },
    [load],
  )

  /**
   * Rebase an account's starting balance, keeping whatever it has already made
   * or lost. Realized P&L is `cash_balance - starting_balance`, so both columns
   * move by the same delta and the P&L figure survives.
   *
   * The row is re-read immediately beforehand so a fill landing between the
   * panel's last load and this write is not clobbered.
   */
  const setStartingBalance = useCallback(
    async (accountId: string, newStartingBalance: number) => {
      if (!Number.isFinite(newStartingBalance) || newStartingBalance <= 0) {
        throw new Error('Starting balance must be a positive number')
      }

      const { data: fresh, error: readErr } = await supabase
        .from('accounts')
        .select('starting_balance, cash_balance')
        .eq('id', accountId)
        .single()
      if (readErr) throw new Error(readErr.message)

      const realized = Number(fresh.cash_balance) - Number(fresh.starting_balance)
      const { error: err } = await supabase
        .from('accounts')
        .update({
          starting_balance: newStartingBalance,
          cash_balance: newStartingBalance + realized,
        })
        .eq('id', accountId)
      if (err) throw new Error(err.message)
      await load()
    },
    [load],
  )

  const resetAccount = useCallback(
    async (accountId: string) => {
      const { error: err } = await supabase.rpc('reset_account', { p_account_id: accountId })
      if (err) throw new Error(err.message)
      await load()
    },
    [load],
  )

  const setArchived = useCallback(
    async (accountId: string, archived: boolean) => {
      const { error: err } = await supabase
        .from('accounts')
        .update({ is_archived: archived })
        .eq('id', accountId)
      if (err) throw new Error(err.message)
      await load()
    },
    [load],
  )

  /**
   * Permanently remove an account. Its orders, fills and positions go with it —
   * every one of those tables declares `on delete cascade` against accounts.
   * There is no undo, which is why the panel makes the caller confirm twice.
   */
  const deleteAccount = useCallback(
    async (accountId: string) => {
      const { error: err } = await supabase.from('accounts').delete().eq('id', accountId)
      if (err) throw new Error(err.message)
      // Drop the selection if it pointed here; load() picks a new one.
      setSelectedId((current) => (current === accountId ? null : current))
      await load()
    },
    [load],
  )

  const accounts = allAccounts.filter((a) => !a.is_archived)
  const selected = accounts.find((a) => a.id === selectedId) ?? null

  return {
    /** Active accounts only — what the terminal shows. */
    accounts,
    /** Active and archived, for the admin panel. */
    allAccounts,
    selected,
    selectedId: selected?.id ?? null,
    setSelectedId,
    loading,
    error,
    reload: load,
    createAccount,
    renameAccount,
    setStartingBalance,
    resetAccount,
    setArchived,
    deleteAccount,
  }
}
