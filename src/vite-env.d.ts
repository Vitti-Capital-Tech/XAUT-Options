/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string | undefined
  readonly VITE_SUPABASE_ANON_KEY: string | undefined
  /** Word that opens the admin panel. Defaults to 'trade' when unset. */
  readonly VITE_ADMIN_KEYWORD: string | undefined
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
