import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export interface Account {
  id: string
  name: string
  starting_balance: string
  cash_balance: string
  is_archived: boolean
  created_at: string
}

const COLS = 'id, name, starting_balance, cash_balance, is_archived, created_at'
const SELECTED_KEY = 'delta-paper.selected-account'

/**
 * The user's paper sub-accounts, plus which one is active.
 *
 * Archived accounts are loaded too — the terminal filters them out, but the
 * admin panel needs to see them in order to restore or delete them.
 *
 * A first account is created automatically so a new user lands on a usable
 * dashboard instead of an empty-state dead end.
 */
export function useAccounts(userId: string | undefined) {
  const [allAccounts, setAllAccounts] = useState<Account[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(() =>
    localStorage.getItem(SELECTED_KEY),
  )
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!userId) return
    const { data, error: err } = await supabase
      .from('accounts')
      .select(COLS)
      .order('created_at', { ascending: true })

    if (err) {
      setError(err.message)
      setLoading(false)
      return
    }

    let rows = (data ?? []) as Account[]

    // Only auto-create when there is genuinely nothing, archived included.
    if (rows.length === 0) {
      const { data: created, error: createErr } = await supabase
        .from('accounts')
        .insert({ user_id: userId, name: 'Primary', starting_balance: 10000, cash_balance: 10000 })
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
  }, [userId])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    if (selectedId) localStorage.setItem(SELECTED_KEY, selectedId)
  }, [selectedId])

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
        })
        .select(COLS)
        .single()
      if (err) throw new Error(err.message)
      setAllAccounts((prev) => [...prev, data as Account])
      setSelectedId((data as Account).id)
    },
    [userId],
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
    resetAccount,
    setArchived,
  }
}
