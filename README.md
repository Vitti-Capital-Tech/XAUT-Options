# XAUT Options — Paper Trading Terminal

A Delta-Exchange-style options terminal for **XAUT** (Tether Gold). Live option
chain, click-to-trade, positions, open orders and trade history — with every
order simulated. **No order ever reaches the exchange.**

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

### Multiple accounts

The switcher (top right) holds any number of independent paper accounts, each
with its own starting balance, positions, orders and history. Per account you
can **reset** (restore starting balance, wipe history) or **archive** (hide but
keep history). The selected account is remembered across reloads.

---

## Known approximations

- **Short-option margin is approximated** as `10% x spot + premium` per lot.
  Delta's real short-option margin is a risk model that also accounts for
  moneyness and isn't exposed on the public API. The constant is
  `SHORT_IM_RATE` in [`src/engine/paper.ts`](src/engine/paper.ts). Long options
  are exact — risk is capped at the premium paid.
- **No liquidation, no auto-settlement at expiry.** Positions in an expired
  contract stay open in the UI; close them manually. Adding settlement means
  reading the settlement price after expiry and realizing intrinsic value.
- **Fills are all-or-nothing** and ignore quoted size, so a market order for
  more lots than are actually offered still fills at the touch. Respecting
  `bid_size`/`ask_size` and walking the book would be the realistic upgrade.
- **Fees assume the taker rate.** A resting limit order that fills is really a
  maker fill; both rates are 0.01% for XAUT today, so this currently makes no
  numerical difference.

## Project layout

```
src/
  lib/delta.ts          Delta REST + WebSocket client, symbol parsing
  lib/marketStore.ts    Throttled live ticker cache (useSyncExternalStore)
  lib/supabase.ts       Supabase client
  lib/format.ts         Number/money/greek formatting
  engine/paper.ts       Fees, margin, bid/ask P&L, order validation, crossing
  hooks/useAuth.ts      Session
  hooks/useAccounts.ts  Paper accounts CRUD + selection
  hooks/useTrading.ts   Positions/orders/fills, order placement, fill engine
  components/           Login, TopBar, OptionChain, OrderTicket, BottomPanel
supabase/migrations/    Schema, RLS, execute_fill, reset_account
docs/                   HLD, LLD, setup
```

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

Not yet exercised:

- **The write path inside `execute_fill`** — the `insert into fills` and the
  positions upsert. Postgres only plans statements inside a PL/pgSQL function on
  first execution, so these are validated by the first real trade rather than by
  deployment. If anything in the schema misbehaves, look here first.
- Expiry settlement, liquidation, and partial fills against quoted size — none
  are implemented (see *Known approximations*).

## License

Proprietary — Copyright (c) 2026 Vitti Capital, all rights reserved. See
[LICENSE](LICENSE). This project simulates trading only and is not financial advice.
