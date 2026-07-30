/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string | undefined
  readonly VITE_SUPABASE_ANON_KEY: string | undefined
  /** Word that opens the admin panel. Defaults to 'trade' when unset. */
  readonly VITE_ADMIN_KEYWORD: string | undefined
  /**
   * Credentials the keyword signs in with on the login screen. Dev builds only —
   * see src/lib/admin.ts for why these must never reach a production bundle.
   */
  readonly VITE_ADMIN_EMAIL: string | undefined
  readonly VITE_ADMIN_PASSWORD: string | undefined
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
