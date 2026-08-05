import { useCallback, useEffect, useRef, useState } from 'react'
import { fetchCandles, type Candle, type Expiry, type Product } from '../lib/delta'
import type { PlaceOrderArgs } from './useTrading'
import type { PositionRow, Side } from '../engine/paper'
import {
  DEFAULT_CONFIG,
  candleColor,
  inWindow,
  lastClosedCandle,
  resolveContract,
  sideFor,
  type CandleColor,
  type ResolvedContract,
  type StrategyConfig,
} from '../lib/strategy'

const POLL_MS = 30_000
const LOOKBACK_SEC = 8 * 3600

// A trade the bot fired sets `open`; the pair we track so a later signal can
// flip it. Persisted per account so a reload does not forget an open bot trade.
interface BotPosition {
  symbol: string
  side: Side
}

export type LogKind = 'trade' | 'skip' | 'info' | 'error'
export interface LogEntry {
  id: number
  at: number
  kind: LogKind
  text: string
}

// --- persistence ----------------------------------------------------------
const CONFIG_KEY = 'delta.strategy.config'
const armedKey = (id: string) => `delta.strategy.armed.${id}`
const actedKey = (id: string) => `delta.strategy.lastActed.${id}`
const trackedKey = (id: string) => `delta.strategy.tracked.${id}`

function readJSON<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}
function writeJSON(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    /* private mode / quota — the bot still runs this session, just forgets on reload */
  }
}

export interface StrategyApi {
  config: StrategyConfig
  setConfig: (patch: Partial<StrategyConfig>) => void
  armed: boolean
  setArmed: (on: boolean) => void

  /** Live readout, recomputed every poll and every spot tick. */
  latestClosed: Candle | null
  color: CandleColor | null
  signalSide: Side | null
  target: ResolvedContract | null
  inWindowNow: boolean
  marketLive: boolean
  lastFetchAt: number | null

  log: LogEntry[]
  /** Fire the current signal now, ignoring the window and the once-per-bar
   *  guard — for testing the wiring without waiting for the top of the hour. */
  runNow: () => void
}

interface Deps {
  accountId: string | null
  expiry: Expiry | null
  spot: number
  positions: PositionRow[]
  productsBySymbol: Map<string, Product>
  placeOrder: (args: PlaceOrderArgs) => Promise<unknown>
  closePosition: (pos: PositionRow, product: Product) => Promise<void>
}

/**
 * The auto-strategy engine. Polls the spot index's 1h candles, and once armed,
 * places one market lot on each freshly-closed bar whose colour and the chosen
 * bias call for a trade — inside the time window, and holding at most one bot
 * position at a time (a new opposite signal flips it, a repeat is skipped).
 *
 * Like the limit-fill engine it lives beside, it only runs while this tab is
 * open: there is no server here to watch the clock for you.
 */
export function useAutoStrategy(deps: Deps): StrategyApi {
  const [config, setConfigState] = useState<StrategyConfig>(() =>
    readJSON<StrategyConfig>(CONFIG_KEY, DEFAULT_CONFIG),
  )
  const [armed, setArmedState] = useState(false)
  const [latestClosed, setLatestClosed] = useState<Candle | null>(null)
  const [lastFetchAt, setLastFetchAt] = useState<number | null>(null)
  const [log, setLog] = useState<LogEntry[]>([])

  // Volatile inputs and the config the poll needs, read through a ref so the
  // interval below can key on the account alone and never tear down mid-hour.
  const latest = useRef<Deps & { config: StrategyConfig; armed: boolean }>({
    ...deps,
    config,
    armed,
  })
  latest.current = { ...deps, config, armed }

  const lastActedRef = useRef<number | null>(null)
  const trackedRef = useRef<BotPosition | null>(null)
  const busyRef = useRef(false)
  const logId = useRef(0)
  const pollRef = useRef<() => Promise<void>>(async () => {})

  const push = useCallback((kind: LogKind, text: string) => {
    logId.current += 1
    const entry: LogEntry = { id: logId.current, at: Date.now(), kind, text }
    // Newest first, capped — this is a running tape, not an audit ledger.
    setLog((prev) => [entry, ...prev].slice(0, 50))
  }, [])

  const setConfig = useCallback((patch: Partial<StrategyConfig>) => {
    setConfigState((prev) => {
      const next = { ...prev, ...patch }
      writeJSON(CONFIG_KEY, next)
      return next
    })
  }, [])

  // Reload per-account state whenever the selected account changes.
  useEffect(() => {
    const id = latest.current.accountId
    if (!id) {
      setArmedState(false)
      lastActedRef.current = null
      trackedRef.current = null
      return
    }
    setArmedState(readJSON<boolean>(armedKey(id), false))
    lastActedRef.current = readJSON<number | null>(actedKey(id), null)
    trackedRef.current = readJSON<BotPosition | null>(trackedKey(id), null)
    setLog([])
  }, [deps.accountId])

  const setArmed = useCallback(
    (on: boolean) => {
      const id = latest.current.accountId
      setArmedState(on)
      if (id) writeJSON(armedKey(id), on)
      push('info', on ? 'Armed — waiting for the next 1h close.' : 'Disarmed.')
      // Kick a poll so the readout and the seed update at once, not 30s later.
      void pollRef.current()
    },
    [push],
  )

  // The one action: evaluate a closed bar and, if it calls for a trade, place
  // it — flipping any bot position already open. `force` runs it past the
  // window and the once-per-bar guard, for the manual button.
  const act = useCallback(
    async (candle: Candle, force: boolean) => {
      if (busyRef.current) return
      const { expiry, spot, positions, productsBySymbol, placeOrder, closePosition, config } =
        latest.current

      const color = candleColor(candle)
      const side = sideFor(color, config.bias)
      if (!side) {
        lastActedRef.current = candle.time
        persistActed()
        push('skip', 'Flat 1h candle — no signal.')
        return
      }
      if (!expiry) {
        push('error', 'No expiry loaded — cannot resolve a contract.')
        return
      }
      const resolved = resolveContract(expiry, config.kind, spot, config.moneyness)
      if (!resolved) {
        lastActedRef.current = candle.time
        persistActed()
        push('error', `No ${config.kind} strike near ${spot.toFixed(0)} to trade.`)
        return
      }

      // Reconcile the tracked bot position against reality: if it was closed or
      // settled elsewhere, forget it before deciding.
      let tracked = trackedRef.current
      if (tracked && !positions.some((p) => p.symbol === tracked!.symbol && p.net_qty !== 0)) {
        tracked = null
        trackedRef.current = null
        persistTracked()
      }

      const desiredSym = resolved.product.symbol
      if (tracked && tracked.symbol === desiredSym && tracked.side === side) {
        if (!force) {
          lastActedRef.current = candle.time
          persistActed()
          push('skip', `Signal unchanged (${side} ${desiredSym}) — holding.`)
          return
        }
      }

      busyRef.current = true
      try {
        // Flip: close whatever the bot holds before opening the new leg.
        if (tracked) {
          const pos = positions.find((p) => p.symbol === tracked!.symbol && p.net_qty !== 0)
          const prod = productsBySymbol.get(tracked.symbol)
          if (pos && prod) {
            await closePosition(pos, prod)
            push('trade', `Closed ${tracked.symbol}.`)
          }
        }
        await placeOrder({
          product: resolved.product,
          side,
          orderType: 'market',
          qty: config.qty,
          limitPrice: null,
        })
        trackedRef.current = { symbol: desiredSym, side }
        persistTracked()
        push('trade', `${side.toUpperCase()} ${config.qty} ${desiredSym} (${color} candle).`)
      } catch (err) {
        push('error', err instanceof Error ? err.message : 'Order failed.')
      } finally {
        // Consume the bar either way, so a rejected fill does not re-fire every
        // poll — the next bar is an hour off, and a no-book/no-margin reject
        // will not clear in 30 seconds.
        lastActedRef.current = candle.time
        persistActed()
        busyRef.current = false
      }
    },
    [push],
  )

  function persistActed() {
    const id = latest.current.accountId
    if (id) writeJSON(actedKey(id), lastActedRef.current)
  }
  function persistTracked() {
    const id = latest.current.accountId
    if (id) writeJSON(trackedKey(id), trackedRef.current)
  }

  const poll = useCallback(async () => {
    const end = Math.floor(Date.now() / 1000)
    let candles: Candle[]
    try {
      candles = await fetchCandles('1h', end - LOOKBACK_SEC, end)
    } catch {
      // A dropped fetch is not worth a log line every 30s; the readout simply
      // does not advance until the next one lands.
      return
    }
    setLastFetchAt(Date.now())
    const lc = lastClosedCandle(candles, end)
    setLatestClosed(lc)
    if (!lc) return

    const { armed: isArmed, config: cfg } = latest.current
    if (!isArmed) return

    // Seed on the first armed poll: adopt the current bar as already-seen, so
    // the bot begins on the NEXT close rather than trading the hour behind it.
    if (lastActedRef.current === null) {
      lastActedRef.current = lc.time
      persistActed()
      return
    }
    if (lc.time <= lastActedRef.current) return

    if (!inWindow(new Date(), cfg.windowStart, cfg.windowEnd)) {
      lastActedRef.current = lc.time
      persistActed()
      push('skip', 'New 1h candle, but outside the trading window.')
      return
    }
    await act(lc, false)
  }, [act, push])

  pollRef.current = poll

  // One interval, keyed on the account. Everything volatile is read from the
  // ref, so this survives position/price churn without resubscribing.
  useEffect(() => {
    void poll()
    const id = setInterval(() => void poll(), POLL_MS)
    return () => clearInterval(id)
  }, [deps.accountId, poll])

  const runNow = useCallback(() => {
    if (latestClosed) void act(latestClosed, true)
  }, [latestClosed, act])

  // Derived readout. Cheap, so recomputed each render off the latest bar/spot.
  const color = latestClosed ? candleColor(latestClosed) : null
  const signalSide = color ? sideFor(color, config.bias) : null
  const target =
    deps.expiry && deps.spot > 0
      ? resolveContract(deps.expiry, config.kind, deps.spot, config.moneyness)
      : null
  const inWindowNow = inWindow(new Date(), config.windowStart, config.windowEnd)

  return {
    config,
    setConfig,
    armed,
    setArmed,
    latestClosed,
    color,
    signalSide,
    target,
    inWindowNow,
    marketLive: deps.spot > 0,
    lastFetchAt,
    log,
    runNow,
  }
}
