import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

/** Surfaced in the UI so a missing .env.local reads as a setup step, not a crash. */
export const supabaseConfigured = Boolean(url && anonKey)

// Placeholder values keep createClient from throwing before the config banner renders.
export const supabase = createClient(url ?? 'http://localhost:54321', anonKey ?? 'anon', {
  auth: { persistSession: true, autoRefreshToken: true },
})
