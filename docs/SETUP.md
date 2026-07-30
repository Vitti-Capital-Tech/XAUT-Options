# Setup

## Prerequisites

| Requirement | Version | Notes |
| --- | --- | --- |
| Node.js | ≥ 20 | Developed on 24.x |
| npm | ≥ 10 | Ships with Node |
| Supabase project | — | Free tier is sufficient |

No Delta Exchange account or API key is required. The app reads only public
market-data endpoints.

---

## 1. Create a Supabase project

1. Sign in at [supabase.com](https://supabase.com).
2. **New project** — set a name, a database password, and a region near you.
3. Wait for provisioning (~2 minutes).

## 2. Deploy the schema

Open **SQL Editor → New query**, paste the entire contents of
[`supabase/migrations/0001_init.sql`](../supabase/migrations/0001_init.sql), and **Run**.

This creates:

| Object | Type | Purpose |
| --- | --- | --- |
| `accounts` | table | Paper sub-accounts and cash balance |
| `orders` | table | Order log; limit orders rest here as `open` |
| `fills` | table | Immutable execution history |
| `positions` | table | Netted position per (account, symbol) |
| `execute_fill` | function | Atomic fill: order + fill + position + balance |
| `reset_account` | function | Wipe an account's history, restore balance |
| `*_owner_all` | RLS policy | Restricts every table to `auth.uid()` |

Verify it worked — all four tables should return `200` and an empty array:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
  "$SUPABASE_URL/rest/v1/accounts?select=id&limit=1"
```

## 3. Configure the environment

From **Project Settings → API**, copy the values into a new `.env.local` in the
project root:

```
VITE_SUPABASE_URL=https://your-project-ref.supabase.co
VITE_SUPABASE_ANON_KEY=eyJhbGciOi...
```

> The anon key is designed to ship in a browser bundle — Row Level Security is
> what protects the data, not the key's secrecy. `.env.local` is gitignored
> regardless, so the project ref stays out of the repository.

Vite reads `.env.local` at startup only. **Restart the dev server after editing it.**

### Optional: the admin keyword

A keyword opens the admin panel, where paper accounts are created and managed.
It defaults to `trade`:

```
VITE_ADMIN_KEYWORD=your-word
```

There are three ways in:

| Route | Requires |
| --- | --- |
| **Manage accounts** in the account switcher | Being signed in |
| Typing the keyword anywhere in the terminal | Being signed in |
| Typing the keyword as the **password** on the login screen | The two variables below, dev server only |

The third skips the email box entirely by signing in with stored credentials:

```
VITE_ADMIN_EMAIL=you@example.com
VITE_ADMIN_PASSWORD=your-password
```

**Sign up once with that email first** — the shortcut will not create the
account, by design.

> **This one is dev-only, and enforced.** Vite inlines `import.meta.env` values
> into the output bundle, so a deployed production build carrying
> `VITE_ADMIN_PASSWORD` would hand that password to every visitor. The shortcut
> is gated on `import.meta.env.DEV`, which is false during `vite build`, and the
> resulting dead-code elimination strips the credentials and their code paths
> from the bundle entirely — verified by grepping `dist/`. Never set these two
> on a deployed host.

None of this is a security boundary: the keyword comparison runs in browser code
anyone can read. Auth and row-level security are what protect the data, and the
panel only ever touches the signed-in user's own accounts.

## 4. Optional — skip email confirmation

For local use, go to **Authentication → Sign In / Providers → Email** and turn
off *Confirm email*. You can then sign up and land straight in the dashboard
without a round trip through your inbox.

## 5. Run

```bash
npm install && npm run dev
```

Open <http://localhost:5173>, create an account, and you are trading.

---

## Scripts

| Command | Effect |
| --- | --- |
| `npm run dev` | Vite dev server on port 5173 with HMR |
| `npm run build` | Typecheck (`tsc -b`) then production bundle to `dist/` |
| `npm run preview` | Serve the built bundle locally |
| `npm run typecheck` | Types only, no emit |

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| "Supabase is not configured" | `.env.local` missing or unread | Create it, then **restart** the dev server |
| Sign-up succeeds but no session | *Confirm email* is enabled | Click the emailed link, or disable the setting (step 4) |
| `relation "accounts" does not exist` | Migration not run | Re-run step 2 |
| `violates row-level security policy` | Writing without a session | Sign in; RLS requires the `authenticated` role |
| Chain empty, status stuck `reconnecting` | WebSocket blocked | Check egress to `wss://socket.india.delta.exchange` |
| "No live XAUT option contracts" | No listed contracts, or REST blocked | Check `https://api.india.delta.exchange/v2/products` |
| Prices update but P&L reads `—` | Exit side of the book is empty | Expected on illiquid strikes; see LLD *Degradation* |

---

## Deployment notes

The app is a static bundle plus a hosted Postgres — `npm run build` output can go
on any static host (Vercel, Netlify, S3, Pages) with the two `VITE_*` variables
set at build time.

Two consequences of that shape are worth knowing before deploying:

- **Vite inlines env vars at build time**, not runtime. Changing the Supabase
  project means rebuilding.
- **The limit-order fill engine runs in the browser.** Resting orders only fill
  while a dashboard tab is open. Making fills tab-independent requires a
  Supabase Edge Function on a cron — see LLD *Deferred work*.
