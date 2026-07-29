import { useCallback, useEffect, useState } from 'react'
import { supabase } from '../lib/supabase'

export interface Account {
  id: string
  name: string
  starting_balance: string
  cash_balance: string
  created_at: string
}

const SELECTED_KEY = 'delta-paper.selected-account'

/**
 * The user's paper sub-accounts, plus which one is active.
 *
 * A first account is created automatically so a new user lands on a usable
 * dashboard instead of an empty-state dead end.
 */
export function useAccounts(userId: string | undefined) {
  const [accounts, setAccounts] = useState<Account[]>([])
  const [selectedId, setSelectedId] = useState<string | null>(
    () => localStorage.getItem(SELECTED_KEY),
  )
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    if (!userId) return
    const { data, error: err } = await supabase
      .from('accounts')
      .select('id, name, starting_balance, cash_balance, created_at')
      .eq('is_archived', false)
      .order('created_at', { ascending: true })

    if (err) {
      setError(err.message)
      setLoading(false)
      return
    }

    let rows = (data ?? []) as Account[]

    if (rows.length === 0) {
      const { data: created, error: createErr } = await supabase
        .from('accounts')
        .insert({ user_id: userId, name: 'Primary', starting_balance: 10000, cash_balance: 10000 })
        .select('id, name, starting_balance, cash_balance, created_at')
        .single()
      if (createErr) {
        setError(createErr.message)
        setLoading(false)
        return
      }
      rows = [created as Account]
    }

    setAccounts(rows)
    setError(null)
    setLoading(false)

    // Fall back to the first account if the remembered one is gone.
    setSelectedId((current) => (current && rows.some((r) => r.id === current) ? current : rows[0].id))
  }, [userId])

  useEffect(() => {
    void load()
  }, [load])

  useEffect(() => {
    if (selectedId) localStorage.setItem(SELECTED_KEY, selectedId)
  }, [selectedId])

  const createAccount = useCallback(
    async (name: string, startingBalance: number) => {
      if (!userId) return
      const { data, error: err } = await supabase
        .from('accounts')
        .insert({
          user_id: userId,
          name: name.trim(),
          starting_balance: startingBalance,
          cash_balance: startingBalance,
        })
        .select('id, name, starting_balance, cash_balance, created_at')
        .single()
      if (err) throw new Error(err.message)
      setAccounts((prev) => [...prev, data as Account])
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

  const archiveAccount = useCallback(
    async (accountId: string) => {
      const { error: err } = await supabase
        .from('accounts')
        .update({ is_archived: true })
        .eq('id', accountId)
      if (err) throw new Error(err.message)
      await load()
    },
    [load],
  )

  const selected = accounts.find((a) => a.id === selectedId) ?? null

  return {
    accounts,
    selected,
    selectedId: selected?.id ?? null,
    setSelectedId,
    loading,
    error,
    reload: load,
    createAccount,
    resetAccount,
    archiveAccount,
  }
}
