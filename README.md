# XAUT Options — Paper Trading Terminal

A Delta-Exchange-style derivatives terminal for **XAUT** (Tether Gold). Live
option chain, click-to-trade, positions, open orders and trade history — plus
three automated strategies that run on a schedule, one of them hedging its delta
with the XAUT perpetual future — with every order simulated. **No order ever
reaches the exchange.**

Four pages, each trading its own book:

| Page | Account kind | What it does |
| --- | --- | --- |
| **Option Chain** | `manual` | Click-to-trade the live chain by hand |
| **Auto Strategy** | `auto` | Buys one option per closed 1h candle — a call on a red bar, a put on a green |
| **Delta Strategy** | `delta` | The delta-band strategy from `Gold_Options_Delta_Strategy.docx`, correcting Δp with **options** |
| **Futures Strategy** | `futures` | The same strategy, correcting Δp by buying and selling the **XAUTUSD perpetual** instead |

The last two are one strategy on two books — one settings table, one engine, one
session clock, one entry, one band, one bracket, one margin guard. The only rule
that differs is the one that answers a breach of the band, and which one runs is
read off the account's kind rather than a setting, so the page and the rule cannot
disagree ([`0044`](supabase/migrations/0044_futures_delta_hedge.sql)).

The four never share a balance or a position: an account carries a `kind`, and
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

Blocked margin follows Delta's shape, at the rate they publish for that very
contract (`initial_margin`, **1%** for XAUT options):

```
short leg = (im_rate * spot + mark) * 0.001 * lots
long leg  = avg_entry * 0.001 * lots          (risk capped at the premium paid)
```

Two things Delta does that this does not, and they pull opposite ways: they raise
the rate with size via `initial_margin_scaling_factor` — which only bites above a
`max_leverage_notional` of \$100,000, roughly 22,500 lots, so it is not modelled —
and they margin options as a **portfolio**, stress-tested with offsetting between
opposing legs, where this sums each leg alone. So a two-sided book is margined
more conservatively here than there.

### Fees

A rate on underlying notional — **0.01%**, taken from the product's own
`taker_commission_rate` rather than hardcoded, so it tracks the venue. Notional
is `spot × contract_value × lots` on an option and `price × contract_value ×
lots` on the perpetual.

> **There is no premium cap any more.** Earlier builds took
> `min(0.01% of notional, 3.5% of premium)`, which mattered on cheap far-out
> strikes where the cap bound. Both the browser (`computeFee`) and the server
> (`execute_fill`) now charge the notional leg alone.

Fees are charged on **every** fill, including the ones the strategy engines
place. Until [`0052`](supabase/migrations/0052_futures_fees.sql) they were not:
every engine called `execute_fill(..., 0, ...)`, and a zero fee was taken at face
value, so engine fills were free and their P&L flattered. `execute_fill` now
computes `0.0001 × notional` itself whenever the caller passes nothing, and
deducts it from `cash_balance` alongside realized P&L — so realized P&L, balance
and total P&L all include fees for engine and manual fills alike.

This matters more than it sounds on a strategy that re-hedges often: a book that
corrects its delta every twenty seconds pays the spread and this fee each time,
and that churn can dominate the position P&L. The trade history's daily header
totals fees separately for exactly that reason.

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

### How the screen stays current

Three mechanisms, in the order they matter:

1. **Realtime** — Postgres pushes every change to `positions`, `orders`, `fills`,
   `accounts` and both strategy settings tables. This is the primary path: a
   change lands on screen the moment it lands in the database, whichever session,
   cron or settlement pass made it.
2. **A 15-second poll** — the fallback, for a dropped subscription or a change
   realtime did not deliver.
3. **The market WebSocket** — quotes only, at 4 repaints a second. It never
   reads the database.

The two database mechanisms are deliberately narrow, because a terminal left open
all day is the normal way to use this app and every one of those reads is billed
Supabase egress:

- **Four books are live at once** — manual, auto, delta and futures — but only one
  page is on screen. All four keep their positions and open orders current,
  because the browser fill engine prices every book and the WebSocket
  subscription is built from every book's held symbols. Nothing else is fetched
  for the three you are not looking at.
- **Trade history is fetched when its tab is opened**, not on the poll. The
  window is the newest 1000 fills — by far the largest read in the app, and one
  nothing computes from: no strategy, no fill engine and no balance reads a fill
  row. The tab badge is a `HEAD` count, so it stays honest without moving any
  rows. Once open, new fills arrive incrementally — only rows newer than the
  newest one held.
- **Realtime handlers are split per table and debounced.** One strategy cycle
  writes an order, its fill and the position it moved within milliseconds; that
  burst refreshes each affected table once, not each table once per event.
- **Strategy settings apply the pushed row directly** rather than treating the
  push as a signal to re-read the same row. This matters most while a strategy is
  armed: the engine stamps `last_cycle` on its settings row every cycle, and
  that write carries nothing the panel displays.
- **Polls stop while the tab is hidden** and reconcile once on return. Nothing
  that must keep running depends on them — the fill engine runs off the
  WebSocket, and both strategy engines run server-side on `pg_cron`.
- **Account changes are filtered by book.** Postgres can only filter that
  subscription by `user_id`, so all four instances are told about every account
  you own; each now ignores a row belonging to a kind it does not manage, rather
  than all four refetching on every balance change.

None of this changes what is on screen or how fast it reacts. Realtime still
drives every update.

### Auto Strategy

One fixed rule, no discretion: read the last **closed 1h candle** of the spot
index and buy an option — a red bar buys a call, a green bar buys a put — at the
chosen moneyness off the nearest expiry, inside a time-of-day window (IST), with a
stop read off `stop_loss_pct` on the mark.

> **It buys, as of [`0046`](supabase/migrations/0046_auto_strategy_buys.sql).** The
> signal and every control are unchanged; the side of every trade is not. Read as
> a strategy it is now the mirror of what it was: selling a call into a red hour
> was a bet the fall would hold, buying one is a bet on the bounce. Same bars,
> opposite view — worth knowing before comparing a run of results to an older one.

The stop has two halves, and the **tighter one is armed**
([`0020`](supabase/migrations/0020_auto_strategy_stop_pct.sql),
[`0037`](supabase/migrations/0037_auto_trailing_stop.sql)). Both are a percent of
the premium — the number an option buyer actually thinks in — and both are watched
on the option's own mark. They differ only in what they measure from:

```
entry stop = avg_entry_price      × (1 − stop_loss_pct  / 100)     fixed
trail stop = last 1m candle close × (1 − trail_stop_pct / 100)     re-read every minute

stop_loss  = greatest(entry stop, trail stop)
```

At `stop_loss_pct = 50` a $4 long stops at $2 — half the premium lost. `25` stops
it at $3; `0` arms no fixed stop. **`100` and above arm none either**, and that is
arithmetic rather than a rule: the level would land at or below zero, which is not
a price an option marks at. A long cannot lose more than it paid, so there is
nothing beyond 100% for a stop to protect.

> The column's default is `100`, which used to mean "stop at twice the premium"
> and now means **no fixed stop**. Any auto account that has never touched the
> field is on it. Set it to what you actually want — the loss is bounded by the
> premium either way, which is what makes running without a stop survivable here
> in a way it never was on a short.

The trailing half measures the same share against what the option is *trading at
now*, so as the position gains the stop follows the premium up and locks the gain
in. On a $4 long with both set to 50:

| Premium now | Entry stop | Trail stop | Armed |
| --- | --- | --- | --- |
| 4.00 | 2.00 | 2.00 | 2.00 |
| 8.00 | 2.00 | 4.00 | **4.00** |
| 12.00 | 2.00 | 6.00 | **6.00** |
| 6.00 | 2.00 | 3.00 | **3.00** |

> Read that last row before switching it on. `greatest` is taken of the two levels
> **as they stand this minute**, so the trail follows the premium back down as well
> as up and the stop can loosen again — never past the entry stop, which is what
> bounds the worst case. Keep an entry stop set as the outer limit even when the
> trail is doing the work.

The minute close is Delta's own 1-minute candle for that option symbol, not the
mark: `apply_trail_stops` reads the most recently *closed* bar every 30 seconds
and moves the level only when it actually changes. `trail_stop_pct = 0` switches
the trailing half off, which is the default, so nothing changes for an existing
account until the number is moved.

`take_profit_pct` is the mirror — a percent of the premium **made**
([`0021`](supabase/migrations/0021_qty_and_take_profit.sql)):

```
take_profit = avg_entry_price × (1 + take_profit_pct / 100)
```

`70` sells a $4 long at $6.80. There is no ceiling on it any more: a long can make
several times what it paid, where the short this replaced could never clear 100%
of the premium it collected. Default `0`, so no take-profit is armed until you set
one. Both levels are read off `avg_entry_price`, so adding to a symbol re-bases
them onto the blended entry rather than leaving them pinned to the first fill.

The window is both ends of the day. Inside it the strategy buys; once past
`window_end` it stops **and flattens** — `apply_auto_exit()` closes every open
leg at the exit side of the book and books the fill as `window_close`
([`0015`](supabase/migrations/0015_auto_strategy_exit.sql)), so nothing is
carried overnight. The default window is `00:00–23:59`, which has no outside, so
an account left on it is never force-closed.

`trade_days` narrows that to chosen days of the week
([`0016`](supabase/migrations/0016_strategy_trade_days.sql)). A day left out is
treated as out of session, not merely as "no entries" — the flatten covers it,
so the strategy can never be left holding a book through a day it does not
trade. Days are ISO weekdays (Mon 1 – Sun 7) on the same IST clock as the
window, and the day tested is the one the window *opened* on, so a window that
wraps past midnight belongs to the day it started.

The **expiry is picked by date**, from the live chain, the way the option chain's
own tabs list them ([`0023`](supabase/migrations/0023_explicit_expiry.sql)). A date
does not roll: once the chosen expiry settles the strategy skips its bars until a
new one is picked, rather than buying a contract nobody chose. The tab marks a
settled selection so the reason it stopped is on screen.

With no date chosen, `expiry_rule` still applies
([`0018`](supabase/migrations/0018_auto_strategy_expiry_rule.sql)). Its default,
**`today`**, buys only the same-day contract on the IST clock and **skips the bar
when there is none**. Two consequences worth knowing:

- XAUT does not list a contract every calendar day (a live set of Mon 10 / Tue 11
  / Fri 14 Aug leaves Wednesday and Thursday with no same-day expiry at all).
- The same-day contract settles at **16:00 UTC = 21:30 IST**, so from 21:30 there
  is nothing same-day left to buy.

On either, an account on `today` stands down and logs why. `nearest` restores the
old behaviour of taking the nearest unsettled expiry whatever its date.

`max_premium` puts a ceiling on the entry
([`0017`](supabase/migrations/0017_auto_strategy_min_premium.sql),
[`0046`](supabase/migrations/0046_auto_strategy_buys.sql)): a bar whose strike is
**offered above it is skipped, not bought**. It was a floor on the bid while the
strategy sold — a seller's version of "this trade does not pay" is too little
collected, a buyer's is too much paid — and the column was renamed rather than
quietly reinterpreted. It still vetoes rather than hunting for a cheaper strike:
the strike is `moneyness`'s to choose, and searching for whatever fits the budget
would quietly override that. `0` disables it.

The controls are only *whether* it runs, the strike, the size and the window.
The engine itself is `apply_strategy()` on `pg_cron`
([`0008`](supabase/migrations/0008_strategy_engine.sql)), so it trades with the
tab closed. It acts at most once per bar, guarded by `last_acted`.

> It can only ever act in the **first few minutes of an hour** — the poll gates
> itself to that window, and the reply it reads expires after 150 seconds. Miss
> it (a flat bar, an unquoted strike, a slow fetch) and the bar is consumed until
> the next hour. Every skip path logs its reason.

### Delta Strategy

The delta-band strategy specified in `Gold_Options_Delta_Strategy.docx`. In
short: sell a symmetric call/put pair at the session open, keep net portfolio
delta **Δp** inside a band, and flatten at the close.

It drives **two books**, and everything below is shared by both except the rows
marked *Breach*, *ATM Exit & Shift*, and *Empty Wing*:

| | Delta Strategy (`delta`) | Futures Strategy (`futures`) |
| --- | --- | --- |
| Breach | Roll an ITM short further out; fresh OTM sell when nothing is left to roll | Buy or sell the XAUTUSD perpetual |
| ATM Exit & Shift | Rolls triggered on band breach | **Exit immediately at ATM** (`itmDistance >= 0`), sell replacement on same side at 50% (`shift_pct`), limit `max_shifts` per side |
| Empty Wing | Retains remaining side | **Auto-flatten all remaining positions** (options & futures hedge) if either wing is empty |
| Entry Pairs | 1 symmetric pair at `entry_premium` | Configurable `pairs_count` and `[entry_premium_min, entry_premium_max]` range |
| Band | Derived from Γp × `gamma_multiplier` by default | **As typed.** Gamma is not read at all |
| Book grows? | Yes — a correction is more premium sold | No — the option book is only what the entry and shifts sell |
| Long exposure? | Never. **No leg is ever bought as a hedge** | The hedge is bought or sold outright |

On the delta book the strategy is **sell-only**: every correction is more premium
sold, or an exit — never a long option. The futures book keeps that rule for
*options* and answers the band with a linear hedge instead; see
[The futures hedge](#the-futures-hedge) and [Futures Strategy mechanics](#futures-strategy-mechanics).

| Phase | Rule |
| --- | --- |
| Open (06:00 IST) | Sell `pairs_count` (1 on `delta`, configurable on `futures`) symmetric pair(s) — pair *i* is the *i*-th ranked strike on each side, so the pairs land on distinct strikes nearest `entry_premium` (optionally filtered within `[entry_premium_min, entry_premium_max]`), sized by `qty` in XAUT — the spec's `N`, in XAUT rather than lots ([`0024`](supabase/migrations/0024_drop_pairs_and_fix_reentry.sql), [`0048`](supabase/migrations/0048_futures_strategy_atm_shift_and_pairs.sql), [`0049`](supabase/migrations/0049_futures_strategy_unbreak_the_cycle.sql)). Each pair fills whole or not at all; a failed open is retried on the next refresh rather than written off for the day |
| Book already open | A two-sided short book the engine did not itself open — one placed by hand — is **adopted**: the day is stamped and the cycle carries straight on into management, rather than retrying the entry forever and never defending the band ([`0049`](supabase/migrations/0049_futures_strategy_unbreak_the_cycle.sql)) |
| Intraday · `delta` | Rebuild the ITM queue each cycle, most-ITM first; resolve breaches by partial exit-and-replace |
| Roll budget · `delta` | Each side gets `max_rolls`; once spent that side is **exit-only** — further triggers close in full, loss booked |
| No ITM legs left · `delta` | Band-correct with fresh OTM sells at the entry premium |
| ATM Exit & Shift · `futures` | When spot touches/crosses strike (`itmDistance >= 0`), close leg immediately and sell replacement on same side at 50% of exit price (up to `max_shifts` times per side, then exit-only) |
| Empty Wing · `futures` | If either Call or Put side has 0 open positions, auto-flatten all remaining options and the perpetual futures hedge |
| Intraday · `futures` | One trade in the perpetual per breach, `(target − Δp) ÷ contract_value` lots, bought when Δp is short of the target and sold when it is past it |
| Close (22:00 IST) | Flatten everything, stand flat overnight, reset counters |
| Off day | A weekday outside `trade_days` reports the session **closed**, so the same flatten covers it and nothing is opened |
| Margin over `margin_cap_pct` | Stop selling and **cut** instead: close lots, deepest ITM first, on the side whose exit pulls Δp toward the band, down to `margin_target_pct` — loss booked ([`0031`](supabase/migrations/0031_delta_margin_guard.sql)). Below the cap every rule runs, at any margin ([`0041`](supabase/migrations/0041_always_manage_delta.sql)) |

Every short it opens carries a **take-profit and no stop**, watched on the
option's own mark:

```
take_profit = take_profit_mark
```

The level is a price, not a multiple of the premium sold: at the default **0.7**
any short leg is bought back when its mark reaches **$0.70**, whatever it sold
for. Adding to a position leaves the level where it is, and `0` disables it.

`stop_loss_mark` is the other side of the same bracket — the leg is bought back when
its mark *rises* to it ([`0026`](supabase/migrations/0026_delta_stop_loss_mark.sql)).
It defaults to `0`, no stop, because **the rules document specifies none**: §5.3
makes the per-side roll budget and exit-only mode the risk control, and Section 6
never lists a stop among the constraints applied throughout. Neither bracket is the
spec's — both are additions.

> Worth understanding before switching the stop on. A leg going against you is
> exactly the leg the ITM queue exists to roll: buy part of it back, sell further
> out, keep collecting. A stop closes it outright instead, so the roll never
> happens, the premium is not replaced, and Δp jumps by that leg's whole
> contribution — which the next cycle corrects by selling somewhere else. Set it
> generously if at all.

Sizing is the document's, all rounded **down** so a correction cannot overshoot:

```
roll:            q = (target_landing - Δp) / (d_itm - d_replacement)
band correction: q = (target_landing - Δp) / d_selected
futures hedge:   q = (target_landing - Δp) / contract_value
```

The hedge has no delta divisor because a perpetual's delta is **1**: one lot of it
carries one lot of the underlying, so the only conversion is out of the band's qty
units and into venue lots.

**Δp is measured in contract-deltas** — `Σ(signed lots × option delta)`, with no
contract-value factor. That is the unit the document's own worked example is
written in, and the band is calibrated to the same one.

#### The futures hedge

On the **futures** book every breach is answered by one trade in `XAUTUSD`, and
no option is ever touched to move Δp. The rule reads in full:

```
lots = (target_landing - Δp) / contract_value      rounded down in magnitude
side = buy when the result is positive, sell when it is negative
```

The band still decides *when* — the same gamma-derived band, the same
`target_landing` and `B` — so what changes is only the instrument the correction
is made in. A breach worth less than one lot does nothing and says so.

**The hedge is inside Δp.** It is not tracked separately: the perpetual lands in
the engine's chain snapshot as one more row, with the greeks a linear contract
actually has —

```
delta 1     one lot of the perpetual is one lot of the underlying
gamma 0     that delta does not move, whatever spot does
```

— so `Σ(signed lots × delta)` counts it without being told to. Three things fall
out of that, and they are the reason it is done this way:

- **Every hedge is sized incrementally.** `target − Δp` already nets off whatever
  hedge is on the book, so nothing has to remember what was hedged, and a cycle
  that fires twice cannot double up.
- **It unwinds itself.** As the option deltas come back, the hedge that answered
  them is now too large — which reads as a breach of the *other* edge, and the
  same rule sells it back down. There is no separate unwind rule to get wrong.
- **The band is still set by the options.** Γp gets nothing from a gamma-0
  contract, so a hedge neither widens nor narrows the band it was placed to
  satisfy. That is the honest answer: the band scales with how fast Δp moves, and
  a linear hedge does not move it.

Delta publishes `"greeks": null` on the perpetual — no venue quotes greeks for a
contract whose greeks are constants — so those two numbers are written as
literals, in the engine and in the browser's copy alike. If the perpetual ever
goes missing from the chain reply, a book holding a hedge stands down for the
cycle with `waiting on greeks` rather than trading against a Δp it cannot
measure.

**No gamma on this book.** The band is `band_low`/`band_high` as typed, and
`gamma_multiplier` is an options-only control that does not appear on the futures
bar at all ([`0045`](supabase/migrations/0045_futures_band_without_gamma.sql)).

The derivation exists because gamma is the rate Δp moves at, so a book that runs
through delta twice as fast could be given twice the tolerance and correct half as
often. That trade is worth making when every correction is a **fresh short** —
expensive, irreversible, and one more leg on the book. It is worth nothing when
the correction is a hedge: one linear trade, costing the spread and a little
margin, undone next cycle if it turns out wrong. And a *wider* band on a
fast-moving book is the opposite of what a hedger wants — a book running is the
moment to be closer to flat, not further from it.

The consequence that actually matters is not the width, though — it is the
stand-down. [`0039`](supabase/migrations/0039_delta_gamma_band.sql) made gamma
required on the same terms as delta, and rightly: with a multiplier set, a leg
silently missing from Γp moves the band by that leg's whole share, so one null
gamma stands the cycle down. On the futures book nothing reads Γp, so a missing
gamma corrupts nothing — but it would still leave the book unhedged, which is the
one job it has. **A futures account needs a delta on every leg and nothing more.**
An options account is unchanged and still needs both.

Γp is not shown on the futures bar either, because it is not computed there.
The perpetual still carries gamma 0 in the chain snapshot — that is simply what a
linear contract's gamma is — and the positions table still prints it.

**What a hedge costs.** Margin, funding and the spread:

```
margin  = mark × contract_value × lots / hedge_leverage    (floored at the 1% IM)
funding = mark × contract_value × |lots| × funding_rate / 100, every 8h
```

`hedge_leverage` defaults to **100** — the venue's maximum, and the right end of
the range for a hedge: leverage decides what the position *blocks*, never what it
risks. At a 1.5 XAUT hedge against a $4,600 index that is about **$69** of margin
rather than $6,900. Funding is charged by the same cron that has always charged
it ([`0038`](supabase/migrations/0038_futures.sql)), which bills every open
perpetual whatever kind of account holds it, so the strategy bar shows what the
next payment will be and when. The hedge buys the ask and sells the bid like
every other engine trade — no mid is assumed.

**Two things the hedge is deliberately exempt from.** Both concern the margin
guard, and both cut the same way:

- **A cut cannot close it.** Cut candidates are short *options* only. Closing the
  hedge would take off the one position reducing the book's directional risk, and
  it has no strike for the deepest-in-the-money ordering to read. The cut takes
  lots off the option shorts, Δp moves, and the next cycle re-hedges what is left.
- **It is not trimmed to the cap.** The band correction is
  ([`0043`](supabase/migrations/0043_stop_the_cut_correction_loop.sql)), because a
  fresh short adds the risk the cut then has to take back off. A hedge does the
  opposite, and refusing to place one for being expensive in margin would be
  refusing to reduce risk. Over the cap the cut still runs first — it outranks
  everything below the session close — so a hedge waits at most one cycle.

**No bracket rides on it.** Every short option the strategy opens carries the
take-profit below; the hedge carries neither mark. A take-profit on a hedge would
close it on a move in the book's favour and leave the option legs uncovered,
which is the one thing it exists to prevent. Δp is its only exit condition, and
the session close is its only other one — the flatten closes it with everything
else, through the same two helpers, because a buy at the ask and a sell at the bid
is right for a perpetual too.

A worked cycle, at the defaults:

```
Δp -1.35   band [-1, +1]   target -0.60   cv 0.001
lots = (-0.60 - -1.35) / 0.001 = 750       ->  buy 750 XAUTUSD
Δp -1.35 -> -0.60          margin blocked +$34.67 at 100x
```

and the row it writes says exactly that:

```
Bought futures — band breach (target -0.60) · spot $4622.13 · Δp -1.35 → -0.60
```

#### Futures Strategy mechanics

The **Futures Strategy** (`accounts.kind = 'futures'`) introduces specific position lifecycle rules tailored for hybrid option-writing + futures hedging ([`0048`](supabase/migrations/0048_futures_strategy_atm_shift_and_pairs.sql)):

1. **Exit at the ATM**: When gold price reaches or breaches an open short option's strike (`spot >= strike` for Calls, `spot <= strike` for Puts, i.e., `itmDistance >= 0`), that leg is exited immediately at market price ($P_{\text{exit}}$).
2. **ATM Shift at 50%**: At the ATM exit price, the strategy sells a replacement position on the same side at a configurable percentage (`shift_pct`, default **50%**) of $P_{\text{exit}}$.
   - **Shift limit**: Configured via `max_shifts` (default **1** per side per session). Counters `shifts_used_call` and `shifts_used_put` track shift executions. Once the shift budget is exhausted on a side, subsequent ATM triggers on that side close the position in full with no replacement (*exit-only*).
3. **Empty Wing Auto-Flatten**: If there are no open short positions remaining on either side (e.g. all Calls were exited or all Puts were exited), the strategy automatically flattens all remaining positions (remaining options and any open perpetual futures hedge).
4. **Number of Pairs & Premium Range Filters**:
   - **`pairs_count`** (default **1**): The number of symmetric Call/Put pairs shorted at the session open. Both sides are ranked by the usual premium rule and joined on rank, so pair *i* is the *i*-th best call against the *i*-th best put — distinct strikes, in the same order the tab's readout lists them.
   - **`entry_premium_min`** & **`entry_premium_max`** (default **0**, unconstrained): The two bounds are **not** symmetric, deliberately ([`79f0f07`](supabase/migrations/0049_futures_strategy_unbreak_the_cycle.sql)).
     - **`entry_premium_min` is a hard floor.** A strike quoted below it is dropped, and if that empties a side the entry does not open — there is no fallback to the unfiltered list. The readout names the floor when this is what stopped it.
     - **`entry_premium_max` is approximate.** It does not exclude a richer strike. It only supplies the target to rank against when `entry_premium` is unset, so a range of 3–5 can and will sell a leg at 7.30 if that is the strike nearest the target. Set `entry_premium` if you want the target somewhere specific.
5. **Delta management, in two tiers** ([`0055`](supabase/migrations/0055_futures_delta_management_fallback.sql)). A band breach is answered by the perpetual first and the option book only as a last resort:
   - **Margin available → hedge.** Buy or sell XAUTUSD to bring Δp back to the target. This is the cheap correction: it moves Δp without touching the option legs and books no loss. Affordability is `equity − blocked margin` from `delta_account_margin`, capped by `margin_cap_pct` when one is set, against the hedge's own initial margin (`lots × mark × cv ÷ hedge_leverage`). A hedge that *reduces* an existing perpetual is always affordable — it returns margin rather than taking it.
   - **No margin → close the offending leg, in full.** Which leg is *measured*, not guessed: each leg's signed contribution is `net_qty × delta`, and the one closed is the largest contribution pointing the same way as the breach. Above the band that is the short put (`net_qty < 0`, `delta < 0`, so the product is positive); below it, the short call. Ordering by contribution rather than by moneyness gets both sides right with no special-casing. The fill is stamped `No margin to hedge — closed the leg driving Δp, loss booked`.

#### Schedule windows

A futures book can run several trading windows in a day rather than one session
([`0051`](supabase/migrations/0051_futures_schedule_windows.sql)). `schedule_windows`
is a JSONB array; each entry carries its own `startTime`/`endTime` plus optional
overrides for `entryPremium`, `entryPremiumMin`/`Max`, `pairsCount`, `qty`,
`maxNotionalPerStrike`, `tieBreak`, `bandLow`/`bandHigh`, `targetLanding`,
`bandBuffer`, `hedgeLeverage`, `shiftPct` and `maxShifts`. Anything a window
leaves out falls back to the column of the same name on the settings row, so a
window is a diff against the account's defaults, not a replacement for them.

`delta_session_window` walks the array in order and returns the first window the
clock is inside; outside every window the phase is `closed`, which is the same
flatten-and-stand-down path a session close takes. Windows may wrap midnight
(`startTime > endTime`), in which case the session day is the day the window
*opened*, not the calendar day.

Entry is gated per window, not per day: `entered_window_ids` records which
windows have already opened a book today, and the daily `entered_day` stamp is
kept alongside it. The empty-wing flatten deliberately clears **neither** — a
book that was closed inside a window stays closed for the rest of it.

#### Expiry rules

`expiry_rule` replaces picking a fixed date by hand
([`0050`](supabase/migrations/0050_futures_min_days_to_expiry.sql)):

| Rule | Picks |
| --- | --- |
| `today` | The expiry settling today; falls back to the nearest live one if there is none |
| `tomorrow` | The nearest expiry settling tomorrow or later |
| `friday` | The nearest Friday expiry; falls back to the nearest live one |
| `nearest` | The nearest live expiry, `+1` when `expiry_pick = 'next'` |
| a `ddmmyy` label | That exact expiry, and nothing if it is no longer listed |

Every rule also requires the expiry to be more than sixteen hours from its
settlement, so the strategy never opens into a contract about to expire.

#### What 0048 broke, and what 0049 fixed

0048 shipped with four faults that stopped the engine outright, so it is worth
knowing what they looked like from the tab
([`0049`](supabase/migrations/0049_futures_strategy_unbreak_the_cycle.sql)):

Every one of them raised inside `apply_delta_strategy()`, and because pg_cron
runs that function as the whole statement, the exception rolled the transaction
back — including the `last_cycle = now()` stamp. The engine therefore retried
every couple of seconds, threw again, and never reached a second armed account.
Armed, and doing nothing, for no visible reason.

| Fault | What it looked like |
| --- | --- |
| `delta_sell_entry` called `delta_qty_to_lots`, a helper that was never created | Switched on, no position ever opened — and nothing below the entry branch ran either: no ATM exit, no empty-wing flatten, no hedge, no band correction, no close-flatten |
| `delta_pick_premium` and `delta_sell_entry` gained parameters via `create or replace`, which adds an overload instead of replacing | 0042's older signatures stayed live beside them, so the ATM shift, the roll and the band correction each matched two candidates and raised `function ... is not unique` |
| The entry lost [`0019`](supabase/migrations/0019_delta_entry_all_or_nothing.sql)'s all-or-nothing fill check | `delta_sell` swallows a failed fill, so the entry reported success either way: the day got stamped on an empty book, or on one leg of a pair — a naked directional short |
| A failed entry did `continue`, skipping the rest of the cycle | Open a book by hand and it was still never managed: `entered_day` stayed null, so the engine went back to the entry branch every cycle and left the band alone all day |

The last one is why the engine now **adopts** a two-sided short book it did not
open, and why a failed entry no longer takes the rest of the cycle with it. Both
sides are required before adopting: a one-sided book is not this strategy's
position, and adopting one would hand it straight to the empty-wing rule, which
would close a leg put on for someone else's reasons.

#### What 0050 broke, and what 0054–0058 fixed

0050 rewrote the top of the engine — the ticker fetch, the chain refresh and the
margin guard — and shipped four faults doing it. Three are the same shape as
0048's, and the fourth cost a book.

| Fault | Fixed in | What it looked like |
| --- | --- | --- |
| `delta_buy_back(...)` called in three places, never created | [`0055`](supabase/migrations/0055_futures_delta_management_fallback.sql) | Every buy-to-close path raised `undefined_function` and took the whole cycle with it |
| `max(a.balance)` — `accounts` has `cash_balance`, not `balance` | [`0055`](supabase/migrations/0055_futures_delta_management_fallback.sql) | The margin guard raised for any account with `margin_cap_pct > 0` and an open option leg, which is all of them |
| `delta_chain.updated_at` written by both upserts; the column has never existed | [`0056`](supabase/migrations/0056_delta_gate_stops_blocking_the_hedge.sql) | The *first* data statement in the function raised, so nothing ran at all — no entry, no ATM shift, no hedge, no close-flatten |
| Chain refresh dropped its XAUT filter, its `greeks` guard **and** the per-cycle `delete` | [`0057`](supabase/migrations/0057_chain_is_xaut_only.sql), [`0058`](supabase/migrations/0058_read_our_own_reply.sql) | A Bitcoin spot price entered the chain and liquidated a book — see below |

[`0051`](supabase/migrations/0051_futures_schedule_windows.sql) added a fifth:
`delta_session_window` was declared `immutable` while reading `now()`. That is a
promise the planner is entitled to act on — evaluate once, reuse forever — so the
window the engine believed it was in could freeze for the life of a pg_cron
backend. `delta_session`, the single-window function it was modelled on, has been
`stable` since [`0022`](supabase/migrations/0022_delta_session_ist.sql) for
exactly this reason. Fixed in
[`0054`](supabase/migrations/0054_session_window_is_not_immutable.sql).

##### The Bitcoin spot incident

A flatten went out reading:

```
Wing empty — closed all positions · spot $78741.10 · Δp 9.11 → 0.00
```

Gold was 4,430 — the XAUTUSD fill on the same row says so. 78,741 is Bitcoin.
Nothing malfunctioned *after* that number; every rule that reads spot did exactly
what it was told:

```
spot 78,741 against a 4,520 call  →  spot − strike = +74,221
the ATM rule fires at itmDistance >= 0, so every call is "at the money"
  → the whole call side is closed
  → the empty-wing rule sees one side gone and flattens the book
```

Four things had to line up, and 0050 supplied three of them:

1. **`net._http_response` is shared.** Every `pg_net` caller in the database
   writes to one table. The delta engine never knew which reply was its own — it
   *described* one (200, recent, body has `"result":[`, body mentions XAUT, first
   element has greeks) and took the newest match.
2. **`queue_strategy_checks`** — the auto strategy's poller, unchanged since
   [`0008`](supabase/migrations/0008_strategy_engine.sql) — fetches
   `/v2/tickers?contract_types=call_options,put_options` with **no**
   `underlying_asset_symbols` filter. That is every option on the exchange: 1043
   tickers, Bitcoin among them, once a minute on the minute. Its first element is
   an XAUT put, and options carry greeks, so it passes all five tests. The delta
   poller's own reply is 107 tickers; the only thing separating them is size, and
   nothing was looking at size.
3. **The chain refresh lost its symbol filter**, so those 1043 rows were all
   inserted, not just the XAUT ones.
4. **The per-cycle `delete from delta_chain` was replaced by an upsert**, so the
   contamination was permanent rather than lasting one cycle.

And spot was `max(spot_price)` over the whole table, unscoped — so the first
Bitcoin row to land became spot for every account, for good.

The fix is layered, because any one layer failing should not be enough:

- **0057** purges non-XAUT rows, restores the symbol filter on both upserts,
  scopes spot to XAUT symbols, and cross-checks it against the XAUTUSD mark — a
  disagreement wider than 20% stands the cycle down instead of trading on it.
  `delta_hedge` is also pinned to `symbol = 'XAUTUSD'`; it was taking whichever
  perpetual `limit 1` returned, which is an order in the wrong instrument waiting
  to happen.
- **0058** stops describing the reply altogether. `queue_delta_checks` records
  the request id `net.http_get` returns — 0050 discarded it with `perform` — into
  `delta_ticker_requests`, and the engine reads the reply to *that id*. A reply
  nobody here asked for cannot be picked, whatever it contains and whoever adds
  the next poller.

> Still outstanding: `queue_strategy_checks` pulls the whole exchange once a
> minute and the auto strategy's engine reads replies the same loose way. It
> deserves the same request-id treatment.

**The habit worth naming.** Every one of these applied cleanly and failed hours
later, because plpgsql resolves function and column names when a statement first
*executes*, not when the function is created. `check_function_bodies` will not
catch a missing table column, a missing function, or an ambiguous overload. So
0056 onwards each end with a `do` block that resolves every name the engine uses
— columns, functions, signatures — at apply time, which is the only cheap place
to find out.

#### The per-strike notional cap

**`max_notional_per_strike`**, default **$95,000**, caps how much the strategy
will stack into any one contract
([`0042`](supabase/migrations/0042_notional_cap_per_strike.sql)):

```
notional at a strike = spot × contract_value × |net_qty|
```

At a spot of 4,341 one lot is $4.34 of notional, so the cap is about **21,880
lots — 21.9 XAUT — per contract**. At `qty = 10` XAUT a leg, that is two sales
into one strike; the third goes somewhere else.

Every sale goes through the same picker, so the cap applies to the daily entry,
the roll replacement and the band correction alike. The price rule is unchanged —
still *the strike quoted closest to `entry_premium`* — the cap only removes
strikes that are already full, so the sale lands on the next-nearest one with
room, on its own.

A sale that does not fit entirely is **trimmed, not skipped**: it sells what the
strike can still take and the next cycle carries on from the strike after it.
Delta keeps being managed, which is the same reason the hold zone went.

Three details:

- **Per contract, not per strike price.** `C-XAUT-4400` and `P-XAUT-4400` get
  $95,000 each — unrelated exposures on opposite sides of spot.
- **The entry stays symmetric.** Both legs are trimmed to the smaller of the two
  rooms rather than selling different sizes; a cap is not a reason to open a
  directional position.
- **Nothing is closed by it.** It governs where new sales go. A strike drifting
  past the cap because spot moved just stops receiving — notional is
  `spot × cv × qty`, and spot is not something the book chose.

`0` turns the cap off.

#### The gamma multiplier

**Delta book only.** The futures book defends the band as typed and does not read
gamma at all — see [The futures hedge](#the-futures-hedge).

On the delta book the band does not have to be a number you type.
**`gamma_multiplier`** derives it from the book's own gamma instead, recomputed
every cycle, and **defaults to 2**
([`0039`](supabase/migrations/0039_delta_gamma_band.sql)):

```
band = ± |Γp| × gamma_multiplier
```

At a net gamma of **0.5** and a multiplier of **2** the band is **−1 to +1**. Let
gamma grow to 0.8 and the band is at ±1.6 on the next pass, with nothing edited.

The reasoning: gamma is the rate Δp itself moves at. A book with twice the gamma
runs through the same delta in half the underlying move, so holding it to a fixed
band means correcting twice as often for behaviour that has not changed. Tying
the two puts the tolerance in units of *how fast will this book breach* rather
than in absolute delta.

> **Read this before switching it on.** It cuts the other way too. Gamma is
> largest where the strikes are nearest the money, so a book being run over gets
> a **wider** tolerance at exactly the moment Δp is moving fastest. That is what
> the rule says and it is deliberate — the band scales with breach speed — but it
> is the opposite of a risk limit. The margin guard below, not this, is what
> bounds the book.

Three details worth knowing:

- **`|Γp|`, not `Γp`.** This strategy only sells, so its gamma is negative; a
  signed band would come out inverted, with `low` above `high`. The sign says
  which way the book is convex, not how wide the tolerance should be.
- **The band is symmetric.** An asymmetric `band_low`/`band_high` — a valid thing
  to type — is not preserved when the multiplier takes over. If you want the band
  off-centre, leave the multiplier at zero.
- **`0` switches it off** and gives you back a band you type in. It is not the
  default — running `0039` puts every delta account on a gamma-derived band, so
  read the warning above before applying it. `band_low`/`band_high` stay live as
  the fallback for the two cases where a derived band would be nonsense: a flat
  book, and a book whose gamma has rounded to nothing. Either gives a width of
  zero, which every non-zero Δp breaches, and the engine would "correct" a book
  it cannot measure.

Gamma is required on the same terms as delta *here*: a leg whose gamma the venue
has not published stands the whole book down for that cycle, exactly as a missing
delta already did. With the multiplier set, a leg silently absent from Γp would
move the band by that leg's entire share. On the futures book that requirement is
lifted, because nothing there reads Γp
([`0045`](supabase/migrations/0045_futures_band_without_gamma.sql)).

On a reload the band reads `—` until it is actually known. Three things land at
different times — the settings row, the first plan, and the greeks Γp is computed
from — and each used to repaint the field with a different pair: the built-in
default, then your saved one, then the derived one. A fallback shown before the
greeks arrive is not the band, it is the band that is about to be replaced, so
the field says nothing rather than something wrong. Nothing trades in that window
either; Δp is unknown for the same reason.

The **Target delta band** control keeps its two boxes either way, so setting a
multiplier does not rearrange the bar — only what fills them changes. Typed while
the numbers are yours; the derived pair, read-only and in brand ink, once gamma is
computing them, with `set 0 to type the band in yourself` under the multiplier as
the way back. The readout shows `Net Γp × multiplier` beside Δp, and the band
meter prints its ends in the same brand ink when gamma is what set them.

#### The margin guard

Every rule above answers to Δp. None of them reads equity, and being sell-only
that eventually bites: the band correction sells a **fresh** leg that nothing ever
pairs off, so each breach with the ITM queue exhausted grows the book. Margin
ratchets up while unrealized losses pull equity down, and the two meet. This is
the one rule that answers to equity instead
([`0031`](supabase/migrations/0031_delta_margin_guard.sql)):

| Blocked margin | What runs |
| --- | --- |
| `> margin_cap_pct` of equity | **Cut only.** Close lots, deepest ITM first, preferring the side whose exit pulls Δp toward the band. Nothing else runs this cycle |
| otherwise | Everything — entries, rolls, band corrections and hedges alike |

Two notes for the futures book. A cut takes lots off **option shorts only**: the
hedge is not a candidate, because closing it would remove the position that is
reducing the book's directional risk, and it has no strike for the walk to order
by. And the hedge is never trimmed to what the cap has left, which the band
correction is. Both are argued in
[The futures hedge](#the-futures-hedge).

There used to be a third row: between `margin_target_pct` and `margin_cap_pct` the
book was frozen against new premium, rolls only. It is gone
([`0041`](supabase/migrations/0041_always_manage_delta.sql)). The intent was sound
— the band correction is the one rule that grows the book with nothing pairing it
off — but what it did in practice was leave Δp outside its band with **no rule able
to act on it**: the ITM queue is only walkable when a short is actually in the
money, so on an all-OTM book the queue is empty, the correction is frozen, and the
engine logs *correction held back* while net delta runs. For a strategy whose
entire job is holding Δp inside a band, that is the one state it must not reach.
Risk is answered at the cap now, by cutting — not by declining to manage delta.

`margin_target_pct` stays, as the **depth** of a cut rather than a gate, and that
is now its most important job: a cut leaves the book at the target, so there is
`cap - target` of headroom before another can fire. Without that gap the
correction would sell, cross the cap, be cut back to just under it and sell again,
churning every cycle. Setting the two equal is what that mistake looks like.

> **The trade-off, plainly.** Between the target and the cap the book now keeps
> selling. That is more premium collected and a delta held where it is meant to
> be; it is also a bigger book, closer to the cap, reached sooner, so cuts fire
> more often than they did — and a cut books a loss. `margin_cap_pct = 0` still
> turns the whole guard off.

Two rules keep the cut and the band correction from trading against each other
([`0043`](supabase/migrations/0043_stop_the_cut_correction_loop.sql)) — a loop
that cost a live account **$2,724 in one morning**, every dollar of it bid-ask
spread, with no market move involved:

- **The cut picks its side off the band's *midpoint*, not off a breach.** Read
  from a breach, the preference was null for every Δp *inside* the band, so the
  cut fell through to "deepest in the money" — whichever leg spot had drifted
  nearest, chosen with no regard for delta. Closing a short put removes positive
  delta, so a put-side cut with Δp already below the middle drove Δp **out** of
  the band, and the correction answered by re-selling the strike the cut had just
  bought back. Against the midpoint the preference is defined at every Δp: below
  it, closing a call raises Δp; above it, closing a put lowers it. On a genuine
  breach the answer is identical to before.
- **The correction is trimmed to what the cap has left.** Sized off Δp alone it
  re-blocked the exact margin the cut had freed, putting the book straight back
  over the cap. It now sells what it can margin and no more, priced per lot the
  same way the cut prices its own.

Together these make the intent above hold: sell freely up to the cap, never
through it, and let the cut answer only the breaches a *price move* causes rather
than the ones the book caused itself. With margin at the cap and Δp outside the
band the correction sells nothing and says so — the book has genuinely run out of
room, which no amount of trading fixes.

Cut lots are rounded **up** — the opposite of every
other size here, because a cut landing a hair above the target has resolved
nothing — and capped at the leg, so the remainder falls to the next cycle and the
next leg. That keeps the realized loss to the smallest one that clears the breach.

It sits **ahead of the expiry check**: closing a leg reads that leg's own quote,
not the expiry the strategy trades, and a settled expiry standing the strategy
down while the book is past its equity is exactly what the guard is for. Only the
session-close flatten outranks it, and that is a strictly larger cut.
`margin_cap_pct = 0` disables it, the way the two bracket marks read zero.

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

#### Where gold was

Trade History carries an **Index Price** column beside the execution price: the
underlying at the instant of the fill, recorded on the row rather than read live,
so it answers the same question on every repaint.

`fills.spot_at_fill` has held it since `0001` for everything routed through
`execute_fill` — manual trades, and every leg either strategy opens or closes.
What it did *not* hold was the triggered closes, which write a fill directly and
passed a literal null: every take-profit, every stop, the auto strategy's window
close, and the futures liquidation that no longer fires. On a delta account running the default
0.70 take-profit that is a large share of the ledger.
[`0040`](supabase/migrations/0040_spot_on_every_fill.sql) threads the spot each
of those three callers already holds into the fill, and computes the `notional`
that was likewise being written as zero for want of it.

Settlement stays blank, and is now the only thing that is: it is driven by the
option's own settlement price off the product, and the underlying at that instant
is not in that payload. Nothing is backfilled — the spot at a fill that has
already happened is not recoverable from anything this database holds, and
inventing it from today's price would be worse than the dash.

#### Why it did that

Every leg the engine touches carries its own reason, on the row it belongs to
([`0035`](supabase/migrations/0035_reason_on_the_row.sql)):

| Where | Column | Answers |
| --- | --- | --- |
| Positions | **Entry Reason** | Why this leg is on the book |
| Trade History | **Exit Reason** | Why this leg was closed |
| Trade History | **Index Price** | Where gold was when it filled |

Both read the same shape of line — the rule that ran, where it was aiming, the
spot it was priced at, and net portfolio delta either side of the action:

```
Rolled further out — band breach (target -0.60) · spot $4243.10 · Δp -1.35 → -0.62
Bought futures — band breach (target -0.60) · spot $4622.13 · Δp -1.35 → -0.60
Margin cut — loss booked · spot $4251.80 · Δp -1.90 → -1.20
Take-profit hit · spot $4243.10 · Δp -0.62 → -0.30
```

The size is not in the sentence and does not need to be — it is on the row the
sentence is written to, and the pair of deltas says what the trade achieved.

One rule had to change for the hedge. Which fills count as *exits* was decided by
`side = 'buy' or realized_pnl <> 0`, which is right on a sell-only option book
where the only way out is to buy back. A hedge opens with a buy as often as with a
sell, so a **perpetual** fill is an exit when it realized something and not
otherwise. The one case that leaves blank is a hedge unwound at exactly its entry
price, which books nothing and reads as an opening trade; a blank Exit Reason
beats a wrong one.

The delta *after* the action is the half that cannot be reconstructed later,
which is the point of recording it: it is measured in the same transaction and
off the same chain snapshot as the reading before, so the pair is a clean
before-and-after of one action rather than two readings taken at different
prices. A cut, a flatten and a bracket carry no target — they answer to margin or
to the option's own price, and have no delta they are aiming for.

An **opening** fill leaves Exit Reason blank on purpose. Its reason is not lost —
it is on the position it opened, which is where "why do I hold this" gets asked.
Under a column headed Exit Reason it would be an answer to a different question.

The take-profit and the stop write their reason the same way
([`0034`](supabase/migrations/0034_delta_tpsl_remarks.sql)). They are armed by the
delta engine but fired by `apply_tpsl_triggers`, the bracket sweep shared with the
other two books, so without that a leg would leave the book with nothing to say
why.

Both engine books, as of
[`0047`](supabase/migrations/0047_futures_exit_reason.sql). That sweep wrote the
sentence only for `kind = 'delta'`, which was the only engine book when `0034`
was written — so on the **futures** account the brackets closed the leg, booked
the P&L and left Exit Reason blank, on exactly the rows that book leaves through
most often: a hedged strangle is held to its two marks rather than rolled. The
test is now `kind in ('delta', 'futures')` and nothing else about the path
changed. Rows that already closed keep their dash — the Δp either side of a close
from last week is not recoverable, and a sentence built from today's book would
be a fabrication on a real trade.

> **Cycles that trade nothing write nothing.** An entry held back by margin, a Δp
> that cannot be trusted because a greek has not arrived, a breach worth less than
> one contract — there is no row to hang those on, and they are already on screen:
> the strategy bar's `Next` line recomputes the same rules live, for a paused
> strategy as well as a running one. Each also writes a `raise log`, which is the
> record when the engine itself is the suspect. A `delta_remarks` table briefly
> kept a history of them and was dropped
> ([`0036`](supabase/migrations/0036_drop_delta_remarks.sql)) — a table, a policy,
> a realtime feed and a retention sweep to duplicate two text columns and one line
> of the readout.

### The perpetual, as the hedge instrument

The one non-option XAUT contract Delta lists:

```
XAUTUSD   perpetual future   0.001 XAUT per lot   tick 0.01
          IM 1%   MM 0.5%   up to 100x   funding every 8h
```

Nobody trades it by hand any more. It is what the **Futures Strategy** page
corrects its delta with, one trade per breach — see
[The futures hedge](#the-futures-hedge) for the rule, and the rest of this section
for the contract's own mechanics, all of which are simulated
([`0038`](supabase/migrations/0038_futures.sql)) and all of which now apply to a
hedge on a strategy book:

**Leverage.** Margin is `notional / leverage`, floored at the contract's own 1%,
and **both sides post it**. That is the opposite of the option book, where a long
has already paid its maximum loss with the premium and the venue asks nothing
further. The leverage rides on the order and is stored on the position, because it
is what margins that position from then on — `hedge_leverage` on the strategy bar
is what the engine sends, and `delta_account_margin` prices the resulting leg the
same way ([`0044`](supabase/migrations/0044_futures_delta_hedge.sql)).

**Funding.** A perpetual never settles; every eight hours (00:00, 08:00 and 16:00
UTC — 05:30, 13:30 and 21:30 IST) the two sides pay each other instead. It is
charged to whatever account holds the position, which now means a strategy book:

```
payment = mark × contract_value × |net_qty| × funding_rate / 100
```

A positive rate means longs pay shorts. The strategy bar shows what the hedge on
the book will pay at the next boundary, and when that is. Cash moves server-side
on a cron, against a ledger keyed on `(account, symbol, funding_time)` so a re-run
cannot double-charge. Only positions open *before* the boundary are billed — and
since the strategy flattens at every session close, a hedge is billed only for the
boundaries it was actually carried through.

**Liquidation — and why nothing is liquidated any more.**
[`0038`](supabase/migrations/0038_futures.sql) liquidates a `futures` account
whose equity falls under maintenance margin, all at the mark, and it is still
there. It can no longer fire, and the reason is worth stating precisely rather
than being left to look like an oversight: the pass skips any account holding a
leg with no fresh *perpetual* mark, and every option leg is such a leg. A book
that is a short strangle carrying a hedge is therefore never tested — which is
the same answer the delta book has always got, and the reason it is acceptable
here is that the margin guard, not a liquidation, is what bounds both books.

What went with it: the client-side liquidation-price estimate and the perpetual
variant of the positions table. The hedge is one row among option legs now, read
by the same columns — its Delta cell shows exactly its own size, its Gamma, Vega
and Theta zero, and its Entry Reason the sentence the engine wrote when it opened
it.

Take-profit and stop-loss still work on a perpetual set by hand from the panel.
The bracket engine had decided direction with
`(contract_type = 'call_options') = long`, which reads a perpetual as a put — a
long XAUTUSD would have taken profit on the index *falling*.
[`0038`](supabase/migrations/0038_futures.sql) splits the case so that a
non-option is simply bullish when long. The engine's own hedge carries no bracket
at all; see [The futures hedge](#the-futures-hedge).

### Downloading a day

Every day group in **Trade History** carries a **↓ Excel** button. It writes that
IST day's fills as a CSV — Excel opens it directly — with the columns in the same
order as [`scripts/export_delta_day.sql`](scripts/export_delta_day.sql), so the
two routes cannot disagree about the same day.

It **queries the database for the day** rather than exporting what the table is
showing, and that is the point. The panel loads the newest 1,000 fills for the
account; a book making hundreds a day will have days that do not fit, and the
oldest visible group is marked `151+ fills` when so. The button ignores all of
that and takes the whole day.

Rows come out oldest-first — the opposite of the panel — because a ledger someone
reads down and reconciles wants the session in the order it happened. A `TOTAL`
row closes the file, with the fill count, the net premium flow, fees and realized
P&L. The file carries a UTF-8 BOM, without which Excel reads the `Δ` in every
engine reason line as mojibake.

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

The three counts come from `account_counts()`
([`0063`](supabase/migrations/0063_counts_are_counted_not_fetched.sql)), which
counts in the database off the `account_id` indexes. The panel used to fetch
every row of `positions`, `fills` and `orders` and count them in the browser —
the whole ledger across the wire to render three two-digit numbers, and wrong
without warning if PostgREST ever capped one of those responses. The function
runs as the caller, so RLS scopes it to your own books exactly as the queries it
replaced were scoped.

---

## Known approximations

- **Short-option margin** is `im% x spot + premium` per lot, where `im%` is the
  contract's own published `initial_margin` (1% for an XAUT option) rather than a
  rate of ours. Still approximate in two ways: Delta raises the rate with order
  size via `initial_margin_scaling_factor`, which isn't modelled, and accounts on
  portfolio rather than isolated margin are floored at
  `max(5% x premium, OM% x notional)`, which can bind higher. Long options are
  exact — risk is capped at the premium paid.
- **Nothing is liquidated.** No book here force-closes a losing position. The
  liquidation pass in [`0038`](supabase/migrations/0038_futures.sql) survives but
  cannot fire on either strategy book, since it skips accounts holding legs with
  no perpetual mark and every option leg is one — see *The perpetual, as the hedge
  instrument*. What bounds these books is the delta strategy's margin guard, which
  closes option shorts over the cap. A hedge carried at 100x through a large
  adverse move is therefore carried, not taken; its loss shows in equity, and the
  option legs it was hedging are what the guard trims.
- **The hedge blocks margin it is never trimmed for.** Deliberate — see *The
  futures hedge* — but the consequence is worth naming: on a book already at its
  margin cap, a hedge can push blocked margin above the cap, and the next cycle's
  cut will answer by closing an option short rather than by shrinking the hedge.
- **Funding is charged on an eight-hour boundary, not accrued continuously.** A
  position opened a minute after 08:00 UTC pays nothing until 16:00, which is how
  the venue works; but the pass that bills it runs on a five-second cron, so the
  mark it is priced at can be seconds past the boundary rather than exactly on
  it. `annualized_funding` on the product is ignored — the live `funding_rate`
  off the ticker is what is charged.
- **The hedge pays no fee.** Like every other engine trade, `delta_hedge` passes
  `0` to `execute_fill`, so a hedged book overstates its P&L by the taker
  commission a real one would pay on each hedge trade. It does pay the spread.
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
  lib/deltaStrategy.ts     Delta strategy: Δp, band, ITM queue, hedge sizing, cycle plan
  engine/paper.ts          Fees, margin, bid/ask P&L, order validation, crossing
  hooks/useAuth.ts         Session
  hooks/usePolling.ts      Visibility-gated intervals, debounced realtime handlers
  hooks/useAccounts.ts     Paper accounts CRUD + selection, per kind
  hooks/useTrading.ts      Positions/orders/fills, order placement, fill engine
  hooks/useAutoStrategy.ts Auto strategy settings (engine is server-side)
  hooks/useDeltaStrategy.ts Delta strategy settings + readout (engine is server-side)
  components/controls.tsx  Shared strategy-bar widgets: select, time picker, switch
  components/              Login, TopBar, OptionChain, OrderTicket, BottomPanel,
                           StrategyTab, DeltaStrategyTab, AdminPanel
supabase/migrations/       Schema, RLS, execute_fill, settlement, TP/SL,
                           both strategy engines, and the perpetual's funding cron
docs/                      HLD, LLD, setup
```

`lib/deltaStrategy.ts` holds the strategy's logic with no React and no I/O, so
the band maths and the sizing can be reasoned about on their own. It is also
what the browser uses to render the live readout — the executing copy is the SQL
in `0012`, as amended through `0044`, and the two must be kept in step by hand.

`DeltaStrategyTab` draws both strategy bars: one `mode` prop swaps the roll
controls and readouts for the hedge's leverage, size and funding. `FuturesTab` is
gone — there is no longer a page that trades a perpetual by hand.

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
- **The gamma-derived band** in `lib/deltaStrategy.ts` — 21 assertions: the
  worked case (Γp 0.5 × 2 → ±1), the magnitude rule on a short book's negative
  gamma, both fallbacks (zero gamma and unknown gamma), the breach and landing
  target read against a derived band rather than the typed one, and `planCycle`
  end to end on a two-leg book — including a missing gamma standing the book
  down. Fixtures are synthetic.
- **Delta strategy logic** in `lib/deltaStrategy.ts` — 65 assertions covering the
  document's 5.2 worked example end to end, the band and landing rules, the
  corrective sides, the ITM queue, and the session clock read through the zone
  rather than a fixed offset. Fixtures are synthetic.
- **Delta strategy daily entry, live.** Armed against the real chain it built the
  113-symbol snapshot from the feed and sold its symmetric pair — two orders, two
  open legs, `entered_day` set.
- **The futures hedge logic** in `lib/deltaStrategy.ts` — 31 assertions: the
  signed sizing rule and its rounding, the perpetual entering Δp at delta 1 and Γp
  at zero without any published greek, a hedged book reading as inside the band,
  an over-large hedge reading as a breach of the *other* edge and being sold back
  by the incremental size, a hedge-only book after the options have gone, a
  sub-lot breach trading nothing, the cut declining to take the hedge, the close
  flattening it with everything else, and options mode never producing a hedge.
  Now 43 with the gamma rules: a futures book ignoring `gamma_multiplier = 2` and
  reporting no Γp, hedging a book whose leg has no published gamma, the options
  book still standing down on that same book, and each saying which greek it is
  waiting for. Fixtures are synthetic.
- **The mixed ticker query the engine now makes.** `contract_types=call_options,
  put_options,perpetual_futures&underlying_asset_symbols=XAUT` answers live with
  126 options and `XAUTUSD` in one array — and `XAUTUSD` comes back *first*, with
  `"greeks": null`. That is why the engine's reply guard still works unchanged: it
  tests that the first element carries a `greeks` **key**, which a null-valued one
  does.
- **The build.** `tsc -b` and the production bundle are clean with the futures page
  removed, the `variant` prop gone from `BottomPanel`, and the two liquidation
  helpers deleted from `engine/paper.ts`.
- **The auto strategy's flip to buying**, in `lib/strategy.ts` — 20 assertions: the
  stop landing below the entry and reading null at 0 and at 100 or more, the trail
  landing below the last close and the greater of the two being what is armed, the
  target landing above the entry with no ceiling, and the signal itself unchanged
  (red → call, green → put, flat → nothing). Fixtures are synthetic.

Not yet exercised:

- **Either strategy past its daily entry.** The roll, exit-only and
  band-correction paths, and now the futures hedge, have run against synthetic
  fixtures only, never against a live book — partly because `N = 1` cannot breach
  the band (see above). These are the paths that place and unwind real size; treat
  the first live breach as the actual test.
- **Everything in [`0044`](supabase/migrations/0044_futures_delta_hedge.sql) and
  [`0045`](supabase/migrations/0045_futures_band_without_gamma.sql) that runs in
  the database**, for the same reason as `0038` below: neither has been executed
  against a live Postgres. That covers the perpetual's row in the chain snapshot,
  `delta_hedge` and the order it writes, the perpetual arm of
  `delta_account_margin`, the two new reason lines, the futures branch of the
  engine, and the per-mode band and stand-down. The file is balanced and self-consistent on inspection — dollar quoting,
  `if`/`end if`, loops and blocks all check out — which is not the same as having
  run. Apply it and watch one live breach on a small book before trusting it.
- **A hedge placed end to end.** Nothing has yet written a `perpetual_futures`
  order from the engine, so the first one is what proves the nullable
  `strike_price`, the `'PERP'` expiry label and the leverage column all land as
  intended — the same three things `0038` was waiting on a manual trade to prove.
- **Everything in [`0046`](supabase/migrations/0046_auto_strategy_buys.sql)**, on
  the same terms: not run against a live Postgres. That covers the buy side of
  `apply_strategy`, the renamed `max_premium` column and its two swapped
  percentage bounds, the inverted brackets, and the long-side filters in
  `apply_trail_stops` and `queue_trail_checks`. The last of those is the one worth
  watching: it queues the 1-minute candles the trail moves on, and had it been
  left filtered to shorts the trailing stop would simply never have moved, with
  nothing in the logs to say so.
- **The gamma band in the database.** [`0039`](supabase/migrations/0039_delta_gamma_band.sql)
  has not been run against a live Postgres, for the same reason `0038` has not:
  migrations are applied by hand in the Supabase SQL editor. The TypeScript copy
  of the rule is tested; the SQL copy that actually trades is not.
- **The two copies of the delta logic can drift.** `lib/deltaStrategy.ts` draws
  the readout and `0012` does the trading. They implement the same rules twice,
  in two languages, with only the TypeScript side under test.
- **The write path inside `execute_fill`** — the `insert into fills` and the
  positions upsert. Postgres only plans statements inside a PL/pgSQL function on
  first execution, so these are validated by the first real trade rather than by
  deployment. If anything in the schema misbehaves, look here first.
- Partial fills against quoted size — not implemented (see *Known
  approximations*).
- **Everything in [`0038`](supabase/migrations/0038_futures.sql) that runs in the
  database.** The migration has not been executed against a live Postgres: no
  local instance exists in this project, and it is applied by hand in the
  Supabase SQL editor like every migration before it. That covers the funding
  cron, the leverage column travelling from order to position through
  `execute_fill`, and the bracket-direction fix. Its liquidation cron is now
  unreachable by construction and is not worth testing; the funding cron is what
  charges a hedge three times a day, and is.

## License

Proprietary — Copyright (c) 2026 Vitti Capital, all rights reserved. See
[LICENSE](LICENSE). This project simulates trading only and is not financial advice.
