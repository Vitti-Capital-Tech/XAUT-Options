# XAUT Options — Paper Trading Terminal

A Delta-Exchange-style derivatives terminal for **XAUT** (Tether Gold). Live
option chain, click-to-trade, positions, open orders and trade history — plus
two automated strategies that run on a schedule and the XAUT perpetual future —
with every order simulated. **No order ever reaches the exchange.**

Four pages, each trading its own book:

| Page | Account kind | What it does |
| --- | --- | --- |
| **Option Chain** | `manual` | Click-to-trade the live chain by hand |
| **Auto Strategy** | `auto` | Sells one option per closed 1h candle — a call on a red bar, a put on a green |
| **Delta Strategy** | `delta` | The delta-band strategy from `Gold_Options_Delta_Strategy.docx` |
| **Futures** | `futures` | The XAUTUSD perpetual, long or short by hand, with leverage, funding and liquidation |

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
with a stop read off `stop_loss_pct` on the mark.

The stop has two halves, and the **tighter one is armed**
([`0020`](supabase/migrations/0020_auto_strategy_stop_pct.sql),
[`0037`](supabase/migrations/0037_auto_trailing_stop.sql)). Both are a percent of
the premium — the number a premium seller actually thinks in — and both are
watched on the option's own mark. They differ only in what they measure from:

```
entry stop = avg_entry_price      × (1 + stop_loss_pct  / 100)     fixed
trail stop = last 1m candle close × (1 + trail_stop_pct / 100)     re-read every minute

stop_loss  = least(entry stop, trail stop)
```

At `stop_loss_pct = 100` a $4 short stops at $8, giving back exactly the premium —
the 2× the strategy was hardcoded to before this was a setting. `50` stops it at
$6; `0` arms no fixed stop.

The trailing half measures the same share against what the option is *trading at
now*, so as a short goes your way the stop follows the premium down and locks the
gain in. On that same $4 short with both set to 100:

| Premium now | Entry stop | Trail stop | Armed |
| --- | --- | --- | --- |
| 4.00 | 8.00 | 8.00 | 8.00 |
| 2.00 | 8.00 | 4.00 | **4.00** |
| 1.00 | 8.00 | 2.00 | **2.00** |
| 3.00 | 8.00 | 6.00 | **6.00** |

> Read that last row before switching it on. `least` is taken of the two levels
> **as they stand this minute**, so the trail follows the premium back up as well
> as down and the stop can loosen again — never past the entry stop, which is what
> bounds the worst case. Keep an entry stop set as the outer limit even when the
> trail is doing the work.

The minute close is Delta's own 1-minute candle for that option symbol, not the
mark: `apply_trail_stops` reads the most recently *closed* bar every 30 seconds
and moves the level only when it actually changes. `trail_stop_pct = 0` switches
the trailing half off, which is the default, so nothing changes for an existing
account until the number is moved.

`take_profit_pct` is the mirror — a percent of the premium **kept**
([`0021`](supabase/migrations/0021_qty_and_take_profit.sql)):

```
take_profit = avg_entry_price × (1 − take_profit_pct / 100)
```

`70` buys a $4 short back at $1.20. Default `0`, so no take-profit is armed until
you set one. Both levels are read off `avg_entry_price`, so adding to a symbol
re-bases them onto the blended entry rather than leaving them pinned to the first
fill.

The window is both ends of the day. Inside it the strategy sells; once past
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
new one is picked, rather than selling a contract nobody chose. The tab marks a
settled selection so the reason it stopped is on screen.

With no date chosen, `expiry_rule` still applies
([`0018`](supabase/migrations/0018_auto_strategy_expiry_rule.sql)). Its default,
**`today`**, sells only the same-day contract on the IST clock and **skips the bar
when there is none**. Two consequences worth knowing:

- XAUT does not list a contract every calendar day (a live set of Mon 10 / Tue 11
  / Fri 14 Aug leaves Wednesday and Thursday with no same-day expiry at all).
- The same-day contract settles at **16:00 UTC = 21:30 IST**, so from 21:30 there
  is nothing same-day left to sell.

On either, an account on `today` stands down and logs why. `nearest` restores the
old behaviour of taking the nearest unsettled expiry whatever its date.

`min_premium` puts a floor under the entry
([`0017`](supabase/migrations/0017_auto_strategy_min_premium.sql)): a bar whose
strike is bid below it is **skipped, not sold**. It vetoes rather than hunting for
a richer strike — the strike is `moneyness`'s to choose, and searching for
whatever clears the floor would quietly override that and could walk the position
deep into the money on a thin day. `0` disables it.

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
| Open (06:00 IST) | Sell one symmetric pair at the strikes nearest `entry_premium`, sized by `qty` in XAUT — the spec's `N`, in XAUT rather than lots ([`0024`](supabase/migrations/0024_drop_pairs_and_fix_reentry.sql)). Both legs fill or neither does; a failed open is retried on the next refresh rather than written off for the day |
| Intraday | Rebuild the ITM queue each cycle, most-ITM first; resolve breaches by partial exit-and-replace |
| Roll budget | Each side gets `max_rolls`; once spent that side is **exit-only** — further triggers close in full, loss booked |
| No ITM legs left | Band-correct with fresh OTM sells in the `band_correction_delta` range |
| Close (22:00 IST) | Flatten everything, stand flat overnight, reset counters |
| Off day | A weekday outside `trade_days` reports the session **closed**, so the same flatten covers it and nothing is opened |
| Margin over `margin_cap_pct` | Stop selling and **cut** instead: close lots, deepest ITM first, on the side whose exit pulls Δp toward the band, down to `margin_target_pct` — loss booked ([`0031`](supabase/migrations/0031_delta_margin_guard.sql)) |

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

Sizing is the document's, both rounded **down** so a correction cannot overshoot:

```
roll:            q = (target_landing - Δp) / (d_itm - d_replacement)
band correction: q = (target_landing - Δp) / d_selected
```

**Δp is measured in contract-deltas** — `Σ(signed lots × option delta)`, with no
contract-value factor. That is the unit the document's own worked example is
written in, and the band is calibrated to the same one.

#### The gamma multiplier

The band does not have to be a number you type. Set **`gamma_multiplier`** above
zero and it is derived from the book's own gamma instead, recomputed every cycle
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
- **`0` is off**, which is the default, so no existing account changes behaviour
  until the number is moved. `band_low`/`band_high` stay live as the fallback for
  the two cases where a derived band would be nonsense: a flat book, and a book
  whose gamma has rounded to nothing. Either gives a width of zero, which every
  non-zero Δp breaches, and the engine would "correct" a book it cannot measure.

Gamma is now required on the same terms as delta: a leg whose gamma the venue has
not published stands the whole book down for that cycle, exactly as a missing
delta already did. With the multiplier set, a leg silently absent from Γp would
move the band by that leg's entire share.

The readout shows `Net Γp × multiplier` beside Δp, and the band meter prints its
ends in the brand ink when gamma is what set them — a number that moves by itself
should not look like one that was typed.

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
| `> margin_target_pct` of equity | **Hold.** No entry, no band correction — but rolls carry on, since a roll closes `q` and re-sells `q` further out and so cannot grow the book |
| otherwise | Unchanged |

The two thresholds are separate so the control cannot flap: one would cut to just
under it, sell, and cut again. Cut lots are rounded **up** — the opposite of every
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

#### Why it did that

Every leg the engine touches carries its own reason, on the row it belongs to
([`0035`](supabase/migrations/0035_reason_on_the_row.sql)):

| Where | Column | Answers |
| --- | --- | --- |
| Positions | **Entry Reason** | Why this leg is on the book |
| Trade History | **Exit Reason** | Why this leg was closed |

Both read the same shape of line — the rule that ran, where it was aiming, the
spot it was priced at, and net portfolio delta either side of the action:

```
Rolled further out — band breach (target -0.60) · spot $4243.10 · Δp -1.35 → -0.62
Margin cut — loss booked · spot $4251.80 · Δp -1.90 → -1.20
Take-profit hit · spot $4243.10 · Δp -0.62 → -0.30
```

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

### Futures

The one non-option XAUT contract Delta lists, traded by hand:

```
XAUTUSD   perpetual future   0.001 XAUT per lot   tick 0.01
          IM 1%   MM 0.5%   up to 100x   funding every 8h
```

One instrument, so there is no chain and no expiry strip — the page is a price
strip and a ticket, with the book beneath it. What makes it different from the
option pages is not the layout but the mechanics, and all three are simulated
([`0038`](supabase/migrations/0038_futures.sql)):

**Leverage.** Margin is `notional / leverage`, floored at the contract's own 1%,
and **both sides post it**. That is the opposite of the option book, where a long
has already paid its maximum loss with the premium and the venue asks nothing
further. The leverage is chosen per order and stored on the position, because it
is what margins that position from then on.

**Funding.** A perpetual never settles; every eight hours (00:00, 08:00 and 16:00
UTC — 05:30, 13:30 and 21:30 IST) the two sides pay each other instead:

```
payment = mark × contract_value × |net_qty| × funding_rate / 100
```

A positive rate means longs pay shorts. The header shows the live rate, who pays
and the countdown; the ticket shows what the position on the book will pay at the
next one. Cash moves server-side on a cron, against a ledger keyed on
`(account, symbol, funding_time)` so a re-run cannot double-charge. Only
positions open *before* the boundary are billed.

**Liquidation.** At 100x a 1% move is the whole margin. The book is
cross-margined, so the test is account-wide rather than a per-position stop:

```
equity = cash + unrealized      maintenance = 0.5% × mark × cv × |qty|
liquidate when equity < maintenance
```

and the whole book closes at the mark, booked as `close_reason = 'liquidation'`.
The estimated liquidation price is on the ticket before the order goes, priced
for the position the order would actually leave behind — not for a flat book —
and in the positions table after it. It reads `—` when there is genuinely no such
price, which is what enough cash against a small position gives you.

The positions table swaps its four greek columns and the Entry Reason for
**Leverage** and **Liq. Price**: a perpetual has no greeks, and nothing on this
page opens a position except the person looking at it. `UPNL %` is return on
margin here rather than on entry value — at 100x, reading a 1% move as "1%" would
understate it by the size of the account.

Take-profit and stop-loss work as they do everywhere else. The bracket engine had
decided direction with `(contract_type = 'call_options') = long`, which reads a
perpetual as a put — a long XAUTUSD would have taken profit on the index
*falling*. [`0038`](supabase/migrations/0038_futures.sql) splits the case so that
a non-option is simply bullish when long.

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
- **No liquidation on the option books.** Nothing force-closes a losing option
  position. The futures book *is* liquidated
  ([`0038`](supabase/migrations/0038_futures.sql)), because a perpetual at 100x
  is unreadable without it — but only to the extent below.
- **Futures liquidation is all-or-nothing and takes no penalty.** Delta unwinds
  a book in steps and deducts a `liquidation_penalty_factor` from what is left of
  the margin; this closes the whole book at the mark and deducts nothing. It is
  conservative in one direction and generous in the other: an account is never
  left alive that the venue would have taken, but one that is taken keeps a
  little more than it would have. The 0.5% maintenance rate is also a constant in
  the migration rather than re-read from the product each pass.
- **Funding is charged on an eight-hour boundary, not accrued continuously.** A
  position opened a minute after 08:00 UTC pays nothing until 16:00, which is how
  the venue works; but the pass that bills it runs on a five-second cron, so the
  mark it is priced at can be seconds past the boundary rather than exactly on
  it. `annualized_funding` on the product is ignored — the live `funding_rate`
  off the ticker is what is charged.
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
                           StrategyTab, DeltaStrategyTab, FuturesTab, AdminPanel
supabase/migrations/       Schema, RLS, execute_fill, settlement, TP/SL,
                           both strategy engines, and the perpetual's funding
                           and liquidation crons
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
- **The futures page renders and prices correctly**, against the live `XAUTUSD`
  feed: notional, both margins, ROE, the funding payment, the leverage ladder and
  the liquidation estimate all agree with the figures computed by hand, the side
  toggle switches the touch it prices against (ask for a long, bid for a short),
  and an order that only reduces exposure asks for no new margin.

Not yet exercised:

- **The delta strategy past its daily entry.** The roll, exit-only and
  band-correction paths have run against synthetic fixtures only, never against
  a live book — partly because `N = 1` cannot breach the band (see above). These
  are the paths that place and unwind real size; treat the first live breach as
  the actual test.
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
  cron, the liquidation cron, the leverage column travelling from order to
  position through `execute_fill`, and the bracket-direction fix. Run it and
  place one small futures trade before trusting any of it.
- **A futures order placed end to end.** The page was verified against the live
  feed but with the order handler stubbed, since signing in to the paper account
  needs the account holder's own credentials. The first real fill is what proves
  the nullable `strike_price`, the `'PERP'` expiry label and the leverage column
  all land as intended.

## License

Proprietary — Copyright (c) 2026 Vitti Capital, all rights reserved. See
[LICENSE](LICENSE). This project simulates trading only and is not financial advice.
