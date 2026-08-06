import { useCallback, useEffect, useRef, useState } from 'react'
import { supabase } from '../lib/supabase'
import { market, useMarketTick } from '../lib/marketStore'
import type { Product } from '../lib/delta'
import { parseSymbol } from '../lib/delta'
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
  strike_price: string
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
  created_at: string
}

const POSITION_COLS =
  'id, account_id, symbol, product_id, contract_type, strike_price, expiry_label, contract_value, net_qty, avg_entry_price, realized_pnl, take_profit, stop_loss, tpsl_trigger'
const ORDER_COLS =
  'id, account_id, symbol, product_id, contract_type, strike_price, expiry_label, contract_value, side, order_type, qty, limit_price, status, avg_fill_price, filled_qty, reduce_only, created_at'
const FILL_COLS =
  'id, symbol, contract_type, strike_price, side, order_type, qty, price, contract_value, premium, notional, fee, realized_pnl, spot_at_fill, created_at'

export interface PlaceOrderArgs {
  product: Product
  side: Side
  orderType: OrderType
  qty: number
  limitPrice: number | null
  reduceOnly?: boolean
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
  const [loading, setLoading] = useState(true)

  const tick = useMarketTick()

  // Orders currently being filled, so a burst of ticks cannot double-submit one.
  const inFlight = useRef(new Set<string>())

  const reload = useCallback(async () => {
    if (!accountId) {
      setPositions([])
      setOrders([])
      setFills([])
      setLoading(false)
      return
    }

    const [posRes, ordRes, fillRes] = await Promise.all([
      supabase.from('positions').select(POSITION_COLS).eq('account_id', accountId),
      supabase
        .from('orders')
        .select(ORDER_COLS)
        .eq('account_id', accountId)
        .order('created_at', { ascending: false })
        .limit(200),
      supabase
        .from('fills')
        .select(FILL_COLS)
        .eq('account_id', accountId)
        .order('created_at', { ascending: false })
        .limit(200),
    ])

    if (!posRes.error) setPositions((posRes.data ?? []) as PositionRow[])
    if (!ordRes.error) setOrders((ordRes.data ?? []) as OrderRow[])
    if (!fillRes.error) setFills((fillRes.data ?? []) as FillRow[])
    setLoading(false)
  }, [accountId])

  useEffect(() => {
    setLoading(true)
    void reload()
  }, [reload])

  // Poll, because a position can be created without this tab doing anything to
  // trigger a reload — the settlement cron closing an expiry, another tab or
  // device on the same paper account, an admin editing it. Without this, such a
  // change shows only after a trade here or a full reopen. reload() just re-reads
  // from the database, so an extra pass is cheap and self-reconciling.
  useEffect(() => {
    if (!accountId) return
    const id = setInterval(() => void reload(), 15_000)
    return () => clearInterval(id)
  }, [accountId, reload])

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
    async ({ product, side, orderType, qty, limitPrice, reduceOnly = false }: PlaceOrderArgs) => {
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
          strike_price: Number(product.strike_price),
          expiry_label: parsed?.expiry ?? '',
          contract_value: Number(product.contract_value),
          side,
          order_type: orderType,
          qty,
          limit_price: orderType === 'limit' ? limitPrice : null,
          reduce_only: reduceOnly,
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

  return {
    positions,
    orders,
    openOrders,
    fills,
    loading,
    reload,
    placeOrder,
    cancelOrder,
    closePosition,
    setTpSl,
    registerProducts,
  }
}
