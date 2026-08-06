import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { fetchCandles, type Candle, type Expiry } from '../lib/delta'
import type { PlaceOrderArgs } from './useTrading'
import type { TriggerSource } from '../engine/paper'
import {
  DEFAULT_CONFIG,
  STOP_LOSS_MULTIPLE,
  candleColor,
  inWindow,
  kindForColor,
  lastClosedCandle,
  resolveContract,
  type CandleColor,
  type OptionKind,
  type ResolvedContract,
  type StrategyConfig,
} from '../lib/strategy'

const POLL_MS = 30_000
const LOOKBACK_SEC = 8 * 3600

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
  /** Which option the last bar says to sell — call on red, put on green. */
  signalKind: OptionKind | null
  target: ResolvedContract | null
  inWindowNow: boolean
  marketLive: boolean
  hasAccount: boolean
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
  placeOrder: (args: PlaceOrderArgs) => Promise<unknown>
  setTpSl: (
    positionId: string,
    takeProfit: number | null,
    stopLoss: number | null,
    trigger: TriggerSource,
  ) => Promise<void>
}

/**
 * The auto-strategy engine. Polls the spot index's 1h candles and, once armed,
 * sells one option on each freshly-closed bar — a call on a red bar, a put on a
 * green — at the chosen moneyness, inside the time window. Every sale gets a
 * stop at twice its entry premium (a 100% loss), armed on the mark so the
 * server closes it whether or not this tab is open. Positions accumulate: each
 * hour adds another short, each running to its own stop or to expiry.
 *
 * The placing itself only runs while this tab is open — there is no server here
 * to watch the clock — but once a short is open, its stop lives server-side.
 */
export function useAutoStrategy(deps: Deps): StrategyApi {
  const [config, setConfigState] = useState<StrategyConfig>(() => ({
    ...DEFAULT_CONFIG,
    ...readJSON<Partial<StrategyConfig>>(CONFIG_KEY, {}),
  }))
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
  const busyRef = useRef(false)
  const logId = useRef(0)
  const pollRef = useRef<() => Promise<void>>(async () => {})

  const push = useCallback((kind: LogKind, text: string) => {
    logId.current += 1
    const entry: LogEntry = { id: logId.current, at: Date.now(), kind, text }
    setLog((prev) => [entry, ...prev].slice(0, 50))
  }, [])

  const setConfig = useCallback((patch: Partial<StrategyConfig>) => {
    setConfigState((prev) => {
      const next = { ...prev, ...patch }
      writeJSON(CONFIG_KEY, next)
      return next
    })
  }, [])

  // Reload per-account state whenever the selected auto account changes.
  useEffect(() => {
    const id = latest.current.accountId
    if (!id) {
      setArmedState(false)
      lastActedRef.current = null
      return
    }
    setArmedState(readJSON<boolean>(armedKey(id), false))
    lastActedRef.current = readJSON<number | null>(actedKey(id), null)
    setLog([])
  }, [deps.accountId])

  function persistActed() {
    const id = latest.current.accountId
    if (id) writeJSON(actedKey(id), lastActedRef.current)
  }

  const setArmed = useCallback(
    (on: boolean) => {
      const id = latest.current.accountId
      setArmedState(on)
      if (id) writeJSON(armedKey(id), on)
      push('info', on ? 'Armed — waiting for the next 1h close.' : 'Disarmed.')
      void pollRef.current()
    },
    [push],
  )

  // The one action: sell the option the closed bar calls for, then arm its stop.
  // The window and once-per-bar guards live in poll(); calling act() directly
  // (the manual button) deliberately skips them.
  const act = useCallback(
    async (candle: Candle) => {
      if (busyRef.current) return
      const { expiry, spot, placeOrder, setTpSl, config, accountId } = latest.current

      const color = candleColor(candle)
      const kind = kindForColor(color)
      if (!kind) {
        lastActedRef.current = candle.time
        persistActed()
        push('skip', 'Flat 1h candle — no signal.')
        return
      }
      if (!expiry) {
        push('error', 'No expiry loaded — cannot resolve a contract.')
        return
      }
      if (!accountId) {
        push('error', 'No auto account selected.')
        return
      }
      const resolved = resolveContract(expiry, kind, spot, config.moneyness)
      if (!resolved) {
        lastActedRef.current = candle.time
        persistActed()
        push('error', `No ${kind} strike near ${spot.toFixed(0)} to sell.`)
        return
      }

      busyRef.current = true
      const sym = resolved.product.symbol
      try {
        const cv = Number(resolved.product.contract_value)
        const lots = Math.max(1, Math.round(config.qty / cv))
        await placeOrder({
          product: resolved.product,
          side: 'sell',
          orderType: 'market',
          qty: lots,
          limitPrice: null,
        })

        // Arm the stop at twice the entry premium, on the mark, so it fires
        // server-side. Read the position back for its (possibly blended) entry.
        const { data } = await supabase
          .from('positions')
          .select('id, avg_entry_price, net_qty')
          .eq('account_id', accountId)
          .eq('symbol', sym)
          .maybeSingle()
        if (data && Number(data.net_qty) !== 0) {
          const stop = STOP_LOSS_MULTIPLE * Number(data.avg_entry_price)
          await setTpSl(data.id as string, null, stop, 'mark')
          push('trade', `SELL ${config.qty} XAUT ${sym} (${color} candle) · stop mark ${stop.toFixed(2)}.`)
        } else {
          push('trade', `SELL ${config.qty} XAUT ${sym} (${color} candle).`)
        }
      } catch (err) {
        push('error', err instanceof Error ? err.message : 'Order failed.')
      } finally {
        // Consume the bar either way, so a rejected fill does not re-fire every
        // poll — the next bar is an hour off.
        lastActedRef.current = candle.time
        persistActed()
        busyRef.current = false
      }
    },
    [push],
  )

  const poll = useCallback(async () => {
    const end = Math.floor(Date.now() / 1000)
    let candles: Candle[]
    try {
      candles = await fetchCandles('1h', end - LOOKBACK_SEC, end)
    } catch {
      return
    }
    setLastFetchAt(Date.now())
    const lc = lastClosedCandle(candles, end)
    setLatestClosed(lc)
    if (!lc) return

    const { armed: isArmed, config: cfg } = latest.current
    if (!isArmed) return

    // Seed on the first armed poll so the bot begins on the NEXT close.
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
    await act(lc)
  }, [act, push])

  pollRef.current = poll

  useEffect(() => {
    void poll()
    const id = setInterval(() => void poll(), POLL_MS)
    return () => clearInterval(id)
  }, [deps.accountId, poll])

  const runNow = useCallback(() => {
    if (latestClosed) void act(latestClosed)
  }, [latestClosed, act])

  // Derived readout.
  const color = latestClosed ? candleColor(latestClosed) : null
  const signalKind = color ? kindForColor(color) : null
  const target =
    deps.expiry && deps.spot > 0 && signalKind
      ? resolveContract(deps.expiry, signalKind, deps.spot, config.moneyness)
      : null
  const inWindowNow = inWindow(new Date(), config.windowStart, config.windowEnd)

  return {
    config,
    setConfig,
    armed,
    setArmed,
    latestClosed,
    color,
    signalKind,
    target,
    inWindowNow,
    marketLive: deps.spot > 0,
    hasAccount: deps.accountId !== null,
    lastFetchAt,
    log,
    runNow,
  }
}
