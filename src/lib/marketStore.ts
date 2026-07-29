/**
 * Live ticker cache shared by the whole app.
 *
 * Ticks arrive far faster than the UI needs to repaint, so writes land in a Map
 * synchronously and subscribers are notified on a throttled tick. Components read
 * the current value during render via `useSyncExternalStore`, using a version
 * counter as the snapshot — cheap identity check, no per-tick object allocation.
 */

import { useSyncExternalStore } from 'react'
import type { Ticker } from './delta'

const NOTIFY_INTERVAL_MS = 250

class MarketStore {
  private tickers = new Map<string, Ticker>()
  private listeners = new Set<() => void>()
  private version = 0
  private dirty = false
  private timer: number | null = null

  spot = 0
  status: 'connecting' | 'live' | 'reconnecting' = 'connecting'

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    if (this.timer === null) {
      this.timer = setInterval(() => this.flush(), NOTIFY_INTERVAL_MS) as unknown as number
    }
    return () => {
      this.listeners.delete(listener)
      if (this.listeners.size === 0 && this.timer !== null) {
        clearInterval(this.timer)
        this.timer = null
      }
    }
  }

  getVersion = () => this.version

  get(symbol: string): Ticker | undefined {
    return this.tickers.get(symbol)
  }

  /** Merge a tick. WS payloads can omit fields, so keep prior values for anything absent. */
  upsert(t: Ticker) {
    const prev = this.tickers.get(t.symbol)
    this.tickers.set(t.symbol, prev ? { ...prev, ...t } : t)
    if (t.spot_price) {
      const s = Number(t.spot_price)
      if (Number.isFinite(s) && s > 0) this.spot = s
    }
    this.dirty = true
  }

  upsertMany(list: Ticker[]) {
    for (const t of list) this.upsert(t)
    this.flush()
  }

  setSpot(price: number) {
    this.spot = price
    this.dirty = true
  }

  setStatus(status: MarketStore['status']) {
    if (this.status === status) return
    this.status = status
    this.dirty = true
    this.flush()
  }

  private flush() {
    if (!this.dirty) return
    this.dirty = false
    this.version += 1
    for (const listener of this.listeners) listener()
  }
}

export const market = new MarketStore()

/**
 * Re-render the caller whenever the market cache changes (at most every 250ms).
 * Read prices with `market.get(symbol)` inside the render body.
 */
export function useMarketTick(): number {
  return useSyncExternalStore(market.subscribe, market.getVersion, market.getVersion)
}
