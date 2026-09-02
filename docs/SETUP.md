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
| `0018_auto_strategy_expiry_rule` | `expiry_rule` on the auto strategy — same-day expiry only (the new default), or the nearest live one |
| `0019_delta_entry_all_or_nothing` | **Bug fix.** The delta strategy stamped its daily entry as done even when nothing sold, and could half-fill the pair. Both legs now open or neither, and the day is only stamped on a filled pair |
| `0020_auto_strategy_stop_pct` | `stop_loss_pct` on the auto strategy — the stop becomes a percent of the premium collected instead of a hardcoded 2× entry |
| `0021_qty_and_take_profit` | `qty` on the delta strategy (size in XAUT, as the auto tab does it) and `take_profit_pct` on the auto strategy (the mirror of its stop) |
| `0022_delta_session_ist` | The delta session, days filter and session day move from the Sydney clock to IST, so both engines keep one clock |
| `0023_explicit_expiry` | `expiry_label` on both strategies — pick the expiry by date from the live chain instead of by rule |
| `0024_drop_pairs_and_fix_reentry` | Drops the delta strategy's `pairs` (folded into `qty`, one size control), and **fixes a session that closes and reopens the same day refusing to re-enter** |
| `0025_clear_entered_day_when_closed` | **Required with `0024`.** That fix only reached an account that still had a book to flatten; `entered_day` is now cleared on every closed cycle, and accounts already stranded are repaired |
| `0026_delta_stop_loss_mark` | `stop_loss_mark` on the delta strategy — an optional stop, off by default. **Not in the rules document**, which makes the roll budget the risk control |

The first ten create the schema; `0011` is a bug fix, `0012` moves the delta
strategy's engine server-side, `0013`–`0014` bracket what it sells, `0015` gives
the auto strategy a close to match its open, `0016`–`0018` add its entry filters,
`0019` fixes the delta strategy's daily entry, `0020`–`0021` make the auto bracket
configurable and give delta a size in XAUT, `0022` puts both engines on the IST
clock, `0023` lets each pick its expiry by date, and `0024` collapses the delta
strategy's two size controls into one, `0024`–`0025` fix its re-entry, and `0026`
adds it an optional stop.

> **The table above stops at `0026`; the directory does not.** Everything from
> `0027` on carries its own reasoning in a header comment at the top of the file
> — what it changes and why — so read the file rather than looking for a row
> here. A fresh install wants *every* migration in the directory, in numerical
> order, not just the twenty-six listed.
>
> Two later ones are worth knowing by name:
>
> - [`0038_futures`](../supabase/migrations/0038_futures.sql) adds the `futures`
>   account kind, the perpetual and its funding cron — the fourth book.
> - [`0063_counts_are_counted_not_fetched`](../supabase/migrations/0063_counts_are_counted_not_fetched.sql)
>   adds `account_counts()`. **The admin panel's position, trade and order counts
>   read zero without it** (and log to the console); nothing else in the app
>   depends on it.
> - [`0064`](../supabase/migrations/0064_the_auto_poller_asks_for_xaut.sql) and
>   [`0065`](../supabase/migrations/0065_the_auto_engine_reads_its_own_reply.sql)
>   are a pair, and `0065` supersedes `0064`'s version of
>   `queue_strategy_checks` — run both, in order. Together they scope the auto
>   strategy's poller to XAUT and make its engine read replies by request id
>   rather than by guessing which of the shared `net._http_response` rows is its
>   own. `0065` ends in a `do` block that resolves every name at apply time, so
>   a mismatch raises there rather than hours later mid-cycle.
> - [`0066`](../supabase/migrations/0066_the_newest_window_governs.sql) does two
>   things to `delta_session_window`: the most recently started window governs
>   when two of them touch, and a window carrying no id is named by its position
>   instead of the shared `win_1` every id-less window used to collide on. Only
>   affects futures books running multiple windows — but the *Add window* button
>   creates adjacent windows by default, so that is most of them. Its `do` block
>   proves both rules by calling the function, not by reading its source.

> `0021` adds `delta_strategy_settings.qty`, defaulting to one lot so nothing
> changes on its own. **Raising it means rescaling `band_low`/`band_high` by the
> same factor** — Δp counts lots, so a bigger size breaches the old band
> permanently.

> `0022` does not change the stored session times, so their *meaning* changes:
> `06:00–22:00` was 01:30–17:30 IST under AEST and is now 06:00–22:00 IST.
> **Check the session against what you actually want after running it.** It also
> re-keys `session_day`, `entered_day` and `flattened_day` onto the IST day, which
> is what stops the switch reading as a new session and selling a second pair.

> `0023` stores a chosen expiry as a date, and **a date does not roll**. Once it
> settles, that strategy stops trading until a new one is picked — deliberately,
> rather than falling through to a contract nobody chose. Leaving `expiry_label`
> null keeps the old rule (`expiry_rule` / `expiry_pick`).

> `0024` folds `pairs` into `qty` before dropping it, so no account's size changes
> — an account on `qty 0.01, pairs 3` becomes `qty 0.03`.

> `0018` changes behaviour on an existing account: `expiry_rule` defaults to
> `today`, so an armed auto account stops trading on a day XAUT lists no same-day
> expiry, and after 21:30 IST. Set it to `nearest` for the previous behaviour.

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
