/**
 * Delta Exchange India public market data.
 *
 * Only public endpoints are used — no API key, no signing, and nothing here
 * can place a real order. XAUT options live on the India host specifically;
 * the global api.delta.exchange only lists BTC and ETH options.
 */

export const REST_BASE = 'https://api.india.delta.exchange'
export const WS_URL = 'wss://socket.india.delta.exchange'

/** Underlying we trade. XAUT options are quoted and settled in USD. */
export const UNDERLYING = 'XAUT'
/** Spot index symbol for the underlying, used for the header price and notional. */
export const SPOT_INDEX = '.DEXAUTUSD'
/**
 * The one non-option XAUT contract Delta lists — a perpetual future. Named as a
 * constant rather than discovered, because there is exactly one and a page is
 * built around it: `/v2/products?states=live` returns 46 calls, 46 puts and this.
 */
export const PERP_SYMBOL = 'XAUTUSD'

export type ContractType = 'call_options' | 'put_options' | 'perpetual_futures'

/** A perpetual is the only contract type here without a strike or an expiry. */
export const isPerp = (contractType: string) => contractType === 'perpetual_futures'

export interface Quotes {
  best_bid: string | null
  best_ask: string | null
  bid_size: string | null
  ask_size: string | null
  bid_iv: string | null
  ask_iv: string | null
  mark_iv: string | null
}

export interface Greeks {
  delta: string
  gamma: string
  theta: string
  vega: string
  rho: string
  spot: string
}

/** Shape shared by the REST /tickers response and the WS v2/ticker channel. */
export interface Ticker {
  symbol: string
  product_id: number
  contract_type: ContractType
  strike_price: string
  contract_value: string
  mark_price: string | null
  spot_price: string | null
  quotes: Quotes | null
  greeks: Greeks | null
  mark_iv?: string | null
  /** Open interest in the underlying, and its USD value — the chain shows the USD one. */
  oi: string | null
  oi_contracts: string | null
  oi_value_usd: string | null
  oi_change_usd_6h: string | null
  volume: number | null
  /** 24h traded value in USD — what the chain's Volume column shows. */
  turnover_usd: number | null
  /** Last traded price, plus the session's open/high/low. */
  close: number | null
  open: number | null
  high: number | null
  low: number | null
  /** Percentage change in last traded price over 24h. */
  ltp_change_24h: string | null
  mark_change_24h: string | null
  /**
   * Perpetuals only: the funding rate for the current eight-hour period, as a
   * percentage. Positive means longs pay shorts. Absent on every option.
   */
  funding_rate?: string | null
}

/** The slice of /products we need to price and size an order. */
export interface Product {
  id: number
  symbol: string
  contract_type: ContractType
  strike_price: string
  contract_value: string
  tick_size: string
  settlement_time: string
  taker_commission_rate: string
  maker_commission_rate: string
  /**
   * Initial margin for the contract, as a percentage. Delta publishes it per
   * product: BTCUSD reads '0.5' against a default leverage of 200, which is the
   * check that fixes the unit — 200x is 0.5% margin, so the field is percent and
   * not a fraction. XAUT options read '1', i.e. 1%.
   */
  initial_margin: string
  /** Delta raises the rate with order size. We do not model that — see paper.ts. */
  initial_margin_scaling_factor: string
  /**
   * Maintenance margin, same percent unit as `initial_margin`. XAUTUSD reads
   * '0.5' against an initial of '1' — half the margin gone is a liquidation.
   * Options carry it too, but nothing liquidates an option book here.
   */
  maintenance_margin?: string
  /** Highest leverage the venue will open this contract at. '100' for XAUTUSD. */
  default_leverage?: string
  product_specs: {
    premium_commission_rate?: number
    /** Funding period in seconds on a perpetual — 28800, i.e. eight hours. */
    expiry_interval?: number
  } | null
  /** The venue's own leverage ladder for the contract, as their ticket offers it. */
  ui_config?: { leverage_slider_values?: number[] } | null
  state: string
}

/** Funding period on a perpetual, in seconds. Eight hours unless Delta says otherwise. */
export const fundingIntervalSeconds = (product: Product): number =>
  product.product_specs?.expiry_interval ?? 28800

/** When the current funding period ends — 00:00, 08:00 and 16:00 UTC on XAUTUSD. */
export function nextFundingTime(product: Product, now: Date = new Date()): Date {
  const period = fundingIntervalSeconds(product) * 1000
  return new Date(Math.floor(now.getTime() / period) * period + period)
}

/** A single expiry with its calls and puts, keyed by strike. */
export interface Expiry {
  /** Raw ddmmyy tail from the symbol, e.g. '300726'. */
  label: string
  settlementTime: string
  strikes: number[]
  /** strike -> product */
  calls: Map<number, Product>
  puts: Map<number, Product>
}

// ---------------------------------------------------------------------------
// Symbol helpers
// ---------------------------------------------------------------------------

/** `C-XAUT-4040-300726` -> `{ kind:'C', strike:4040, expiry:'300726' }` */
export function parseSymbol(symbol: string) {
  const parts = symbol.split('-')
  if (parts.length !== 4) return null
  const [kind, underlying, strike, expiry] = parts
  if (kind !== 'C' && kind !== 'P') return null
  return { kind, underlying, strike: Number(strike), expiry }
}

/** ddmmyy -> Date (UTC midnight). Delta expiries settle at 16:00 UTC that day. */
export function expiryToDate(label: string): Date {
  const d = Number(label.slice(0, 2))
  const m = Number(label.slice(2, 4))
  const y = 2000 + Number(label.slice(4, 6))
  return new Date(Date.UTC(y, m - 1, d))
}

const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

/** ddmmyy -> '30 JUL 26' for the expiry tabs. */
export function formatExpiry(label: string): string {
  const d = expiryToDate(label)
  return `${String(d.getUTCDate()).padStart(2, '0')} ${MONTHS[d.getUTCMonth()]} ${String(d.getUTCFullYear()).slice(2)}`
}

export type ExpiryRule = 'today' | 'tomorrow' | 'friday' | 'fixed'

/**
 * The IST calendar date, as a UTC-midnight `Date` so it compares directly with
 * `expiryToDate`.
 *
 * The rules below used to ask `now.getUTCDate()`, which is a different day from
 * IST's between 00:00 and 05:30 IST. `today` and `friday` got away with it —
 * yesterday's contract is already dead by then and the liveness filter drops it,
 * so the rule fell through to the nearest live expiry, which is the right one.
 * `tomorrow` did not: it asks for `>= date + 1`, the UTC date is still
 * yesterday's, and `yesterday + 1` is what IST calls today. A window asking for
 * one day to expiry got zero, and silently — the engine computed the same wrong
 * answer from the same UTC date, so the readout agreed with it.
 *
 * Nothing about the labels changes. An XAUT option settles at 16:00 UTC on its
 * label's date, which is 21:30 IST the same evening, so the label's date already
 * is its IST date. Only the day it is compared against moves.
 *
 * Declared here rather than imported from `deltaStrategy`, which imports this
 * module.
 */
function istToday(now: Date): Date {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Kolkata',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now)
  const at = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? '0')
  return new Date(Date.UTC(at('year'), at('month') - 1, at('day')))
}

/** `YYYY-MM-DD` as a UTC-midnight Date, comparable with `expiryToDate`. */
function dayToDate(day: string): Date | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day)
  if (!m) return null
  return new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])))
}

/**
 * Resolves an expiry from the live chain based on an expiry rule and/or explicit label.
 */
export function resolveTargetExpiry(
  expiries: Expiry[],
  rule: ExpiryRule = 'today',
  explicitLabel?: string | null,
  now: Date = new Date(),
  /**
   * The day `today` / `tomorrow` / `friday` are counted from, as `YYYY-MM-DD`.
   *
   * This is the **session day**, not the calendar day, and on a window that
   * wraps midnight the two are different for half its length: the session day
   * stays the day the window opened, deliberately, so that a 19:01 → 16:30
   * window is one session rather than two half ones.
   *
   * Anchoring on the calendar day meant the rule moved under the session. A
   * window opened Monday evening asking for `tomorrow` sold Tuesday's expiry at
   * the open and then, from IST midnight, called Wednesday's "tomorrow" — so
   * every strike the band correction or an ATM shift sold after midnight was on
   * a different expiry from the book it was correcting. Anchored on the session
   * day, a window trades one expiry from open to close.
   *
   * Omit it and the IST calendar day is used, which is what a book with no
   * windows and a non-wrapping session wants — there the two are the same day.
   */
  anchorDay?: string | null,
): Expiry | null {
  if (expiries.length === 0) return null

  // If an explicit label is chosen and still live in the chain, honour it
  if (explicitLabel && !explicitLabel.startsWith('rule:')) {
    const found = expiries.find((e) => e.label === explicitLabel)
    if (found) return found
    if (rule === 'fixed') return null // Fixed date has settled
  }

  const effectiveRule: ExpiryRule =
    explicitLabel && explicitLabel.startsWith('rule:')
      ? (explicitLabel.replace('rule:', '') as ExpiryRule)
      : rule

  // The day the rules count from: the session's own day where one is given,
  // else the IST calendar day. Same clock as the session and the engine either
  // way — see `istToday` and `anchorDay`.
  const anchor = (anchorDay ? dayToDate(anchorDay) : null) ?? istToday(now)
  const todayTime = anchor.getTime()
  const oneDayMs = 24 * 60 * 60 * 1000

  if (effectiveRule === 'today') {
    const todayExp = expiries.find((e) => expiryToDate(e.label).getTime() === todayTime)
    if (todayExp) return todayExp
    return expiries[0] ?? null
  }

  if (effectiveRule === 'tomorrow') {
    const tomorrowTime = todayTime + oneDayMs
    const tomExp = expiries.find((e) => expiryToDate(e.label).getTime() >= tomorrowTime)
    return tomExp ?? expiries[expiries.length - 1] ?? expiries[0] ?? null
  }

  if (effectiveRule === 'friday') {
    // Weekday of the anchor day, not of the viewer's UTC instant. Built as UTC
    // midnight of that date, so getUTCDay reads it back without a shift.
    const currentDay = anchor.getUTCDay()
    const daysToFriday = (5 - currentDay + 7) % 7
    const targetFridayTime = todayTime + daysToFriday * oneDayMs
    const fridayExp = expiries.find((e) => expiryToDate(e.label).getTime() === targetFridayTime)
    if (fridayExp) return fridayExp
    const afterFriday = expiries.find((e) => expiryToDate(e.label).getTime() >= targetFridayTime)
    return afterFriday ?? expiries[expiries.length - 1] ?? expiries[0] ?? null
  }

  return expiries[0] ?? null
}

/**
 * Choices for Futures Strategy expiry picker — dynamic Today, Tomorrow, Friday
 * options alongside every listed explicit expiry date.
 */
export function futuresExpiryOptions(
  expiries: Expiry[],
  selectedLabel: string | null = null,
  now: Date = new Date(),
): { value: string; label: string }[] {
  const todayExp = resolveTargetExpiry(expiries, 'today', null, now)
  const tomorrowExp = resolveTargetExpiry(expiries, 'tomorrow', null, now)
  const fridayExp = resolveTargetExpiry(expiries, 'friday', null, now)

  const dynamicOptions = [
    {
      value: 'rule:today',
      label: todayExp ? `Today (${formatExpiry(todayExp.label)})` : 'Today (0 DTE)',
    },
    {
      value: 'rule:tomorrow',
      label: tomorrowExp ? `Tomorrow (${formatExpiry(tomorrowExp.label)})` : 'Tomorrow (1 DTE)',
    },
    {
      value: 'rule:friday',
      label: fridayExp ? `Friday (${formatExpiry(fridayExp.label)})` : 'Friday (Weekly)',
    },
  ]

  const listed = expiries.map((e) => ({
    value: e.label,
    label: formatExpiry(e.label),
  }))

  if (
    selectedLabel &&
    !selectedLabel.startsWith('rule:') &&
    !expiries.some((e) => e.label === selectedLabel)
  ) {
    return [
      ...dynamicOptions,
      { value: selectedLabel, label: `${formatExpiry(selectedLabel)} · settled` },
      ...listed,
    ]
  }

  return [...dynamicOptions, ...listed]
}

/**
 * Choices for a strategy's expiry picker — every listed expiry, formatted as the
 * chain's tabs are.
 *
 * A stored expiry that is no longer listed is kept at the top and marked, rather
 * than dropped. It is the reason that strategy has stopped trading, so hiding it
 * would hide the diagnosis; the engine honours a chosen date only while it is
 * listed and unsettled, and never falls through to another.
 */
export function expiryOptions(
  expiries: Expiry[],
  selected: string | null,
): { value: string; label: string }[] {
  const listed = expiries.map((e) => ({ value: e.label, label: formatExpiry(e.label) }))
  if (selected && !expiries.some((e) => e.label === selected)) {
    return [{ value: selected, label: `${formatExpiry(selected)} · settled` }, ...listed]
  }
  return listed
}

/** Whether a stored expiry is still tradeable, i.e. still in the live chain. */
export function expiryIsLive(expiries: Expiry[], selected: string | null): boolean {
  if (!selected) return true // nothing chosen yet — the engine's rule still applies
  if (selected.startsWith('rule:')) return true
  return expiries.some((e) => e.label === selected)
}

// ---------------------------------------------------------------------------
// REST bootstrap
// ---------------------------------------------------------------------------

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${REST_BASE}${path}`)
  if (!res.ok) throw new Error(`Delta ${path} responded ${res.status}`)
  const body = await res.json()
  if (!body?.success) throw new Error(`Delta ${path} returned an unsuccessful payload`)
  return body.result as T
}

/**
 * A list endpoint, with the page checked against the total the venue reports.
 *
 * Delta paginates `/v2/products` and hands back `meta.total_count` alongside an
 * `after` cursor. Asking for a page smaller than the total silently returns a
 * prefix — no error, no flag on the array. This app asked for `page_size=1000`
 * against a live option list of 1079 and lost the last 79, which are the most
 * recently listed contracts: exactly the newly opened strikes a chain most needs
 * to show. Nobody would have seen it, because a chain missing a strike looks
 * exactly like a chain whose venue has not listed one.
 *
 * Now that every call is scoped to one underlying the totals are far inside the
 * page — 159 against 1000 — so this should never fire. It is here because the
 * shape of the failure is invisible, not because it is expected: a venue listing
 * more contracts is a normal thing to happen, and it should say so rather than
 * quietly draw a short chain.
 */
async function getList<T>(path: string): Promise<T[]> {
  const res = await fetch(`${REST_BASE}${path}`)
  if (!res.ok) throw new Error(`Delta ${path} responded ${res.status}`)
  const body = await res.json()
  if (!body?.success) throw new Error(`Delta ${path} returned an unsuccessful payload`)

  const rows = (body.result ?? []) as T[]
  const total = Number(body?.meta?.total_count)
  if (Number.isFinite(total) && total > rows.length) {
    console.warn(
      `Delta ${path} returned ${rows.length} of ${total} rows — the page is short and the ` +
        `rest were dropped. Raise page_size or follow meta.after.`,
    )
  }
  return rows
}

/**
 * Fetch every live option product for the underlying and group it by expiry.
 * Expiries come back sorted nearest-first.
 */
export async function fetchExpiries(underlying = UNDERLYING): Promise<Expiry[]> {
  // Scoped to the underlying at the venue, not here. Unfiltered this is every
  // option listed on the exchange — 1079 products, 58 KB gzipped, once a minute
  // — of which 159 are ours. It also overflowed the page: see `getList`.
  //
  // The server-side engines have asked this way since 0050; only the browser was
  // still pulling the whole exchange to throw nine tenths of it away.
  const all = await getList<Product>(
    `/v2/products?contract_types=call_options,put_options&states=live&page_size=1000` +
      `&underlying_asset_symbols=${encodeURIComponent(underlying)}`,
  )
  // Kept even though the venue now filters: it is also the symbol-shape check,
  // and it is what makes a surprising row from the API a skipped row rather than
  // a crash in `parseSymbol(...)!` below.
  const mine = all.filter((p) => {
    const parsed = parseSymbol(p.symbol)
    return parsed?.underlying === underlying
  })

  const byLabel = new Map<string, Expiry>()
  for (const p of mine) {
    const parsed = parseSymbol(p.symbol)!
    let exp = byLabel.get(parsed.expiry)
    if (!exp) {
      exp = {
        label: parsed.expiry,
        settlementTime: p.settlement_time,
        strikes: [],
        calls: new Map(),
        puts: new Map(),
      }
      byLabel.set(parsed.expiry, exp)
    }
    if (parsed.kind === 'C') exp.calls.set(parsed.strike, p)
    else exp.puts.set(parsed.strike, p)
  }

  for (const exp of byLabel.values()) {
    // Union of call and put strikes — a strike may legitimately have only one leg.
    exp.strikes = [...new Set([...exp.calls.keys(), ...exp.puts.keys()])].sort((a, b) => a - b)
  }

  return [...byLabel.values()].sort(
    (a, b) => expiryToDate(a.label).getTime() - expiryToDate(b.label).getTime(),
  )
}

/** Snapshot of all option tickers for the underlying, to paint the chain immediately. */
export async function fetchTickers(underlying = UNDERLYING): Promise<Ticker[]> {
  // Same filter, same reason: 1079 tickers at 219 KB gzipped against 159 at 32 KB.
  const all = await getList<Ticker>(
    `/v2/tickers?contract_types=call_options,put_options` +
      `&underlying_asset_symbols=${encodeURIComponent(underlying)}`,
  )
  return all.filter((t) => parseSymbol(t.symbol)?.underlying === underlying)
}

/**
 * The perpetual's contract, fetched by symbol rather than by filtering the
 * product list. One instrument, one request — and it keeps the futures page
 * independent of the chain's bootstrap, which is a much larger call that can
 * fail on its own schedule.
 */
export async function fetchPerp(symbol = PERP_SYMBOL): Promise<Product> {
  return getJson<Product>(`/v2/products/${symbol}`)
}

/** The perpetual's opening snapshot, so the page has a price before the socket. */
export async function fetchPerpTicker(symbol = PERP_SYMBOL): Promise<Ticker> {
  return getJson<Ticker>(`/v2/tickers/${symbol}`)
}

// ---------------------------------------------------------------------------
// Candle history
// ---------------------------------------------------------------------------

/** One OHLC bar. `time` is the bar's open, in Unix seconds; a 1h bar covers
 *  `[time, time + 3600)`. Delta serves the index with no volume. */
export interface Candle {
  time: number
  open: number
  high: number
  low: number
  close: number
  volume: number | null
}

/**
 * The candle history the strategy reads. We chart the spot index the header
 * already tracks (`.DEXAUTUSD`) rather than the perpetual, so a green bar here
 * means the very price shown up top rose over the hour — the two never disagree.
 * Delta returns newest-first; we sort oldest-first so `.at(-1)` is the latest.
 */
export async function fetchCandles(
  resolution: string,
  start: number,
  end: number,
  symbol: string = SPOT_INDEX,
): Promise<Candle[]> {
  const q = `resolution=${resolution}&symbol=${encodeURIComponent(symbol)}&start=${start}&end=${end}`
  const rows = await getJson<Candle[]>(`/v2/history/candles?${q}`)
  return [...rows].sort((a, b) => a.time - b.time)
}

// ---------------------------------------------------------------------------
// WebSocket stream
// ---------------------------------------------------------------------------

type StreamEvents = {
  ticker: (t: Ticker) => void
  spot: (price: number) => void
  status: (s: 'connecting' | 'live' | 'reconnecting') => void
}

/**
 * Live ticker stream with reconnect.
 *
 * Subscriptions are swapped as the user changes expiry rather than subscribing
 * to every strike at once — one expiry is ~40 symbols instead of ~150, which
 * keeps the message rate and the re-render load down. Symbols belonging to open
 * positions are pinned in by the caller so their P&L keeps ticking while the
 * user browses a different expiry.
 */
export class MarketStream {
  private ws: WebSocket | null = null
  private symbols: string[] = []
  private handlers: Partial<StreamEvents> = {}
  private reconnectAt = 0
  private reconnectTimer: number | null = null
  private watchdog: number | null = null
  private closed = false

  on<K extends keyof StreamEvents>(event: K, fn: StreamEvents[K]) {
    this.handlers[event] = fn
    return this
  }

  connect() {
    this.closed = false
    this.open()
  }

  /** Replace the subscribed symbol set. Cheap to call on every expiry switch. */
  setSymbols(symbols: string[]) {
    const next = [...new Set(symbols)].sort()
    if (next.join(',') === this.symbols.join(',')) return

    const previous = this.symbols
    this.symbols = next

    if (this.ws?.readyState === WebSocket.OPEN) {
      const gone = previous.filter((s) => !next.includes(s))
      if (gone.length) this.send({ type: 'unsubscribe', payload: { channels: [{ name: 'v2/ticker', symbols: gone }] } })
      const added = next.filter((s) => !previous.includes(s))
      if (added.length) this.send({ type: 'subscribe', payload: { channels: [{ name: 'v2/ticker', symbols: added }] } })
    }
  }

  close() {
    this.closed = true
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer)
    if (this.watchdog) clearInterval(this.watchdog)
    this.ws?.close()
    this.ws = null
  }

  private send(msg: unknown) {
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(msg))
  }

  private open() {
    this.handlers.status?.(this.reconnectAt ? 'reconnecting' : 'connecting')
    const ws = new WebSocket(WS_URL)
    this.ws = ws

    let lastMessage = Date.now()

    ws.onopen = () => {
      this.reconnectAt = 0
      lastMessage = Date.now()
      this.handlers.status?.('live')
      // Heartbeats let us tell "quiet market" apart from "socket silently died".
      this.send({ type: 'enable_heartbeat' })
      this.send({
        type: 'subscribe',
        payload: {
          channels: [
            { name: 'v2/ticker', symbols: this.symbols },
            { name: 'spot_price', symbols: [SPOT_INDEX] },
          ],
        },
      })
    }

    ws.onmessage = (event) => {
      lastMessage = Date.now()
      let msg: any
      try {
        msg = JSON.parse(event.data)
      } catch {
        return
      }
      if (msg.type === 'v2/ticker') this.handlers.ticker?.(msg as Ticker)
      else if (msg.type === 'spot_price' && typeof msg.price === 'number') this.handlers.spot?.(msg.price)
    }

    ws.onclose = () => {
      if (this.ws === ws) this.scheduleReconnect()
    }
    ws.onerror = () => ws.close()

    if (this.watchdog) clearInterval(this.watchdog)
    this.watchdog = setInterval(() => {
      // Heartbeat cadence is ~30s; 45s of nothing means the socket is stale.
      if (Date.now() - lastMessage > 45_000 && this.ws === ws) ws.close()
    }, 10_000) as unknown as number
  }

  private scheduleReconnect() {
    if (this.closed) return
    this.ws = null
    if (this.watchdog) clearInterval(this.watchdog)
    this.handlers.status?.('reconnecting')
    // Exponential backoff, capped at 15s.
    const delay = Math.min(15_000, 1_000 * 2 ** this.reconnectAt)
    this.reconnectAt += 1
    this.reconnectTimer = setTimeout(() => this.open(), delay) as unknown as number
  }
}
