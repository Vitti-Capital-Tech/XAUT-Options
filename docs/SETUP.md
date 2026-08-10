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

Open **SQL Editor → New query** and run each migration in
[`supabase/migrations/`](../supabase/migrations/) **in numerical order**, one
file at a time. Each is a whole-file paste-and-Run, and each assumes its
predecessors have already been applied — several `alter` tables or replace
functions the earlier ones created, so skipping or reordering will fail.

| Migration | Adds |
| --- | --- |
| `0001_init` | Core schema — `accounts`, `orders`, `fills`, `positions`, `execute_fill`, `reset_account`, RLS |
| `0002_settlement` | Expiry settlement on `pg_cron`; enables `pg_net` and `pg_cron` |
| `0003_tpsl` | Take-profit / stop-loss levels, armed server-side |
| `0004_tpsl_trigger` | Whether a bracket watches the index or the mark |
| `0005_fill_reason` | Records *why* a triggered close fired |
| `0006_tpsl_cadence` | Tightens the TP/SL cron cadence |
| `0007_account_kind` | `accounts.kind` — splits the manual and auto books |
| `0008_strategy_engine` | `strategy_settings` and the server-side **auto strategy** |
| `0009_realtime` | Realtime publication, so a second tab updates without a poll |
| `0010_delta_strategy` | `delta` account kind and `delta_strategy_settings` |
| `0011_strategy_expiry_fix` | **Required.** Fixes the auto strategy reading an expiry field the tickers feed never sends — without it, it never places a single entry |
| `0012_delta_strategy_engine` | `delta_chain` and the server-side **delta strategy** engine |
| `0013_delta_take_profit` | Take-profit on every delta strategy short; no stop |
| `0014_delta_take_profit_mark` | Reads that take-profit as a price on the option's mark rather than a multiple of the premium sold |
| `0015_auto_strategy_exit` | The auto strategy flattens past `window_end` instead of holding overnight; shares one window test with the entry gate |
| `0016_strategy_trade_days` | `trade_days` on both strategies — which days of the week each trades, on its own clock |
| `0017_auto_strategy_min_premium` | `min_premium` on the auto strategy — skip a bar whose strike is bid under the floor |

The first ten create the schema; `0011` is a bug fix, `0012` moves the delta
strategy's engine server-side, `0013`–`0014` bracket what it sells, `0015` gives
the auto strategy a close to match its open, and `0016`–`0017` add its entry
filters. A fresh install wants all seventeen.

After `0012`, four cron jobs should be scheduled — confirm with:

```sql
select jobname, schedule, active from cron.job;
```

You want `settlement-poll`, `settlement-apply`, `tpsl-poll`, `tpsl-apply`,
`strategy-poll`, `strategy-apply`, `delta-poll` and `delta-apply`. If `cron.job`
is empty, `pg_cron` was not enabled — re-run `0002_settlement.sql`, which is
where both extensions are created.

Verify the core tables — all four should return `200` and an empty array:

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

> **Dev server only by default, and enforced.** Vite inlines `import.meta.env`
> values into the output bundle, so a production build carrying
> `VITE_ADMIN_PASSWORD` would hand that password to every visitor. The shortcut
> is gated on `import.meta.env.DEV`, which is false during `vite build`, and the
> resulting dead-code elimination strips the credentials and their code paths
> out entirely — verified by grepping `dist/`.

If you see **"This is a production build, where keyword sign-in is off by
default"**, you are not on the dev server. Either run:

```bash
npm run dev
```

or, if you genuinely want the shortcut in a built copy — `npm run preview`, or a
build you host on your own machine — opt in:

```
VITE_ALLOW_KEYWORD_LOGIN=true
```

> That override makes the branch reachable, so the password really is readable in
> the shipped JavaScript. Confirmed by building both ways: without it the
> credentials are absent from `dist/`, with it they are present. The login screen
> shows a red warning whenever it is active, so it cannot be left on unnoticed.
> Only for a machine nobody else can reach.

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
