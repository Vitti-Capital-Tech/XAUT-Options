# XAUT Options — Paper Trading Terminal

A Delta-Exchange-style options terminal for **XAUT** (Tether Gold). Live option
chain, click-to-trade, positions, open orders and trade history — plus two
automated strategies that run on a schedule — with every order simulated.
**No order ever reaches the exchange.**

Three pages, each trading its own book:

| Page | Account kind | What it does |
| --- | --- | --- |
| **Option Chain** | `manual` | Click-to-trade the live chain by hand |
| **Auto Strategy** | `auto` | Sells one option per closed 1h candle — a call on a red bar, a put on a green |
| **Delta Strategy** | `delta` | The delta-band strategy from `Gold_Options_Delta_Strategy.docx` |

The three never share a balance or a position: an account carries a `kind`, and
every order, fill and position is already scoped to an account.

Market data is live from Delta Exchange India's *public* API. There is no API
key anywhere in this project and no signed endpoint is ever called, so the app
is structurally incapable of placing a real trade.

## Documentation

| Document | Contents |
| --- | --- |
| [docs/HLD.md](docs/HLD.md) | High-level design — system context, architecture, data flow, trust boundaries, technology decisions |
| [docs/LLD.md](docs/LLD.md) | Low-level design — schema ERD, sequence diagrams, order state machine, netting algorithm, module contracts |
| [docs/SETUP.md](docs/SETUP.md) | Supabase provisioning, environment variables, running locally |

---

## How it works

### Option chain

Calls on the left, puts on the right, strikes down the middle, ATM marked with
the live spot. In-the-money rows are tinted. Bid/ask update over WebSocket
(`v2/ticker`), throttled to 4 repaints/second so ticks don't thrash the DOM.

Click semantics match Delta's terminal:

| Click | Action |
| --- | --- |
| A **bid** | Sell into it — ticket opens on the sell side, price prefilled |
| An **ask** | Buy from it — ticket opens on the buy side, price prefilled |
| A position row | Ticket opens for that contract |

Only the visible expiry is subscribed, plus any symbol you hold or have a
resting order on — so P&L and limit fills keep working while you browse other
expiries.

### Order ticket

Market or limit, quantity in lots with 1/10/100/1000 presets and a **Close**
button that prefills the flattening trade. Before you submit it shows the
estimated fill, premium, notional, fee, margin required and available balance,
and blocks the order when margin is short, quantity is fractional, a limit price
is off-tick, or the relevant side of the book is empty.

### P&L, marked on bid/ask

Positions are valued at **the price you would actually exit at**:

- **Long** → marked at **best bid** (you exit by selling into the bid)
- **Short** → marked at **best ask** (you exit by buying the ask)

This is deliberately pessimistic and matches a real book: buy the ask, and your
position immediately shows the spread as an unrealized loss. If the exit side of
the book is empty, P&L reads `—` rather than silently reporting zero.

Money maths, all USD, with `contract_value = 0.001 XAUT` per lot:

```
premium  = price * 0.001 * lots
notional = spot  * 0.001 * lots
```

So one lot of a 4040 call quoted at 24.90 costs $0.0249 and carries $4.03 of
underlying exposure. The small per-lot value is genuinely how Delta sizes XAUT
options — it's why quoted book sizes run to five figures.

Account lines:

```
Balance    = starting balance + realized P&L - fees   (open positions excluded)
Equity     = Balance + unrealized P&L
Available  = Equity - margin blocked
```

### Fees

Taken from the product itself rather than hardcoded: a rate on underlying
notional (0.01%), capped at a percentage of premium (3.5%) — the cap binds on
cheap far-out strikes, the notional leg binds otherwise.

### Order fills

- **Market orders** fill immediately on placement — buys at best ask, sells at best bid.
- **Limit orders** rest in *Open Orders* and fill when the book crosses them.
  A buy limit at 30 against a 24.90 offer fills at **24.90**, the better price,
  as a real book would give you.

Position netting: adding to a position blends the entry price; reducing it
realizes P&L on the closed lots and leaves the survivors' basis alone; selling
through zero realizes the closed lots and re-opens the remainder at the fill
price. This runs inside `execute_fill` as a single transaction with the order
row locked, so a fill can't half-apply and two tabs can't fill one order twice.

> **Limit orders only fill while the dashboard is open.** The fill engine runs
> in the browser, driven by the same WebSocket feed that paints the chain. To
> fill with the tab closed you'd need a Supabase Edge Function on a cron —
> a deliberate deferral, not an oversight.

### Auto Strategy

One fixed rule, no discretion: read the last **closed 1h candle** of the spot
index and sell an option — a red bar sells a call, a green bar sells a put — at
the chosen moneyness off the nearest expiry, inside a time-of-day window (IST),
with a stop at twice the entry premium on the mark.

The controls are only *whether* it runs, the strike, the size and the window.
The engine itself is `apply_strategy()` on `pg_cron`
([`0008`](supabase/migrations/0008_strategy_engine.sql)), so it trades with the
tab closed. It acts at most once per bar, guarded by `last_acted`.

> It can only ever act in the **first few minutes of an hour** — the poll gates
> itself to that window, and the reply it reads expires after 150 seconds. Miss
> it (a flat bar, an unquoted strike, a slow fetch) and the bar is consumed until
> the next hour. Every skip path logs its reason.

### Delta Strategy

The sell-only delta-band strategy specified in
`Gold_Options_Delta_Strategy.docx`. In short: sell a symmetric call/put pair at
the session open, keep net portfolio delta **Δp** inside a band by rolling
in-the-money shorts further out, fall back to fresh out-of-the-money sells when
nothing is left to roll, and flatten at the close.

**No leg is ever bought as a hedge.** Every correction is more premium sold, or
an exit — never a long option.

| Phase | Rule |
| --- | --- |
| Open (06:00 Sydney) | Sell N symmetric pairs at the strikes nearest `entry_premium` |
| Intraday | Rebuild the ITM queue each cycle, most-ITM first; resolve breaches by partial exit-and-replace |
| Roll budget | Each side gets `max_rolls`; once spent that side is **exit-only** — further triggers close in full, loss booked |
| No ITM legs left | Band-correct with fresh OTM sells in the `band_correction_delta` range |
| Close (22:00 Sydney) | Flatten everything, stand flat overnight, reset counters |

Every short it opens carries a **take-profit and no stop**, watched on the
option's own mark:

```
take_profit = take_profit_mark
```

The level is a price, not a multiple of the premium sold: at the default **0.7**
any short leg is bought back when its mark reaches **$0.70**, whatever it sold
for. Adding to a position leaves the level where it is, and `0` disables it. There is deliberately no stop-loss — the roll budget and
exit-only mode are the strategy's risk control, not a per-leg stop.

Sizing is the document's, both rounded **down** so a correction cannot overshoot:

```
roll:            q = (target_landing - Δp) / (d_itm - d_replacement)
band correction: q = (target_landing - Δp) / d_selected
```

**Δp is measured in contract-deltas** — `Σ(signed lots × option delta)`, with no
contract-value factor. That is the unit the document's own worked example is
written in, and the band is calibrated to the same one.

The engine is `apply_delta_strategy()` on `pg_cron`
([`0012`](supabase/migrations/0012_delta_strategy_engine.sql)), so this also
trades with the tab closed. It runs entirely in SQL because `/v2/tickers`
carries `greeks.delta`, both sides of the touch, spot and contract value on
every symbol — and accepts `underlying_asset_symbols=XAUT`, which cuts the fetch
from ~964 KB to ~143 KB.

Every default on the control bar is the document's own figure. The **nine items
the document leaves OPEN** have no value in it, so they are controls with
defaults chosen here, not derived: `target_landing`, what counts as a roll, `N`,
the strike tie-break, expiry selection and the cycle frequency.

> **`N` defaults to 1, which is effectively inert.** One pair nets to roughly
> zero delta and will never reach a ±1 band, so it sells its pair and holds it
> until the close — no rolls, no corrections. The document's worked example sits
> at Δp −1.5, which implies `N` nearer 3. Set it before expecting the rest of the
> strategy to fire.

### Multiple accounts

The switcher (top right) holds any number of independent paper accounts, each
with its own starting balance, positions, orders and history. The selected
account is remembered across reloads.

### Admin panel

Three ways in: type **`trade`** anywhere in the terminal, pick **Manage
accounts** in the switcher, or type **`trade`** as the **password** on the login
screen to skip the email box entirely — that last one needs `VITE_ADMIN_EMAIL`
and `VITE_ADMIN_PASSWORD` set, and works on the dev server only.

The panel lists every paper account with its
starting balance, current balance, realized P&L, and open position, order and
trade counts, and lets you:

| Action | Effect |
| --- | --- |
| Create | New account with a name and starting balance |
| Use | Make it the active account |
| Edit | Rename, or rebase the starting balance keeping realized P&L |
| Reset | Restore the starting balance, clear positions/orders/history |
| Archive / Restore | Hide from the switcher without losing history |
| Delete | Remove the account and all its records — no undo, so it confirms twice |

The keyword is configurable via `VITE_ADMIN_KEYWORD`. It is a convenience
shortcut, not a security boundary: the check runs in browser code, and the panel
only ever touches your own accounts. Auth and row-level security do the
protecting.

---

## Known approximations

- **Short-option margin** is `im% x spot + premium` per lot, where `im%` is the
  contract's own published `initial_margin` (1% for an XAUT option) rather than a
  rate of ours. Still approximate in two ways: Delta raises the rate with order
  size via `initial_margin_scaling_factor`, which isn't modelled, and accounts on
  portfolio rather than isolated margin are floored at
  `max(5% x premium, OM% x notional)`, which can bind higher. Long options are
  exact — risk is capped at the premium paid.
- **No liquidation.** Nothing force-closes a losing position.
- **Expiry settles server-side** via `pg_cron`; see
  [`supabase/migrations/0002_settlement.sql`](supabase/migrations/0002_settlement.sql).
- **Fills are all-or-nothing** and ignore quoted size, so a market order for
  more lots than are actually offered still fills at the touch. Respecting
  `bid_size`/`ask_size` and walking the book would be the realistic upgrade.
- **Fees assume the taker rate.** A resting limit order that fills is really a
  maker fill; both rates are 0.01% for XAUT today, so this currently makes no
  numerical difference.
- **Strategy fills are modelled without fees.** Both engines pass `0` to
  `execute_fill`, so an automated book overstates its P&L by roughly the
  commission a manual one would pay.
- **Both engines are paced by `pg_cron` at one minute.** The delta strategy's
  `cycle_seconds` therefore floors at 60 in practice however low it is set, and
  a correction is sized against a snapshot up to a minute old.

## Project layout

```
src/
  lib/delta.ts             Delta REST + WebSocket client, symbol parsing
  lib/marketStore.ts       Throttled live ticker cache (useSyncExternalStore)
  lib/supabase.ts          Supabase client
  lib/format.ts            Number/money/greek formatting
  lib/strategy.ts          Auto strategy: candle colour, moneyness, IST window
  lib/deltaStrategy.ts     Delta strategy: Δp, band, ITM queue, sizing, cycle plan
  engine/paper.ts          Fees, margin, bid/ask P&L, order validation, crossing
  hooks/useAuth.ts         Session
  hooks/useAccounts.ts     Paper accounts CRUD + selection, per kind
  hooks/useTrading.ts      Positions/orders/fills, order placement, fill engine
  hooks/useAutoStrategy.ts Auto strategy settings (engine is server-side)
  hooks/useDeltaStrategy.ts Delta strategy settings + readout (engine is server-side)
  components/controls.tsx  Shared strategy-bar widgets: select, time picker, switch
  components/              Login, TopBar, OptionChain, OrderTicket, BottomPanel,
                           StrategyTab, DeltaStrategyTab, AdminPanel
supabase/migrations/       Schema, RLS, execute_fill, settlement, TP/SL,
                           and both strategy engines
docs/                      HLD, LLD, setup
```

`lib/deltaStrategy.ts` holds the strategy's logic with no React and no I/O, so
the band maths and the sizing can be reasoned about on their own. It is also
what the browser uses to render the live readout — the executing copy is the SQL
in `0012`, and the two must be kept in step by hand.

## Verification status

Confirmed working:

- Pricing, fees, margin, bid/ask P&L, order validation and position netting in
  `engine/paper.ts` — 30 assertions against a real Delta ticker payload,
  including the netting rules `execute_fill` implements in SQL.
- Delta REST and WebSocket contracts, live against `api.india.delta.exchange`.
- Click-to-trade end to end in the browser: buying an ATM call at the ask
  produced the expected premium, notional, fee, margin, position mark at the
  bid, and the equity/available lines.
- Schema deployed: all four tables present, RLS rejects anonymous writes
  (`42501`), and both functions exist and execute.
- **Delta strategy logic** in `lib/deltaStrategy.ts` — 65 assertions covering the
  document's 5.2 worked example end to end, the band and landing rules, the
  corrective sides, the ITM queue, and the Sydney session clock across both AEST
  and AEDT. Fixtures are synthetic.
- **Delta strategy daily entry, live.** Armed against the real chain it built the
  113-symbol snapshot from the feed and sold its symmetric pair — two orders, two
  open legs, `entered_day` set.

Not yet exercised:

- **The delta strategy past its daily entry.** The roll, exit-only and
  band-correction paths have run against synthetic fixtures only, never against
  a live book — partly because `N = 1` cannot breach the band (see above). These
  are the paths that place and unwind real size; treat the first live breach as
  the actual test.
- **The two copies of the delta logic can drift.** `lib/deltaStrategy.ts` draws
  the readout and `0012` does the trading. They implement the same rules twice,
  in two languages, with only the TypeScript side under test.
- **The write path inside `execute_fill`** — the `insert into fills` and the
  positions upsert. Postgres only plans statements inside a PL/pgSQL function on
  first execution, so these are validated by the first real trade rather than by
  deployment. If anything in the schema misbehaves, look here first.
- Liquidation and partial fills against quoted size — neither is implemented
  (see *Known approximations*).

## License

Proprietary — Copyright (c) 2026 Vitti Capital, all rights reserved. See
[LICENSE](LICENSE). This project simulates trading only and is not financial advice.
