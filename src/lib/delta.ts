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

export type ContractType = 'call_options' | 'put_options'

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
  product_specs: { premium_commission_rate?: number } | null
  state: string
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
 * Fetch every live option product for the underlying and group it by expiry.
 * Expiries come back sorted nearest-first.
 */
export async function fetchExpiries(underlying = UNDERLYING): Promise<Expiry[]> {
  const all = await getJson<Product[]>(
    '/v2/products?contract_types=call_options,put_options&states=live&page_size=1000',
  )
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
  const all = await getJson<Ticker[]>('/v2/tickers?contract_types=call_options,put_options')
  return all.filter((t) => parseSymbol(t.symbol)?.underlying === underlying)
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
