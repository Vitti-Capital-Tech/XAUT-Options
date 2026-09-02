# Low-Level Design

**XAUT Options — Paper Trading Terminal**

Implementation-level reference: schema, algorithms, module contracts and formulas.
For rationale and system context see [HLD.md](HLD.md).

---

## 1. Contract mechanics

Everything downstream depends on getting these units right.

| Quantity | Formula | Example (4040 call @ 24.90, spot 4038.77) |
| --- | --- | --- |
| Contract value | Product field | `0.001` XAUT per lot |
| Premium (USD) | `price × contract_value × lots` | `24.90 × 0.001 × 1000 = $24.90` |
| Notional (USD) | `spot × contract_value × lots` | `4038.77 × 0.001 × 1000 = $4,038.77` |
| Quote unit | USD per XAUT | `24.90` |
| Tick size | Product field | `0.01` |

One lot is worth about 2.5 cents of premium and carries $4 of underlying
exposure. This is genuinely how Delta sizes XAUT options — it is why quoted book
sizes run to five figures, and why the UI shows four decimal places on premium
and fee columns.

### Symbol grammar

```
C-XAUT-4040-300726
│ │    │    └── expiry, ddmmyy (30 Jul 2026, settles 16:00 UTC)
│ │    └─────── strike price
│ └──────────── underlying
└────────────── C = call, P = put
```

`parseSymbol` returns `null` on anything that does not match, and callers treat
`null` as "not our instrument" rather than throwing.

### The perpetual

`XAUTUSD` is the venue's only non-option XAUT contract and is deliberately *not*
in the grammar above: it has no strike, no expiry and four characters where the
options have four hyphen-separated fields, so `parseSymbol` returns `null` for it
and every option-shaped filter excludes it for free.

| Quantity | Formula | Example (mark 4380.82) |
| --- | --- | --- |
| Contract value | Product field | `0.001` XAUT per lot |
| Notional (USD) | `mark × contract_value × lots` | `4380.82 × 0.001 × 1000 = $4,380.82` |
| Margin | `notional / leverage`, floor `im% × notional` | at 10x: `$438.08` |
| Funding | `mark × cv × lots × rate / 100`, every `expiry_interval` | at `+0.0050%`: `$0.22` per 8h |
| Maintenance | `mm% × mark × cv × lots` | `0.5% → $21.90` |

The notional is priced off the contract's *own* mark rather than off the spot
index, unlike an option: on a linear contract the two differ only by the basis,
and it is the mark the venue margins and liquidates against.

`isPerp(contract_type)` is the single test the rest of the codebase branches on.

---

## 2. Data model

```mermaid
erDiagram
    AUTH_USERS ||--o{ ACCOUNTS : owns
    ACCOUNTS ||--o{ ORDERS : contains
    ACCOUNTS ||--o{ POSITIONS : holds
    ACCOUNTS ||--o{ FILLS : records
    ORDERS ||--o{ FILLS : produces
    ACCOUNTS ||--o| STRATEGY_SETTINGS : "if kind=auto"
    ACCOUNTS ||--o| DELTA_STRATEGY_SETTINGS : "if kind in (delta, futures)"
    ACCOUNTS ||--o{ FUNDING_PAYMENTS : "if it holds a perpetual"

    AUTH_USERS {
        uuid id PK
        text email
    }
    ACCOUNTS {
        uuid id PK
        uuid user_id FK
        text name
        text kind "manual | auto | delta | futures"
        numeric starting_balance
        numeric balance
    }
    STRATEGY_SETTINGS {
        uuid account_id PK
        boolean armed
        text moneyness "ATM | OTM_1 | OTM_2"
        numeric qty "XAUT per entry -> lots"
        numeric min_premium "bid floor; 0 = none"
        numeric max_premium "offer ceiling; 0 = none"
        text expiry_rule "today | nearest"
        text expiry_label "ddmmyy, or null"
        text window_start "HH:MM IST"
        text window_end
        smallint_array trade_days "ISO weekdays, IST"
        numeric stop_loss_pct "% of premium off entry; 0 = none"
        numeric trail_stop_pct "% of premium off the 1m close; 0 = none"
        numeric take_profit_pct "% of premium kept; 0 = none"
        bigint last_acted "unix sec of last bar"
    }
    DELTA_STRATEGY_SETTINGS {
        uuid account_id PK
        boolean armed
        text session_open "HH:MM IST"
        text session_close
        smallint_array trade_days "ISO weekdays, IST"
        numeric band_low "L; the fallback once gamma_multiplier is set"
        numeric band_high "U"
        text target_landing "edge | mid"
        numeric band_buffer "B"
        numeric gamma_multiplier "band = +/- |Gp| x this; 0 = off; ignored on a futures book"
        numeric itm_trigger "points"
        integer max_rolls "per side per session"
        numeric entry_premium
        numeric entry_premium_min "floor for opening pairs"
        numeric entry_premium_max "ceiling for opening pairs"
        integer pairs_count "opening pairs count"
        numeric shift_pct "% of ATM exit price to sell replacement"
        integer max_shifts "shift limit per side"
        numeric qty "XAUT per leg -> lots"
        numeric max_notional_per_strike "USD ceiling per contract; 0 = off"
        numeric hedge_leverage "futures books only; margin is notional / this"
        text expiry_rule "today | tomorrow | friday | nearest | fixed"
        text expiry_label "ddmmyy, or null"
        text session_day "IST YYYY-MM-DD"
        integer rolls_used_call
        integer rolls_used_put
        integer shifts_used_call "used ATM shifts today"
        integer shifts_used_put
        text entered_day
        text flattened_day
        text_array touched_symbols "once per pass"
        boolean pass_open
        numeric take_profit_mark "a price on the option's mark"
        numeric stop_loss_mark "a price on the mark; 0 = none"
        numeric margin_cap_pct "cut at this % of equity; 0 = off"
        numeric margin_target_pct "cut depth, not a gate; cap - this = hysteresis"
        jsonb schedule_windows "multi-window schedule configurations for Futures strategy"
        text_array entered_window_ids "entered window IDs today"
    }
    ORDERS {
        uuid id PK
        uuid account_id FK
        text symbol
        text side "buy | sell"
        text order_type "market | limit"
        integer qty "lots"
        numeric limit_price "null for market"
        text status "open | filled | cancelled"
        numeric avg_fill_price
        integer filled_qty
        boolean reduce_only
        numeric leverage "perpetual only; null on an option"
    }
    FILLS {
        uuid id PK
        uuid order_id FK
        text side
        integer qty
        numeric price
        numeric premium
        numeric notional
        numeric fee
        numeric realized_pnl "non-zero only when closing"
        numeric spot_at_fill
        text close_reason "take_profit | stop_loss | window_close | liquidation"
        text reason "why the delta engine closed this leg"
    }
    POSITIONS {
        uuid id PK
        uuid account_id FK
        text symbol
        integer net_qty "signed: + long, - short"
        numeric avg_entry_price
        numeric realized_pnl
        text entry_reason "why the delta engine opened this leg"
        numeric leverage "perpetual only; what margins it"
    }
    FUNDING_PAYMENTS {
        uuid id PK
        uuid account_id FK
        text symbol
        timestamptz funding_time "the 8h boundary billed"
        numeric funding_rate "percent for the period"
        numeric mark_price
        integer net_qty
        numeric amount "signed for the account"
    }
```

### Invariants

| # | Invariant | Enforced by |
| --- | --- | --- |
| 1 | One netted position per `(account_id, symbol)` | `unique (account_id, symbol)` |
| 2 | A `positions` row always means live exposure | Row deleted when `net_qty` reaches 0 |
| 3 | A limit order has a price; a market order does not | `orders_limit_price_required` check |
| 4 | `qty > 0` on orders and fills | Column checks |
| 5 | `fills` are immutable | Never updated or deleted outside `reset_account` |
| 6 | Every row belongs to `auth.uid()` | RLS `USING` + `WITH CHECK` |
| 7 | Only an `open` order can fill | `execute_fill` status guard |
| 8 | A funding boundary is billed at most once per position | `unique (account_id, symbol, funding_time)` |

> **Invariant 2 has a consequence:** closing a position deletes the row and with it
> its `realized_pnl` counter. That is intentional — realized P&L lives durably on
> `fills` and in `cash_balance`; the column is a convenience for open positions only.

### Indexes

| Index | Columns | Serves |
| --- | --- | --- |
| `accounts_user_idx` | `(user_id, created_at)` | Account switcher listing |
| `orders_account_status_idx` | `(account_id, status, created_at desc)` | Order history |
| `orders_open_idx` | `(account_id) where status = 'open'` | Partial — the fill engine only scans open orders |
| `fills_account_idx` | `(account_id, created_at desc)` | Trade history, and the fill count in `account_counts` |
| `positions_account_idx` | `(account_id)` | Positions table, P&L totals, and the position count in `account_counts` |
| `funding_account_idx` | `(account_id, funding_time desc)` | The perpetual's funding ledger |
| `trail_candle_requests_created_idx` | `(created_at)` | Trimming the pg_net request-id → symbol map the trailing stop matches its candle replies by |
| `delta_ticker_requests_requested_at_idx` | `(requested_at desc)` | Trimming the same map for the delta engine's ticker replies ([`0058`](../supabase/migrations/0058_read_our_own_reply.sql)) |

---

## 3. Order lifecycle

```mermaid
stateDiagram-v2
    [*] --> Validating: user submits
    Validating --> [*]: blocked — nothing written
    Validating --> Open: row inserted

    Open --> Filled: market order (immediate)
    Open --> Filled: limit order crossed by the book
    Open --> Cancelled: user cancels
    Open --> Cancelled: market order fill failed

    Filled --> [*]
    Cancelled --> [*]

    note right of Validating
        previewOrder: quantity whole and positive,
        tick-aligned limit, sufficient margin,
        book present on the needed side
    end note

    note right of Open
        Only limit orders rest here.
        A market order is never left open.
    end note
```

| Transition | Trigger | Writes |
| --- | --- | --- |
| → `open` | Insert succeeds | `orders` |
| `open` → `filled` (market) | Immediately after insert | `fills`, `positions`, `accounts` |
| `open` → `filled` (limit) | Book crosses the limit | same |
| `open` → `cancelled` | User action | `orders.status`, `cancel_reason` |
| `open` → `cancelled` | Market fill failed | `orders.status = 'Fill failed'` |

---

## 4. Pricing rules

### Which price applies

| Context | Long / buy | Short / sell | Empty side |
| --- | --- | --- | --- |
| Market order fill | `best_ask` | `best_bid` | Order blocked |
| Position mark | `best_bid` | `best_ask` | P&L renders `—` |
| Limit crossing test | `best_ask ≤ limit` | `best_bid ≥ limit` | Rests |
| Limit fill price | `best_ask` (the touch) | `best_bid` (the touch) | — |

Two consequences follow, both intended:

- **Crossing the spread shows up immediately.** Buy at the ask, mark at the bid, and
  the position opens down the full spread — exactly as on a real book.
- **A limit order fills at the touch, not at its limit.** A buy limit at 30 against a
  24.90 offer fills at **24.90**, the better price, as a real book would give you.

### Fees

```
option:     fee = taker_rate × spot  × cv × lots     ← 0.01% of notional
perpetual:  fee = taker_rate × price × cv × lots
```

`taker_rate` comes from the product payload (`taker_commission_rate`, default
`0.0001`) rather than a constant, so the app tracks venue changes.

| Case | Price | Charged (1000 lots, spot 4038.77, cv 0.001) |
| --- | --- | --- |
| Near the money | 24.90 | **$0.4039** |
| Deep out of the money | 0.05 | **$0.4039** |

> **The 3.5% premium cap is gone.** The rule used to be
> `min(0.01% of notional, 3.5% of premium)`, and the cap bound on cheap far-out
> strikes — the deep-OTM row above used to be charged $0.00175, not $0.4039.
> Neither `computeFee` nor `execute_fill` applies a cap now. The consequence is
> that a far-out strike costs proportionally far more to trade than it did, which
> is worth knowing before reading a strategy's P&L across builds.

**Both sides charge, and they agree.** `computeFee` prices the browser's own
fills; `execute_fill` prices everything written server-side. Before
[`0052`](../supabase/migrations/0052_futures_fees.sql) the strategy engines all
called `execute_fill(..., 0, ...)` and the zero was taken literally, so **engine
fills were free** — their realized P&L was overstated by the whole fee line.
`execute_fill` now falls back to `0.0001 × notional` when the caller passes
nothing, and debits `cash_balance` by realized P&L *minus* fees.

### Margin

| Position | Margin blocked | Exact? |
| --- | --- | --- |
| Long option | `avg_entry × cv × lots` — the premium paid | Yes; loss is capped at premium |
| Short option | `(im% × spot + mark) × cv × lots` | Rate is the venue's; scaling is not |
| Perpetual, either side | `mark × cv × lots / leverage`, floored at `im% × notional` | Rate is the venue's; scaling is not |

Direction does not enter into the perpetual row, and that is the whole difference
from the option rows above it: a long option has already paid its maximum loss in
premium and the venue asks for nothing more, whereas a long future can lose
without limit exactly as a short one can. `perpMargin` is where that lives.

`im%` is the contract's own `initial_margin`, read off the product by
`shortImRate` in [`src/engine/paper.ts`](../src/engine/paper.ts) — 1% for an XAUT
option. The field is a percentage, which `BTCUSD` settles: it publishes `0.5`
against a default leverage of 200, and 200x is 0.5% margin.

This used to be a hardcoded 10%, on the stated grounds that Delta did not publish
the number. They do. Two things are still approximate: Delta raises the rate with
order size via `initial_margin_scaling_factor`, which is not modelled, so a large
short margins slightly cheaper here; and accounts on portfolio margin instead of
isolated margin are floored at `max(5% × premium, OM% × notional)`, which for a
naked short can bind well above this figure.

`FALLBACK_SHORT_IM_RATE` applies only where the product is not loaded at all, as
with a contract that has already expired.

Only the portion of an order that *increases* exposure requires new margin:

```mermaid
graph LR
    A["order: signed lots"] --> B{"existing<br/>net_qty"}
    B -->|"flat or same sign"| C["opening = full qty"]
    B -->|"opposite sign"| D["closing = min(abs net, qty)<br/>opening = qty − closing"]
    C --> E["margin = f(opening) + fee"]
    D --> E
    E --> F{"margin ≤<br/>available?"}
    F -->|no| G["block order"]
    F -->|yes| H["allow"]
```

### Account arithmetic

| Line | Formula |
| --- | --- |
| Balance | `starting_balance + Σ realized − Σ fees` |
| Unrealized | `Σ` over positions of exit-marked P&L |
| Equity | `Balance + Unrealized` |
| Margin blocked | `Σ` per-position margin |
| Available | `Equity − Margin blocked` |

Open positions are deliberately excluded from Balance — premium is not debited on
entry. This keeps realized and unrealized strictly separable and matches Delta's
own presentation.

**Worked example** — buy 1000 lots of the 4040 call at ask 28.50, bid 27.30, from $10,000:

| Line | Value | Derivation |
| --- | --- | --- |
| Premium | $28.50 | `28.50 × 0.001 × 1000` |
| Fee | $0.4039 | notional leg binds |
| Balance | $9,999.60 | `10000 − 0.4039` |
| Mark | 27.30 | best bid — the exit price |
| Unrealized | −$1.20 | `(27.30 − 28.50) × 1000 × 0.001` |
| Equity | $9,998.40 | `9999.60 − 1.20` |
| Margin | $28.50 | premium paid |
| Available | $9,969.90 | `9998.40 − 28.50` |

The −$1.20 is precisely the 1.20 spread. Values above were confirmed in the running app.

---

## 5. Position netting

Implemented in `execute_fill`; mirrored in JS in the test suite so the rules are
verifiable without a database.

```mermaid
flowchart TD
    A["fill: side, qty, price"] --> B["signed = buy ? +qty : −qty"]
    B --> C{"position<br/>exists?"}
    C -->|no| D["net = signed<br/>avg = price<br/>realized = 0"]
    C -->|yes| E{"same<br/>direction?"}
    E -->|yes| F["net += signed<br/>avg = weighted mean<br/>realized = 0"]
    E -->|no| G["closeQty = min(abs net, qty)<br/>realize on closeQty"]
    G --> H{"resulting<br/>net"}
    H -->|"= 0"| I["delete position row"]
    H -->|"sign flipped"| J["avg = price<br/>remainder re-opens"]
    H -->|"same sign"| K["avg unchanged<br/>survivors keep basis"]

    classDef r fill:#064e3b,stroke:#10b981,color:#d1fae5
    class G,I,J,K r
```

### Rules

| Case | `net_qty` | `avg_entry_price` | Realized |
| --- | --- | --- | --- |
| Open new | `signed` | `price` | 0 |
| Add same direction | `net + signed` | `(abs(net)·avg + qty·price) / (abs(net) + qty)` | 0 |
| Partial reduce | `net + signed` | **unchanged** | on `closeQty` |
| Full close | 0 → row deleted | — | on all lots |
| Flip through zero | `net + signed` | `price` | on `closeQty` only |

Realized P&L on the closed lots:

```
long  closed by selling:  (price − avg_entry) × closeQty × cv
short closed by buying:   (avg_entry − price) × closeQty × cv
```

### Worked cases

| Sequence | Result | Realized |
| --- | --- | --- |
| Buy 1000 @ 20, buy 1000 @ 30 | `+2000 @ 25` | 0 |
| Buy 1000 @ 20, sell 400 @ 30 | `+600 @ 20` | `+$4.00` |
| Buy 1000 @ 20, sell 1000 @ 25 | flat | `+$5.00` |
| Sell 1000 @ 30, buy 1000 @ 22 | flat | `+$8.00` |
| Buy 1000 @ 20, **sell 1500 @ 26** | `−500 @ 26` | `+$6.00` (1000 lots only) |
| Buy 250 each @ 10/20/30/40, sell 1000 @ 35 | flat | `+$10.00` |

The flip case is the one worth internalising: only the 1000 closed lots realize;
the 500-lot short opens fresh at 26.

---

## 6. Transactional fill

```mermaid
sequenceDiagram
    autonumber
    participant C as Client
    participant F as execute_fill
    participant O as orders
    participant P as positions
    participant FI as fills
    participant A as accounts

    C->>F: rpc(order_id, qty, price, fee, spot)
    F->>O: SELECT … FOR UPDATE
    Note over F,O: Row lock — concurrent tabs serialise here
    alt not found / not open / partial qty
        F-->>C: raise exception (transaction rolls back)
    else valid
        F->>P: SELECT … FOR UPDATE
        F->>F: compute net_qty, avg_entry, realized
        F->>FI: INSERT fill
        F->>O: UPDATE status = 'filled'
        alt net_qty = 0
            F->>P: DELETE position
        else
            F->>P: INSERT … ON CONFLICT DO UPDATE
        end
        F->>A: cash_balance += realized − fee
        F-->>C: fill row
    end
```

Guards, in order:

| Check | Failure |
| --- | --- |
| Order exists | `order % not found` |
| Status is `open` | `order % is %, not open` |
| `qty = qty − filled_qty` | `partial fills are not supported` |

All four writes plus the balance update occur in one transaction. Any raise rolls
back everything, so a fill without a position — or a balance moved without a
fill — cannot occur.

> **Implementation notes.** The existing row in `ON CONFLICT DO UPDATE` is referenced
> as `positions.realized_pnl`, unqualified by schema — `public.positions.…` is not
> valid there. Direction is compared with explicit boolean tests rather than
> `sign()`, since `sign()` on an integer relies on overload resolution not worth
> depending on. Both functions are `SECURITY INVOKER`, so RLS still scopes every
> row they touch.

---

## 7. Market data layer

### Ticker cache

`marketStore` decouples tick arrival from rendering.

| Aspect | Implementation | Reason |
| --- | --- | --- |
| Storage | `Map<symbol, Ticker>` | O(1) lookup per row |
| Writes | Synchronous, set a dirty flag | Never drop a tick |
| Notification | `setInterval` 250 ms, only if dirty | Cap repaints at 4/sec |
| React binding | `useSyncExternalStore` over a version counter | Stable snapshot; no per-tick allocation |
| Merge | `{ ...prev, ...next }` | WS payloads may omit fields |
| Timer lifecycle | Started on first subscriber, cleared on last | No idle timer |

Components subscribe with `useMarketTick()` for invalidation, then read
`market.get(symbol)` during render. Unconventional, but it means a tick allocates
nothing and re-renders only subscribers.

### WebSocket lifecycle

```mermaid
stateDiagram-v2
    [*] --> Connecting: connect()
    Connecting --> Live: onopen → enable_heartbeat + subscribe
    Connecting --> Reconnecting: onerror / onclose
    Live --> Reconnecting: onclose
    Live --> Reconnecting: watchdog — 45 s silence
    Reconnecting --> Connecting: backoff min(15 s, 2^n s)
    Live --> [*]: close()
    Reconnecting --> [*]: close()
```

| Concern | Handling |
| --- | --- |
| Dead-but-open socket | Heartbeat enabled; 45 s of silence forces a close |
| Reconnect storms | Exponential backoff, capped at 15 s, reset on success |
| Expiry switch | Diff old/new symbol sets; unsubscribe removed, subscribe added |
| Off-screen positions | Held and resting symbols pinned into the subscription |
| Stale socket callbacks | Handlers check `this.ws === ws` before acting |

Subscribed set = visible expiry ∪ held symbols ∪ resting-order symbols. Roughly 40
symbols instead of 150, without breaking P&L on other expiries.

### Server-side polling: correlate, do not describe

The engines do not use the WebSocket. Each pairs a `queue_*` job that fires a
`pg_net` request with an `apply_*` job that reads the reply a moment later, and
**every one of them writes into the same `net._http_response` table**. There are
eight callers.

So an engine has to answer "which of these rows is mine?", and there are only two
ways to do it:

| | How | Holds up? |
| --- | --- | --- |
| Describe the reply | Filter on status, age and body shape | No |
| Correlate the request | Keep the id `net.http_get` returns, join on `_http_response.id` | Yes |

All three engines correlate now:

| Engine | Correlation table | Since |
| --- | --- | --- |
| Trailing stops | `trail_candle_requests` (request id → symbol) | [`0037`](../supabase/migrations/0037_auto_trailing_stop.sql) |
| Delta / futures | `delta_ticker_requests` | [`0058`](../supabase/migrations/0058_read_our_own_reply.sql) |
| Auto strategy | `strategy_requests` (request id → `candle` \| `tickers`) | [`0065`](../supabase/migrations/0065_the_auto_engine_reads_its_own_reply.sql) |

The delta engine described instead, and it cost a book: see
[Bitcoin spot, and why "describe the reply" cannot work](#bitcoin-spot-and-why-describe-the-reply-cannot-work).

The auto engine was the last one describing, and its test was
`(result -> 0) ? 'symbol'` — true of *every* ticker reply in the database. With a
delta account armed, `queue_delta_checks` fires one every five seconds, so in any
150-second window there were dozens of candidates and the auto engine took
whichever landed last. It had been reading the delta poller's reply more often
than its own. That never became an incident only because
[`0064`](../supabase/migrations/0064_the_auto_poller_asks_for_xaut.sql) made both
pollers ask the same question, so the wrong body happened to hold the right data
— luck about content, not correctness.

`strategy_requests` tags each id `candle` or `tickers`, so **both** of that
poller's replies are correlated rather than only the ticker one. The candle
picker had the same weakness in a quieter form: it excluded the trailing-stop
candle fetches with `not exists (select 1 from trail_candle_requests …)`, an
exclusion list somebody has to remember to extend every time a new poller fetches
bars. An id match needs no list.

**Rule for any new poller: keep the request id.** A description that is accurate
today is only accurate until somebody adds a ninth caller.

### The chain table

`delta_chain` is the server's own quote cache — unlogged, keyed by symbol, and
the only market data the SQL engines read. It carries `best_bid`, `best_ask`,
`mark_price`, `spot_price`, `delta`, `gamma`, `contract_value`, `product_id` and,
since [`0056`](../supabase/migrations/0056_delta_gate_stops_blocking_the_hedge.sql),
`updated_at`.

Two properties matter more than they look:

- **It is XAUT-only, and enforced as such.** Both upserts filter on
  `C-XAUT-%` / `P-XAUT-%` / `XAUTUSD`
  ([`0057`](../supabase/migrations/0057_chain_is_xaut_only.sql)). Spot is derived
  from those symbols only and cross-checked against the XAUTUSD mark; more than
  20% apart and the cycle stands down rather than trading on it.
- **It is refreshed by upsert, not by `delete` + `insert`.** That was a
  performance change in [`0050`](../supabase/migrations/0050_futures_min_days_to_expiry.sql),
  and it also removed the property that a bad ingest lasted exactly one cycle.
  A row that gets in now stays until something takes it out. The filters above
  are what replaced that safety.

---

## 8. Module contracts

### `engine/paper.ts` — pure, no I/O

| Function | Signature | Notes |
| --- | --- | --- |
| `marketFillPrice` | `(ticker, side) → number \| null` | `null` = that side is empty |
| `exitPrice` | `(ticker, netQty) → number \| null` | Bid for longs, ask for shorts |
| `computeFee` | `(product, price, qty, spot) → number` | 0.01% of notional (0.0001 * notional) |
| `valuePosition` | `(pos, ticker, spot) → PositionValue` | P&L at the exit price, margin at the mark |
| `summarizeAccount` | `(cash, positions, tickerFor, spot) → AccountSummary` | Balance/equity/available |
| `previewOrder` | `(intent, ticker, spot, existing, available) → OrderPreview` | `error` blocks; `warning` informs |
| `crossesNow` | `(side, limitPrice, ticker) → number \| null` | Fill price at the touch, or `null` |
| `perpMargin` | `(price, cv, lots, imRate, leverage) → number` | Notional over leverage, floored at the rate |
| `maintenanceRate` | `(product) → number` | `maintenance_margin` as a fraction |
| `maxLeverage` | `(product) → number` | The lesser of the published figure and `1 / imRate` |
| `liquidationPrice` | `(netQty, avgEntry, cv, cash, mmRate) → number \| null` | `null` where no mark can liquidate |
| `fundingPayment` | `(mark, cv, netQty, ratePct) → number` | Signed for the account; negative is paid away |

`null` consistently means "unknown", never zero. This is what makes an empty book
render `—` rather than a plausible-looking wrong number.

### `hooks/useTrading.ts`

| Export | Purpose |
| --- | --- |
| `positions`, `openOrders` | Current account state; always kept live |
| `fills` | The loaded history window. Empty until `setHistoryVisible(true)` |
| `fillCount` | The account's total fills, from a `HEAD` count — no rows on the wire |
| `fillsTruncated` | The window hit `FILL_LIMIT`, so its oldest day group may be short |
| `setHistoryVisible` | Told by `BottomPanel` which tab is showing; gates every fill read |
| `placeOrder` | Validate → insert → fill if crossing → refetch |
| `cancelOrder` | Guarded by `.eq('status','open')` |
| `closePosition` | Opposing market order, `reduce_only` |
| `registerProducts` | Supplies product metadata to the fill engine |
| `reload` | Positions, orders and the fill count. History only if its tab is open |

Concurrency guard: an `inFlight` ref of order ids stops a tick burst from
double-submitting. The DB row lock and status check are the real defence.

#### Refresh model

Four instances of this hook are mounted at once — one per account kind — and
only one page is on screen, so what each instance fetches is load-bearing for
egress rather than for correctness.

| Source | Cadence | Reads |
| --- | --- | --- |
| Realtime `positions` | On change, debounced 150 ms | Positions; notifies the account summary |
| Realtime `orders` | On change, debounced 150 ms | Orders |
| Realtime `fills` | On change, debounced 150 ms | Fill count; rows only if the history tab is open |
| `useVisiblePoll` | 15 s, visible tabs only | Positions, orders, fill count |
| `setHistoryVisible(true)` | Tab opened | The newest `FILL_LIMIT` rows, once |

Three properties hold this together:

**Fills are display-only.** Nothing in `engine/paper.ts`, either strategy, or the
account summary reads a fill row — balances come off `accounts.cash_balance`,
which `execute_fill` maintains. So deferring the 1000-row window until its tab is
opened cannot make any other number wrong.

**Incremental catch-up uses `gte`, not `gt`.** A strategy cycle writes its legs
in one transaction, so sibling fills share `now()` to the microsecond; a strict
comparison against the newest held row would drop every sibling but the first.
The boundary rows are re-read and dropped by id, which is the check that actually
keeps the list unique. `setFills` returns the previous array unchanged when
nothing is fresh, so a quiet account does not re-render the table.

**The poll is a fallback, never a driver.** The browser fill engine is driven by
`marketStore` ticks and both strategy engines run on `pg_cron`, so a hidden tab
loses nothing by not polling. `useVisiblePoll` reconciles once on return before
resuming the interval.

### `lib/delta.ts` — REST bootstrap

| Helper | Endpoint | Scope |
| --- | --- | --- |
| `fetchExpiries` | `/v2/products?contract_types=call_options,put_options&states=live&page_size=1000&underlying_asset_symbols=XAUT` | 159 products, 8.3 KB |
| `fetchTickers` | `/v2/tickers?contract_types=call_options,put_options&underlying_asset_symbols=XAUT` | 159 tickers, 32 KB |
| `fetchPerp` / `fetchPerpTicker` | `/v2/products/XAUTUSD`, `/v2/tickers/XAUTUSD` | One instrument each |
| `fetchCandles` | `/v2/history/candles` | One symbol, one range |

Both list calls are refreshed every 60 seconds, because Delta lists new strikes
and rolls expiries through the day and the WebSocket only streams symbols already
in the list. Unfiltered they were 1079 rows and 277 KB per refresh, of which 159
rows were XAUT — the venue-side filter is a 7× cut on both.

`getList` also compares the returned array against `meta.total_count` and warns
when the page is short. That is not defensive habit; it is a bug this code had.
`page_size=1000` against 1079 live options returned a silent prefix, and the 79
dropped were the most recently listed — the newly opened strikes a chain most
needs to show. Nothing surfaced it because a chain missing a strike is
indistinguishable from a chain whose venue has not listed one. With the
underlying filter the total is 159 and the warning should never fire; it is there
because the failure has no other symptom.

The client-side `parseSymbol(...).underlying` filter is kept behind the venue's,
where it now doubles as the symbol-shape check that turns a surprising row into a
skipped row rather than a crash on the non-null assertion below it.

### `hooks/useAccounts.ts`

Four instances are mounted at once, one per account `kind`, and all four
subscribe to the same `accounts` change stream — `user_id` is the only filter
Postgres can express there, and it is the same for all of them. So every
instance is told about every account the user owns.

Each handler now reads `kind` off the payload and returns early when the row
belongs to a book it does not manage, so a balance change costs one refetch
rather than four. A delete carries only the primary key under the default
replica identity, so `kind` is absent and the refetch goes ahead — the safe way
round, and rare enough not to matter. The handler is debounced 150 ms, because a
single cycle's fill, position and order writes can all land within a few
milliseconds of the balance update they accompany.

### `hooks/usePolling.ts`

| Export | Purpose |
| --- | --- |
| `useVisiblePoll(fn, ms, enabled)` | Interval that runs only while `document.visibilityState === 'visible'`, and fires once immediately on becoming visible |
| `useDebouncedCallback(fn, ms)` | Stable callback that runs `fn` once, `ms` after the last call |

Both hold `fn` in a ref, so a fresh closure each render neither restarts the
timer nor changes the callback's identity — which is what lets the realtime
subscription list them as effect dependencies without being torn down and
rebuilt on every render.

### Strategy settings sync

`useAutoStrategy` and `useDeltaStrategy` both **apply the realtime payload
directly** instead of using it as a signal to re-read the row they were just
handed. Two guards make that safe:

- A write of our own within the last 3 seconds suppresses the incoming row, so
  an in-flight upsert is not clobbered by the pre-write state. `useAutoStrategy`
  additionally suppresses while the draft is dirty.
- `applyRow` compares a signature built from the **converted** values — config,
  `armed`, session counters — and returns early when nothing it displays has
  moved. The conversion matters: the same row arrives as strings over PostgREST
  and as numbers over realtime, so comparing raw columns would call every push a
  change.

The signature guard is what makes an armed strategy quiet. `apply_delta_strategy`
stamps `last_cycle = now()` on the settings row every cycle
([`0062`](../supabase/migrations/0062_windows_own_all_their_filters.sql)), and
that write is published like any other; the column is not one this hook reads.

### `account_counts()` — [`0063`](../supabase/migrations/0063_counts_are_counted_not_fetched.sql)

```
acct_id uuid, position_count bigint, fill_count bigint, open_order_count bigint
```

One row per account of the calling user, for the admin panel's three counts.
`language sql`, `stable`, `security invoker` — it runs as the caller, so the same
RLS policies that gate a direct select gate this, and it needs no privileged
role.

It replaces three unfiltered, unlimited selects that pulled every row of
`positions`, `fills` and `orders` into the browser to be counted there. Besides
the egress, that was silently fragile: where `db-max-rows` is configured,
PostgREST caps the response and a capped page would have been counted as though
it were the whole table.

The output columns are prefixed rather than named `positions` / `fills` /
`orders` because in a `language sql` body a `RETURNS TABLE` column shadows a
relation of the same name, and the correlated counts would fail to resolve.

### `lib/deltaStrategy.ts` — pure, no I/O

The delta strategy's rules, with no React and no fetching, so the band maths can
be reasoned about on its own. The browser uses it for the readout; the executing
copy is PL/pgSQL in
[`0012`](../supabase/migrations/0012_delta_strategy_engine.sql).

| Function | Signature | Notes |
| --- | --- | --- |
| `sessionPhase` | `(now, cfg) → { phase, day, tradingDay }` | `before \| open \| closed`, IST; handles a window that wraps midnight, and reports a day outside `tradeDays` as closed |
| `bookDeltas` | `(positions, tickerFor, spot, requireGamma?) → { legs, missing, gammaMissing }` | `missing` legs are reported, never guessed at. With `requireGamma` (options books) a leg needs delta *and* gamma; without it (futures books) a delta is enough and the gap is reported in `gammaMissing`. The perpetual takes both from the contract, not the feed — delta 1, gamma 0 — because the venue publishes `greeks: null` for it |
| `portfolioDelta` | `(legs) → number` | `Σ(signed lots × delta)`, hedge included |
| `portfolioGamma` | `(legs) → number` | `Σ(signed lots × gamma)`; negative on a short book, and unmoved by a hedge |
| `effectiveBand` | `(cfg, gp) → Band` | `±\|Γp\| × gammaMultiplier`, or the typed pair when off or underivable |
| `bandBreach` | `(dp, band) → 'low' \| 'high' \| null` | Reads the band in force, not the config |
| `landingTarget` | `(cfg, band, breach) → number` | Edge drawn back by `B`, or the midpoint |
| `itmQueue` | `(legs, cfg) → LegDelta[]` | Shorts at or beyond the trigger, most-ITM first; the perpetual is never in it (its ITM distance is −∞) |
| `rollQty` | `(target, dp, dItm, dRepl) → number` | §5.2, rounded down |
| `bandQty` | `(target, dp, dSelected) → number` | §5.4, rounded down |
| `hedgeLots` | `(target, dp, cv) → number` | Signed: `(target − Δp) ÷ cv`, magnitude rounded down. No delta divisor — a perpetual's delta is 1 |
| `strikeRoomLots` | `(cfg, heldLots, cv, spot) → number \| null` | Lots left under the notional cap; null when off |
| `pickByPremium` | `(expiry, kind, cfg, tickerFor, beyond?, roomFor?) → StrikePick \| null` | `beyond` is what makes a roll a roll; a strike with no room is not a candidate |
| `pickByDelta` | `(expiry, kind, cfg, tickerFor) → StrikePick \| null` | Inside `band_correction_delta` |
| `planCycle` | `(CycleInput) → CyclePlan` | One next action, plus the reason either way |

**Units.** Δp is in *contract-deltas* — no `contract_value` factor. That is the
unit the specification's worked example is written in (2 contracts across a 0.25
delta gap moves Δp by 0.5), and `[L, U]` is calibrated to the same one. Reading
it as XAUT-denominated delta would put every band figure out by 1000×.

**The band.** `[L, U]` is only the band when `gammaMultiplier` is zero. Above
zero the band is `±|Γp| × gammaMultiplier`, recomputed each cycle, and `L`/`U`
become the fallback for the two cases a derived band cannot cover — a flat book
and a book whose gamma has rounded away, both of which would give a width of zero
that every non-zero Δp breaches.

Γp is scaled by `contract_value` before the multiplier is applied, because the
multiplier is set against a band figure and the two have to be in one unit. The
magnitude is taken: this strategy only sells, so Γp is negative, and a signed
band would come out with `low` above `high`.

`Band.pending` separates *Γp is not in yet* from *there is no Γp*. Both hand back
the typed pair, but only the second is a settled answer; the first is a band about
to be replaced the moment the greeks land, and `planCycle` sets it because it is
the only thing that knows whether legs are held whose greeks are outstanding. The
readout prints an em dash rather than a fallback while it is set. Nothing acts in
that window — Δp is null for the same reason, and every branch that reads the band
is behind a non-null Δp.

Everything downstream reads the `Band`, not the config — the breach test, the
landing target, and the margin cut's side preference. The SQL side derives it
once per account per pass in
[`0039`](../supabase/migrations/0039_delta_gamma_band.sql) via `delta_band`,
which is the same rule as `effectiveBand` and has to be kept in step with it by
hand, like every other rule here.

> Which is why `qty` ([`0021`](../supabase/migrations/0021_qty_and_take_profit.sql))
> is the one setting that cannot be changed in isolation. It sizes the entry in
> XAUT the way the auto strategy does — `lots = round(qty / contract_value)`, and it
> is the spec's `N` in XAUT rather than lots, `pairs` having been folded into it by
> [`0024`](../supabase/migrations/0024_drop_pairs_and_fix_reentry.sql). Δp counts
> lots, so lots scale Δp one-for-one. At 1 XAUT a leg is
> 1000 lots and a 0.30-delta option contributes 300, which breaches the default
> `[-1, 1]` from the first fill and never recovers. The sizing formulas are
> scale-free and will compute correct contract counts either way; the *band* is
> what has to be rescaled with the size. It defaults to exactly one lot, so an
> existing account is untouched until the number moves.

**Rounding.** Both sizing formulas floor with a `1e-9` tolerance. A plain floor
gets the specification's own example wrong: the deltas are two-decimal
quantities, but `0.55 − 0.30` is `0.2500000000000001` in binary, so `0.5 ÷ that`
is `1.9999999999999996` and floors to 1 where the document says 2.

**Sides.** Δp below the band means a book too short-call heavy, so exiting an ITM
*call* lifts it and selling a fresh *put* does the same — which is why the roll
side and the sell side are always opposites. A futures-hedged book has no sides to
choose between: the same contract adds delta when bought and removes it when sold,
so the sign of `target − Δp` is the whole decision
([`0044`](../supabase/migrations/0044_futures_delta_hedge.sql)).

**Two hedging modes, one engine.** `planCycle` takes a `mode`, and
`apply_delta_strategy` reads the same distinction off `accounts.kind`. Three
things differ and nothing else: the branch that answers a breach, where the band
comes from (derived from Γp on an options book, typed on a futures one), and what
a leg must publish to be counted — delta and gamma, or delta alone
([`0045`](../supabase/migrations/0045_futures_band_without_gamma.sql)). Flatten,
cut, entry, brackets and session clock are shared verbatim. The hedge is *inside* Δp, so every hedge is
sized incrementally and an over-large one unwinds itself as a breach of the
opposite edge; nothing records what was hedged.

**Brackets.** `delta_sell` arms `take_profit = take_profit_mark` with
`tpsl_trigger = 'mark'` and no stop, on any short the fill leaves open. The level
is an absolute mark price rather than a multiple of the premium sold, so adding to
a short leaves it where it is; it is only armed when `avg_entry_price` is above
it, since a take-profit at or above a short's entry would fire on the fill that
opened it. `apply_tpsl_triggers` sets `v_up := v_long` when the reference is the
mark, so a short's take-profit fires on `v_ref <= take_profit` — the mark
*falling* is the short's gain. Reading the level off the account's own settings
rather than taking it as a parameter is what keeps the signature stable for
`apply_delta_strategy` and `delta_sell_entry`.

**The auto strategy's window is both ends of the day.** `apply_strategy` sells
only inside it; `apply_auto_exit` closes every open leg on an armed auto account
once outside it, at the exit side of the book, booking `close_reason =
'window_close'`
([`0015`](../supabase/migrations/0015_auto_strategy_exit.sql)). Both read the same
`in_ist_window(start, end, at)` — a second inlined copy of that arithmetic could
drift and leave a minute that both enters and flattens. The window is inclusive
of `window_end`, so the flatten begins the minute after it; the `00:00–23:59`
default has no outside and never fires. Exits route through
`close_position_triggered` rather than a market order, so the ledger labels them
and no order row is invented for a close the engine forced. A leg that cannot be
priced from the last 90s of replies is left open and retried, never closed at a
guess.

**Days.** `trade_days` on both settings tables holds ISO weekdays — Monday 1 to
Sunday 7, `extract(isodow)`'s numbering, so the column, the SQL and the client
count alike ([`0016`](../supabase/migrations/0016_strategy_trade_days.sql)). The
day tested is the one the **session opened on**, never the current date: for the
auto strategy that is `in_ist_window`'s `wday`, non-null exactly when the clock is
inside the window and equal to its open date; for the delta strategy it is
`delta_session`'s `sday`, which already keys the counters. So unselecting Saturday
still lets a Friday 22:00 session run to its close on Saturday morning.

A day left out is *out of session*, not merely "no entries" — `delta_session`
returns `closed` and `in_ist_window` returns false, which routes an off-day into
each engine's existing flatten. Neither can be left holding a book through a day
it does not trade. An empty array is a valid off state and reads as "never". Both
`in_ist_window` and `delta_session` were dropped and recreated rather than
overloaded: two candidates that each default their tail would make the old
two-argument call ambiguous.

**The auto strategy's premium cap vetoes, the delta strategy's floor narrowed.**
`strategy_settings.max_premium` skips a bar whose resolved strike is offered above
it ([`0017`](../supabase/migrations/0017_auto_strategy_min_premium.sql),
[`0046`](../supabase/migrations/0046_auto_strategy_buys.sql)) rather than looking
for a strike that fits — `moneyness` is the strategy's one rule about *what* to
buy, and a search would override it and could walk the position deep into the
money on a thin day. It was a floor on the bid until the strategy started buying;
the column was renamed rather than reinterpreted, because a seller's "too little
collected" and a buyer's "too much paid" are opposite tests.
`delta_strategy_settings.min_premium` read the same the other way (Section 6:
nothing is sold below the floor), and being a strike search there the floor
narrowed rather than blocked. A
skipped bar consumes `last_acted`, like every other skip path: the poll only
fetches in the first minutes of an hour, so the bar cannot be retried, and leaving
it unconsumed would re-log the same decision every minute for the rest of it.

**An expiry chosen by date does not roll.** `expiry_label` on both settings tables
holds a `ddmmyy` picked from the live chain
([`0023`](../supabase/migrations/0023_explicit_expiry.sql)), and each engine honours
it only while that expiry is still listed and unsettled. When it is not, the auto
strategy skips the bar and the delta strategy stands down — neither falls through
to another contract, because silently trading an expiry nobody selected is the
fault `0018` was written to remove and an explicit choice deserves the same
guarantee. Null falls back to the rule, which is what a fresh account uses.

One ordering detail in `apply_delta_strategy`: the session-close flatten sits
*before* the expiry lookup, so a stale expiry can never strand an open book. The
flatten reads positions, not settings.

**Nearest-unsettled is not the same as today.** `apply_strategy` sold the nearest
expiry still to settle, which diverges from the same-day contract two ways: XAUT
lists no contract for every calendar day (Mon 10 / Tue 11 / Fri 14 Aug leaves
Wednesday and Thursday with none), and the same-day one settles at 16:00 UTC =
21:30 IST. `expiry_rule = 'today'` — the default from
[`0018`](../supabase/migrations/0018_auto_strategy_expiry_rule.sql) — takes only
the contract whose label is the current IST date *and* is still unsettled, and
skips the bar otherwise rather than falling through.

It reads the **current** IST date, not the window's open day. A wrapped window
(22:00–06:00) belongs to its open day for the days filter, but that day's expiry
settled at 21:30 IST, before the tail even begins — so the overnight tail can only
ever trade the new day's contract.

The expiry now varies per account, so the strike ranking that `_k` used to hold in
a temp table built once before the account loop is a ranked subquery over `_chain`
instead. Deliberately not a temp table created inside the loop: that is the
plpgsql plan-caching trap [`0012`](../supabase/migrations/0012_delta_strategy_engine.sql)
called out when it chose an unlogged `delta_chain` over a temp one.

### Validation matrix

| Condition | Result | Message |
| --- | --- | --- |
| Fractional or non-positive qty | Blocked | whole number of lots |
| Market order, empty side | Blocked | market order cannot fill |
| Limit with no price | Blocked | enter a limit price |
| Off-tick limit price | Blocked | multiple of *tick* |
| Margin > available | Blocked | insufficient margin |
| Limit away from market | Allowed | will rest until it crosses |
| Spread > 10% on a market order | Allowed | wide spread — you are crossing it |

---

## 9. Degradation

| Input | Behaviour | Never |
| --- | --- | --- |
| Missing exit-side quote | Mark and P&L render `—` | Report `0` P&L |
| Both sides empty | Row shows `—`; orders blocked | Fabricate a mid |
| Contract absent from chain | Close button disabled with a tooltip | Silently fail |
| Illiquid strike, absurd bid | Marked honestly at that bid | Substitute mark price |
| `null` mark in totals | Contributes 0 to the sum, row shows `—` | Poison the total with `NaN` |

The illiquid case is worth calling out: a deep-ITM put quoted with a lowball bid
and no ask will show a large unrealized loss. That is the honest consequence of
exit-price marking, not a defect — but it surprises people.

Two prices, not one, and they answer different questions. P&L is struck at the
exit price, because that is the money the position is worth if it leaves now;
margin is struck at Delta's mark, because that is what the venue blocks and what
the server-side margin guard measures against. So a row's UPNL will not tie out
against the Mark Price column by the width of the spread, which is why the UPNL
cell names the price it used in its hover. Each price falls back to the other when
its own source is missing.

---

## 10. Verification

| Area | Method | Result |
| --- | --- | --- |
| Fees, margin, P&L, validation, crossing, netting | 30 assertions against a real ticker payload | Pass |
| Delta REST + WS contracts | Live calls to `api.india.delta.exchange` | Confirmed |
| Chain rendering, greeks, ATM anchor | Browser, live data | Confirmed |
| Order ticket maths | Browser — premium, notional, fee, margin | Matches derivations above |
| Position marking | Browser — long marked at bid, −$1.20 = spread | Confirmed |
| Schema deployment | Table probe + RLS write probe | Tables present; anon write → `42501` |
| `execute_fill` compiles | RPC reached the internal `raise` | Confirmed |
| `lib/deltaStrategy.ts` | 65 assertions — §5.2 worked example end to end, band and landing rules, corrective sides, ITM queue, the session clock across zones | Pass, on synthetic fixtures |
| Tickers payload shape | Live call — `greeks.delta`, `quotes`, `spot_price`, `contract_value` on all 113 XAUT symbols; **no `settlement_time`** | Confirmed |
| Delta strategy daily entry | Armed live — built the 113-row snapshot and sold its symmetric pair | Confirmed |

### Outstanding

**The write path inside `execute_fill`** — `INSERT INTO fills` and the positions
upsert — has not executed. Postgres plans statements inside a PL/pgSQL function on
first execution, so deployment success does not prove those two statements. The
first real trade validates them; if the schema misbehaves, that is where to look.

**Either strategy past its daily entry.** The roll, exit-only, band-correction and
futures-hedge branches of `apply_delta_strategy` have never run against a live
book — with `N = 1` the book cannot breach a ±1 band, so nothing has reached
them. They are exactly the branches that place and unwind size. Treat the first
live breach as the real test, and raise `N` deliberately rather than discovering
it in a moving market.

**No book is liquidated.** The liquidation pass in
[`0038`](../supabase/migrations/0038_futures.sql) skips any account holding a leg
with no fresh perpetual mark, and every option leg is one — so a strategy book
carrying a hedge is never tested. That is deliberate and matches the option books,
but it means the margin guard is the only thing bounding a hedged book.

**Two implementations of one rule set.** `lib/deltaStrategy.ts` and
[`0012`](../supabase/migrations/0012_delta_strategy_engine.sql) encode the same
specification in TypeScript and PL/pgSQL. Only the first is covered by
assertions, and nothing checks that they agree — a divergence would surface as
the readout predicting one thing and the engine doing another.

> The most recent instance, found by diffing the columns the engine writes
> against the columns the readout reads: the engine gates entry on
> `entered_window_ids` **or** a new day, and `planCycle` gated on the day alone.
> Everywhere except adjacent windows the two agree, because the closed cycle
> between spaced windows nulls `entered_day`; two windows that touch never
> produce one, so the readout claimed the session was entered while the engine
> opened the next window's book. Readout-only — the engine was right — but it is
> exactly the failure this section describes. `SessionState.enteredWindowIds`
> closes it, and the same pass fixed a real engine bug alongside it
> ([`0066`](../supabase/migrations/0066_the_newest_window_governs.sql)): on the
> boundary minute both windows are open and array order was picking the one that
> had just *expired* to govern the band, the premium and the size. The same
> migration names an id-less window by its position, so several of them can no
> longer collide on one entry stamp and silently leave every window but the first
> sitting flat.
>
> A second kind, and the one the first kind hides: the two implementations can
> also agree on a *wrong* answer. `resolveTargetExpiry` and the engine both read
> `today` / `tomorrow` / `friday` off the **UTC** date while every session clock
> in the app runs on IST, so between 00:00 and 05:30 IST `tomorrow` resolved to
> the day IST already called today — zero days to expiry where one was asked for.
> The readout confirmed it, because it had made the same mistake.
> [`0067`](../supabase/migrations/0067_the_expiry_day_is_the_ist_day.sql) moves
> both to IST. Agreement between the two is necessary and not sufficient; the
> clock each of them reads is its own question.
>
> A third, found by tracing one real window rather than by diffing: the answer to
> "which expiry is this book trading" was being computed in **four** places —
> `planCycle`'s caller, `entryLots`, and two spots in `App.tsx` — and every one of
> them called `pickExpiry` with the *raw account config* and no session day. So
> the readout used the account-level rule where the engine used the governing
> window's `daysToExpiry`, and counted from the calendar day where the session
> ran on its own. `pickSessionExpiry` is now the single answer, `CycleInput` no
> longer accepts a pre-resolved `expiry`, and `resolveSessionContext` is the one
> place a window's overrides are folded in
> ([`0068`](../supabase/migrations/0068_the_expiry_day_is_the_session_day.sql)).
>
> The shape of that fault is worth naming: it was not that the two
> implementations disagreed about a rule, but that one of them had four copies of
> the question. A type change was what closed it — passing `expiries` instead of
> `expiry` makes the wrong answer unrepresentable.
>
> The diff that found the first kind is worth repeating when either side changes:
> list the settings columns the engine writes, list the ones `COLS` selects, and
> read the difference. `touched_symbols` and `pass_open` are on it legitimately — engine
> bookkeeping the readout is documented not to model — so the check is not "the
> lists match" but "every difference has a reason".

> A second instance, found the day a teammate toggled a weekday off and on again:
> the flatten stamped `flattened_day` but left `entered_day` set, so the reopened
> session read "already entered today" and sat flat for the rest of the day
> reporting Δp = 0 — indistinguishable from a balanced book. Fixed in
> [`0024`](../supabase/migrations/0024_drop_pairs_and_fix_reentry.sql): the flatten
> clears `entered_day` and the entry clears `flattened_day`, because clearing only
> the first would leave the close-flatten stamped and carry a position overnight.
> The two flags have to move in step.

> This is not hypothetical. The S4 entry diverged for seven migrations:
> `planCycle` left the day unstamped when no strike cleared the floor, so it
> retried; the engine stamped `entered_day` whether or not `delta_sell_entry` had
> sold anything, so one thin quote at the open cost the whole session, silently.
> Fixed in [`0019`](../supabase/migrations/0019_delta_entry_all_or_nothing.sql),
> which also made the pair all-or-nothing — symmetry was checked when picking the
> strikes but the two sells were independent, so a thrown fill on the second leg
> left a naked directional short that fault one then held all day. Both legs now
> sit inside one block whose implicit savepoint unwinds the first if the second
> does not fill, so a retry starts from flat having paid no spread.

> And then [`0048`](../supabase/migrations/0048_futures_strategy_atm_shift_and_pairs.sql)
> reintroduced it. Rewriting `delta_sell_entry` for pairs dropped the before/after
> `net_qty` comparison, and since `delta_sell` swallows a failed fill and returns
> void, the entry went back to reporting success on a book it had not opened. The
> same rewrite called `delta_qty_to_lots`, a helper it never created — plpgsql
> resolves calls at run time, so the migration applied clean and the engine died
> at the open — and widened two signatures with `create or replace`, which adds an
> overload rather than replacing, leaving three call sites ambiguous. Fixed in
> [`0049`](../supabase/migrations/0049_futures_strategy_unbreak_the_cycle.sql).
>
> The lesson is narrower than "test the engine". Each of these is invisible to
> anything that only reads the migration: `check_function_bodies` does not resolve
> a plpgsql call, and an ambiguous overload is a resolution-time error on a branch
> that may not run for hours. 0049 ends with a `do` block that resolves every
> function the engine names and counts its definitions, which is the cheapest
> thing that would have caught all three at apply time rather than at 06:00.
>
> The band-management symptoms were downstream of all of it: an entry that raises
> takes the whole cycle with it, and an entry that merely fails used to `continue`
> past the ATM check, the hedge and the band correction. Opening the book by hand
> did not help either, because `entered_day` is only stamped by the engine's own
> entry — so the engine sat in the entry branch all day. Hence adoption: a
> two-sided short book the engine did not open is taken over rather than ignored.

> And then [`0050`](../supabase/migrations/0050_futures_min_days_to_expiry.sql)
> did it a third time, in one rewrite of the engine's opening statements. It
> called `delta_buy_back`, which had never been created, from three places. It
> read `max(a.balance)` from a table whose column is `cash_balance`. It wrote
> `delta_chain.updated_at`, a column that has never existed — in the *first* data
> statement of the function, so the whole strategy stopped, not just one branch.
> And [`0051`](../supabase/migrations/0051_futures_schedule_windows.sql) added
> `delta_session_window` as `immutable` while reading `now()`, which lets the
> planner freeze the answer for the life of a backend.
>
> Same root habit as 0048, and it is worth naming precisely: **plpgsql resolves
> names when a statement first executes, not when the function is created.**
> `check_function_bodies` parses the body; it does not resolve a called function,
> a table column, or an overload. So every one of these applied cleanly, and then
> failed hours later on a branch nobody had exercised — which reads as "it worked
> this morning" rather than as a deployment error. Fixed in
> [`0054`](../supabase/migrations/0054_session_window_is_not_immutable.sql)–[`0056`](../supabase/migrations/0056_delta_gate_stops_blocking_the_hedge.sql),
> and from 0056 onward each migration ends with a `do` block that resolves every
> column, function and signature the engine names, at apply time.

> [`0058`](../supabase/migrations/0058_read_our_own_reply.sql) then added a fifth
> instance of the same class, in the fix for the fourth. Its new response picker
> aliased the shared table as `r` — and `r` is the account-loop record this
> function declares. **plpgsql resolves a name against its own variables before a
> statement's table aliases**, so `r.content` bound to the unassigned record and
> the engine raised `record "r" is not assigned yet` on its *first* statement,
> every cycle, for a full day. `apply_trail_stops` has aliased that same table
> `resp` since 0037 for exactly this reason.
>
> No catalog check sees this one: it is not a missing name, it is a correctly
> spelled name resolving to the wrong thing. The guard that does see it is a
> regex over `pg_proc.prosrc` for a table aliased `r` or `s`, which
> [`0059`](../supabase/migrations/0059_close_only_what_the_band_needs.sql) runs at
> apply time. Crude, and still worth having — the failure mode is a strategy that
> is armed and silent.

<a id="bitcoin-spot-and-why-describe-the-reply-cannot-work"></a>

**Bitcoin spot, and why "describe the reply" cannot work.** The most expensive
bug in this codebase so far was not in the strategy logic at all. A flatten went
out reading `Wing empty — closed all positions · spot $78741.10 · Δp 9.11 → 0.00`
while gold was 4,430. Nothing malfunctioned after that number:

```
spot 78,741 vs a 4,520 call → spot − strike = +74,221
ATM rule fires at itmDistance >= 0 → every call is "at the money"
  → the whole call side closes
  → the empty-wing rule sees one side gone and flattens the book
```

`v_spot` was `max(spot_price)` over the whole of `delta_chain`, and a Bitcoin row
was in it. It got there because the engine picked a reply that was never meant
for it: `queue_strategy_checks` ([`0008`](../supabase/migrations/0008_strategy_engine.sql))
fetches `/v2/tickers?contract_types=call_options,put_options` with no
`underlying_asset_symbols` filter — 1043 tickers, once a minute — and that body
satisfies every test the delta engine used to identify its own reply, because its
first element is an XAUT put and options carry greeks. The delta poller's own
reply is 107 tickers. **The two bodies are the same shape; only the request that
asked for them differs.** No content predicate can separate them, which is why
0057's restored `greeks` guard does not stop this and
[`0058`](../supabase/migrations/0058_read_our_own_reply.sql) switches to request-id
correlation — the pattern `apply_trail_stops` has used since 0037.

Three defences now have to fail together, not one:

| Layer | Migration | Stops |
| --- | --- | --- |
| Read the reply to our own request id | [`0058`](../supabase/migrations/0058_read_our_own_reply.sql) | Any foreign reply, whatever it contains |
| XAUT-only filter on both chain upserts | [`0057`](../supabase/migrations/0057_chain_is_xaut_only.sql) | Non-XAUT rows reaching the chain |
| Spot scoped to XAUT, cross-checked against the XAUTUSD mark (20%) | [`0057`](../supabase/migrations/0057_chain_is_xaut_only.sql) | Trading on an implausible spot at all |

The generalisable part: **a number every rule reads is a single point of failure,
and it deserves a plausibility check of its own.** Δp, the ATM test, the roll
trigger, the margin guard and the flatten all consume `v_spot`, and none of them
could tell that it was wrong. The 20% cross-check costs one comparison per cycle
and would have turned a liquidated book into a log line.

**`0008` is a standing lesson in silent failure.** It read `settlement_time` from
`/v2/tickers`, which has never carried that field; the comparison against `now()`
was `NULL`, the expiry lookup matched nothing, and it returned `0` one line
before it would have traded — every minute, indefinitely, while `pg_cron`
recorded success. `last_acted` never leaving `NULL` was the only external symptom.
Fixed in [`0011`](../supabase/migrations/0011_strategy_expiry_fix.sql), which
also added a `raise log` to every early return.

---

## 11. Deferred work

| Item | Rationale for deferral | Sketch |
| --- | --- | --- |
| Expiry settlement | Largest gap to the real venue | On expiry, read settlement price, realize intrinsic, close position |
| Server-side limit fills | Avoids standing infrastructure | Edge Function on `pg_cron` polling REST and calling `execute_fill` |
| Size-aware fills | Touch-price fills adequate at current sizes | Walk the book against `bid_size`/`ask_size`; support partial fills |
| Maker/taker distinction | Both rates identical for XAUT today | Branch on resting vs crossing at fill time |
| Realtime sync | Refetch adequate for single-tab use | Supabase Realtime on the four tables |
| Stop-loss / take-profit | Not requested | Trigger orders evaluated in the same tick loop |
| One delta implementation | SQL was the shortest path to a tab-free engine | A worker importing `lib/deltaStrategy.ts`, so the tested code is the code that trades |
| Fees on strategy fills | Both engines pass `0` to `execute_fill` | Call `computeFee`'s SQL equivalent at fill time |
| Sub-minute delta cycles | `pg_cron`'s floor is one minute | A worker holding the feed, rather than refetching the chain each tick |

Note that size-aware fills would require relaxing the `partial fills are not
supported` guard in `execute_fill` and tracking `filled_qty` across multiple
executions — the column already exists for this.
