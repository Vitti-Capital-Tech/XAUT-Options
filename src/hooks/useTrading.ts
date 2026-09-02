import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { market, useMarketTick } from '../lib/marketStore'
import { useDebouncedCallback, useVisiblePoll } from './usePolling'
import type { Product } from '../lib/delta'
import { isPerp, parseSymbol } from '../lib/delta'
import { downloadCsv, fillsFilename, fillsToCsv, istDayRange } from '../lib/exportFills'
import {
  computeFee,
  crossesNow,
  marketFillPrice,
  type OrderRow,
  type PositionRow,
  type Side,
  type OrderType,
  type TriggerSource,
} from '../engine/paper'

export interface FillRow {
  id: string
  symbol: string
  contract_type: string
  /** Null on a perpetual — no strike to record. */
  strike_price: string | null
  side: Side
  order_type: string
  qty: number
  price: string
  contract_value: string
  premium: string
  notional: string
  fee: string
  realized_pnl: string
  spot_at_fill: string | null
  /** Expiry settlement, versus an ordinary or triggered fill. */
  is_settlement: boolean
  /** Why a triggered close fired — 'take_profit' | 'stop_loss'. Null otherwise. */
  close_reason: string | null
  /**
   * Why the delta engine closed this leg, in a line — the rule that ran, the spot
   * it was priced at, and net delta either side of it
   * ([`0035`](../../supabase/migrations/0035_reason_on_the_row.sql)). Null on
   * opening fills, whose reason lives on the position they opened, and on
   * anything the delta engine did not do.
   */
  reason: string | null
  created_at: string
}

const POSITION_COLS =
  'id, account_id, symbol, product_id, contract_type, strike_price, expiry_label, contract_value, net_qty, avg_entry_price, realized_pnl, take_profit, stop_loss, tpsl_trigger, entry_reason, leverage'
const ORDER_COLS =
  'id, account_id, symbol, product_id, contract_type, strike_price, expiry_label, contract_value, side, order_type, qty, limit_price, status, avg_fill_price, filled_qty, reduce_only, created_at, leverage'
const FILL_COLS =
  'id, symbol, contract_type, strike_price, side, order_type, qty, price, contract_value, premium, notional, fee, realized_pnl, spot_at_fill, is_settlement, close_reason, reason, created_at'

/**
 * How many rows each history fetch takes, newest first.
 *
 * Orders stay at 200 — nobody reads past the last few, and a resting order is
 * resolved by the fill engine rather than by being looked at.
 *
 * Fills are 1000, up from the same 200, because that cap was silently wrong in a
 * way that mattered: the panel groups what it loaded by day and prints the count
 * per group, so on a book making hundreds of fills a day the oldest visible day
 * reported however many rows happened to fit rather than what the day did. 49
 * fills today plus a 200 cap showed yesterday as "151 fills" when it was 429.
 *
 * 1000 is a bigger window, not a fix for the shape of the problem — a day is
 * still capped, it is just capped further out. What makes it honest is
 * `fillsTruncated` below, which the panel uses to mark the one group that may be
 * short. Anything wanting a real ledger should query the database:
 * scripts/export_delta_day.sql.
 *
 * The window is only ever read while the Trade History tab is actually open —
 * see `setHistoryVisible`. It is by far the largest thing this hook fetches, and
 * four books' worth of it on a 15s poll was most of the app's Supabase egress,
 * for a table that is pure display: nothing in the fill engine, the strategies
 * or the account summary reads a fill.
 */
const FILL_LIMIT = 1000
const ORDER_LIMIT = 200
/** Collapse one engine cycle's burst of row changes into a single re-read. */
const REALTIME_DEBOUNCE_MS = 150

export interface PlaceOrderArgs {
  product: Product
  side: Side
  orderType: OrderType
  qty: number
  limitPrice: number | null
  reduceOnly?: boolean
  /** Perpetuals only. Stored on the order and carried onto the position by
   *  `execute_fill`, which is what margins it from then on. */
  leverage?: number | null
}

/**
 * Positions, open orders and trade history for one paper account, plus the
 * order-placement and limit-fill logic.
 *
 * The limit-order fill engine runs here, in the browser, driven by the same
 * WebSocket feed that paints the chain. Consequence worth knowing: limit orders
 * only fill while this dashboard is open. Market orders always fill immediately
 * on placement.
 */
export function useTrading(accountId: string | null, onAccountChanged: () => void) {
  const [positions, setPositions] = useState<PositionRow[]>([])
  const [orders, setOrders] = useState<OrderRow[]>([])
  const [fills, setFills] = useState<FillRow[]>([])
  // How many fills the account holds, for the tab's badge. Counted rather than
  // measured off `fills`, which is empty until the tab is opened — a `head`
  // request returns the number in a header and no rows at all.
  const [fillCount, setFillCount] = useState(0)
  const [loading, setLoading] = useState(true)

  const tick = useMarketTick()

  // Orders currently being filled, so a burst of ticks cannot double-submit one.
  const inFlight = useRef(new Set<string>())

  // Whether the Trade History tab is on screen. A ref as well as state because
  // the loaders below must read it without taking it as a dependency — a stale
  // `reload` identity would tear down the poll and the subscription.
  const historyVisibleRef = useRef(false)
  const fillsRef = useRef<FillRow[]>([])
  fillsRef.current = fills

  const loadPositions = useCallback(async () => {
    if (!accountId) return
    const { data, error } = await supabase
      .from('positions')
      .select(POSITION_COLS)
      .eq('account_id', accountId)
    if (!error) setPositions((data ?? []) as PositionRow[])
  }, [accountId])

  const loadOrders = useCallback(async () => {
    if (!accountId) return
    const { data, error } = await supabase
      .from('orders')
      .select(ORDER_COLS)
      .eq('account_id', accountId)
      .order('created_at', { ascending: false })
      .limit(ORDER_LIMIT)
    if (!error) setOrders((data ?? []) as OrderRow[])
  }, [accountId])

  /** The badge's number, with no row bodies on the wire. */
  const loadFillCount = useCallback(async () => {
    if (!accountId) return
    const { count, error } = await supabase
      .from('fills')
      .select('id', { count: 'exact', head: true })
      .eq('account_id', accountId)
    if (!error) setFillCount(count ?? 0)
  }, [accountId])

  /** The whole visible window, newest first. Only for opening the tab. */
  const loadFills = useCallback(async () => {
    if (!accountId) return
    const { data, error } = await supabase
      .from('fills')
      .select(FILL_COLS)
      .eq('account_id', accountId)
      .order('created_at', { ascending: false })
      .limit(FILL_LIMIT)
    if (!error) setFills((data ?? []) as FillRow[])
  }, [accountId])

  /**
   * Bring an open history tab up to date by reading only what is newer than the
   * newest row it holds, rather than the whole window again.
   *
   * `gte`, not `gt`: the engine writes a cycle's legs in one transaction, so
   * sibling fills share `now()` to the microsecond and a strict comparison would
   * drop every one but the first. The boundary rows come back and are dropped by
   * id below, which is the check that actually keeps the list unique.
   */
  const syncFills = useCallback(async () => {
    if (!accountId) return
    const newest = fillsRef.current[0]?.created_at
    if (!newest) {
      await loadFills()
      return
    }
    const { data, error } = await supabase
      .from('fills')
      .select(FILL_COLS)
      .eq('account_id', accountId)
      .gte('created_at', newest)
      .order('created_at', { ascending: false })
      .limit(FILL_LIMIT)
    if (error || !data?.length) return
    setFills((prev) => {
      const seen = new Set(prev.map((f) => f.id))
      const fresh = (data as FillRow[]).filter((f) => !seen.has(f.id))
      return fresh.length === 0 ? prev : [...fresh, ...prev].slice(0, FILL_LIMIT)
    })
  }, [accountId, loadFills])

  /**
   * Everything the book needs to be correct on screen. Trade history is not in
   * that set: it is fetched when its tab is opened and kept current from there,
   * so a dashboard sitting on the Positions tab never pays for it.
   */
  const reload = useCallback(async () => {
    if (!accountId) {
      setPositions([])
      setOrders([])
      setFills([])
      setFillCount(0)
      setLoading(false)
      return
    }
    await Promise.all([
      loadPositions(),
      loadOrders(),
      loadFillCount(),
      historyVisibleRef.current ? syncFills() : Promise.resolve(),
    ])
    setLoading(false)
  }, [accountId, loadPositions, loadOrders, loadFillCount, syncFills])

  useEffect(() => {
    setLoading(true)
    void reload()
  }, [reload])

  /**
   * Told by the panel which tab is showing. Opening history reads the window
   * once; closing it stops the account's fills being refreshed at all, and
   * drops what was held so reopening cannot show a stale ledger.
   */
  const setHistoryVisible = useCallback(
    (visible: boolean) => {
      if (historyVisibleRef.current === visible) return
      historyVisibleRef.current = visible
      if (visible) void loadFills()
      else setFills([])
    },
    [loadFills],
  )

  // A switched account has a different ledger, so whatever is held belongs to
  // the old one. Re-read if the tab is open, clear if it is not.
  useEffect(() => {
    setFills([])
    if (historyVisibleRef.current) void loadFills()
  }, [accountId, loadFills])

  // Poll, because a position can be created without this tab doing anything to
  // trigger a reload — the settlement cron closing an expiry, another tab or
  // device on the same paper account, an admin editing it. Without this, such a
  // change shows only after a trade here or a full reopen. This is the fallback;
  // realtime below makes the same reload happen at once.
  //
  // Only while the tab is on screen: nothing here drives the fill engine, which
  // runs off the market websocket, so a backgrounded dashboard re-reading four
  // books every fifteen seconds was buying nothing anybody could see. Coming
  // back to the tab reconciles before the interval resumes.
  useVisiblePoll(() => void reload(), 15_000, Boolean(accountId))

  // Realtime: the moment this account's positions, orders or fills change — from
  // any session, the strategy cron, or settlement — re-read, so a parallel
  // dashboard updates without a refresh.
  //
  // Split by table, and debounced. One engine cycle lands an order, its fill and
  // the position it moved within a few milliseconds of each other, and a single
  // shared handler turned that into four complete re-reads of all three tables.
  // Each table now refreshes only itself, once per burst.
  const changedRef = useRef(onAccountChanged)
  changedRef.current = onAccountChanged

  const bumpPositions = useDebouncedCallback(() => {
    void loadPositions()
    changedRef.current()
  }, REALTIME_DEBOUNCE_MS)

  const bumpOrders = useDebouncedCallback(() => {
    void loadOrders()
  }, REALTIME_DEBOUNCE_MS)

  // A fill moves cash, so the account summary still has to be told — but the
  // rows themselves are only worth fetching if someone is looking at them.
  const bumpFills = useDebouncedCallback(() => {
    void loadFillCount()
    if (historyVisibleRef.current) void syncFills()
    changedRef.current()
  }, REALTIME_DEBOUNCE_MS)

  useEffect(() => {
    if (!accountId) return
    // Best-effort: a subscription failure must never blank the app — the 15s
    // poll above still reconciles. Swallow any throw.
    try {
      const channel = supabase
        .channel(`trading-${accountId}`)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'positions', filter: `account_id=eq.${accountId}` }, bumpPositions)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'fills', filter: `account_id=eq.${accountId}` }, bumpFills)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'orders', filter: `account_id=eq.${accountId}` }, bumpOrders)
        .subscribe()
      return () => {
        void supabase.removeChannel(channel)
      }
    } catch (err) {
      console.error('trading realtime failed; falling back to poll:', err)
    }
  }, [accountId, bumpPositions, bumpOrders, bumpFills])

  /** Run a fill against an existing order row. Returns the realized P&L. */
  const executeFill = useCallback(
    async (order: OrderRow, product: Product, fillPrice: number) => {
      const spot = market.spot
      const qty = order.qty - order.filled_qty
      const fee = computeFee(product, fillPrice, qty, spot)

      const { error } = await supabase.rpc('execute_fill', {
        p_order_id: order.id,
        p_qty: qty,
        p_price: fillPrice,
        p_fee: fee,
        p_spot: spot,
      })
      if (error) throw new Error(error.message)
    },
    [],
  )

  const placeOrder = useCallback(
    async ({
      product,
      side,
      orderType,
      qty,
      limitPrice,
      reduceOnly = false,
      leverage = null,
    }: PlaceOrderArgs) => {
      if (!accountId) throw new Error('No account selected')
      const { data: userData } = await supabase.auth.getUser()
      const userId = userData.user?.id
      if (!userId) throw new Error('Not signed in')

      const parsed = parseSymbol(product.symbol)
      const ticker = market.get(product.symbol)

      // Resolve the market price before writing anything, so an empty book
      // fails cleanly instead of leaving a stranded order row.
      let immediateFill: number | null = null
      if (orderType === 'market') {
        immediateFill = marketFillPrice(ticker, side)
        if (immediateFill === null) {
          throw new Error(`No ${side === 'buy' ? 'asks' : 'bids'} available — market order cannot fill`)
        }
      } else {
        immediateFill = crossesNow(side, limitPrice!, ticker)
      }

      const { data: created, error: insertErr } = await supabase
        .from('orders')
        .insert({
          account_id: accountId,
          user_id: userId,
          symbol: product.symbol,
          product_id: product.id,
          contract_type: product.contract_type,
          // A perpetual has neither, and says so with a null and a label rather
          // than with a zero that would sort and format as a real strike.
          strike_price: isPerp(product.contract_type) ? null : Number(product.strike_price),
          expiry_label: isPerp(product.contract_type) ? 'PERP' : (parsed?.expiry ?? ''),
          contract_value: Number(product.contract_value),
          side,
          order_type: orderType,
          qty,
          limit_price: orderType === 'limit' ? limitPrice : null,
          reduce_only: reduceOnly,
          leverage: isPerp(product.contract_type) ? leverage : null,
        })
        .select(ORDER_COLS)
        .single()

      if (insertErr) throw new Error(insertErr.message)
      const order = created as OrderRow

      if (immediateFill !== null) {
        try {
          await executeFill(order, product, immediateFill)
        } catch (err) {
          // Never leave a market order resting — it has no price to rest at.
          await supabase
            .from('orders')
            .update({ status: 'cancelled', cancel_reason: 'Fill failed' })
            .eq('id', order.id)
            .eq('status', 'open')
          throw err
        }
      }

      await reload()
      onAccountChanged()
      return order
    },
    [accountId, executeFill, reload, onAccountChanged],
  )

  const cancelOrder = useCallback(
    async (orderId: string) => {
      const { error } = await supabase
        .from('orders')
        .update({ status: 'cancelled', cancel_reason: 'Cancelled by user' })
        .eq('id', orderId)
        .eq('status', 'open')
      if (error) throw new Error(error.message)
      await reload()
    },
    [reload],
  )

  /**
   * Arm or clear a position's take-profit / stop-loss. `trigger` picks the price
   * the levels watch — the underlying index or the option mark — and the
   * server-side cron fires the close against it. Pass null to clear a side.
   */
  const setTpSl = useCallback(
    async (
      positionId: string,
      takeProfit: number | null,
      stopLoss: number | null,
      trigger: TriggerSource = 'index',
    ) => {
      const { error } = await supabase.rpc('set_position_tpsl', {
        p_position_id: positionId,
        p_take_profit: takeProfit,
        p_stop_loss: stopLoss,
        p_trigger: trigger,
      })
      if (error) throw new Error(error.message)
      await reload()
    },
    [reload],
  )

  /**
   * Download one IST calendar day of this account's fills as a spreadsheet.
   *
   * Queried fresh rather than filtered out of `fills`, and that is the whole
   * point: the loaded set is the newest `FILL_LIMIT` rows, so exporting from it
   * would hand over whatever happened to fit — which is exactly the way the day
   * header used to under-report a busy session. This asks the database for the
   * day and takes all of it.
   *
   * Returns how many rows were written, so the caller can say so.
   */
  const exportDay = useCallback(
    async (day: string, accountName: string): Promise<number> => {
      if (!accountId) return 0
      const { start, end } = istDayRange(day)
      const { data, error } = await supabase
        .from('fills')
        .select(FILL_COLS)
        .eq('account_id', accountId)
        .gte('created_at', start)
        .lt('created_at', end)
        .order('created_at', { ascending: true })
      if (error) throw new Error(error.message)

      const rows = (data ?? []) as FillRow[]
      if (rows.length === 0) return 0
      downloadCsv(fillsFilename(accountName, day), fillsToCsv(rows))
      return rows.length
    },
    [accountId],
  )

  /** Flatten a position with an opposing market order. */
  const closePosition = useCallback(
    async (pos: PositionRow, product: Product, lots?: number) => {
      const qty = Math.min(lots ?? Math.abs(pos.net_qty), Math.abs(pos.net_qty))
      if (qty <= 0) return
      await placeOrder({
        product,
        side: pos.net_qty > 0 ? 'sell' : 'buy',
        orderType: 'market',
        qty,
        limitPrice: null,
        reduceOnly: true,
      })
    },
    [placeOrder],
  )

  // -------------------------------------------------------------------------
  // Limit-order fill engine: on every throttled market tick, fill anything
  // the book has crossed.
  // -------------------------------------------------------------------------
  const productsRef = useRef<Map<string, Product>>(new Map())
  const registerProducts = useCallback((products: Product[]) => {
    for (const p of products) productsRef.current.set(p.symbol, p)
  }, [])

  useEffect(() => {
    const open = orders.filter((o) => o.status === 'open' && o.order_type === 'limit')
    if (open.length === 0) return

    let cancelled = false

    const run = async () => {
      let filledAny = false
      for (const order of open) {
        if (cancelled) return
        if (inFlight.current.has(order.id)) continue

        const product = productsRef.current.get(order.symbol)
        if (!product) continue

        const ticker = market.get(order.symbol)
        const price = crossesNow(order.side, Number(order.limit_price), ticker)
        if (price === null) continue

        inFlight.current.add(order.id)
        try {
          await executeFill(order, product, price)
          filledAny = true
        } catch {
          // Another tab may have filled it first; the next reload reconciles.
        } finally {
          inFlight.current.delete(order.id)
        }
      }
      if (filledAny && !cancelled) {
        await reload()
        onAccountChanged()
      }
    }

    void run()
    return () => {
      cancelled = true
    }
    // `tick` is the driver: this re-runs on every throttled market update.
  }, [tick, orders, executeFill, reload, onAccountChanged])

  const openOrders = orders.filter((o) => o.status === 'open')
  // The fetch came back full, so there are older fills that were not read. Only
  // the oldest day group can be short — every day above it is bounded by the day
  // after it, not by the cap.
  const fillsTruncated = fills.length >= FILL_LIMIT

  return {
    positions,
    orders,
    openOrders,
    fills,
    fillCount,
    fillsTruncated,
    setHistoryVisible,
    loading,
    reload,
    placeOrder,
    cancelOrder,
    closePosition,
    setTpSl,
    exportDay,
    registerProducts,
  }
}
