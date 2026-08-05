import { useCallback, useEffect, useMemo, useState } from 'react'
import { Login } from './components/Login'
import { TopBar } from './components/TopBar'
import { OptionChain } from './components/OptionChain'
import { OrderTicket, type TicketRequest } from './components/OrderTicket'
import { BottomPanel } from './components/BottomPanel'
import { AdminPanel } from './components/AdminPanel'
import { useAuth } from './hooks/useAuth'
import { useAccounts } from './hooks/useAccounts'
import { useTrading } from './hooks/useTrading'
import { useKeywordTrigger } from './hooks/useKeywordTrigger'
import { market, useMarketTick } from './lib/marketStore'
import {
  MarketStream,
  fetchExpiries,
  fetchTickers,
  formatExpiry,
  type Expiry,
  type Product,
} from './lib/delta'
import { shortImRate, summarizeAccount, type Side } from './engine/paper'
import { supabaseConfigured } from './lib/supabase'
import { ADMIN_KEYWORD } from './lib/admin'

export default function App() {
  const { session, user, loading: authLoading } = useAuth()

  if (!supabaseConfigured) return <ConfigNotice />
  if (authLoading) return <Splash>Loading…</Splash>
  if (!session) return <Login />
  return <Terminal userId={user!.id} email={user!.email} />
}

// ---------------------------------------------------------------------------

function Terminal({ userId, email }: { userId: string; email: string | undefined }) {
  const accounts = useAccounts(userId)
  const trading = useTrading(accounts.selectedId, accounts.reload)

  const [expiries, setExpiries] = useState<Expiry[]>([])
  const [activeExpiry, setActiveExpiry] = useState<string | null>(null)
  const [marketError, setMarketError] = useState<string | null>(null)
  const [ticket, setTicket] = useState<TicketRequest | null>(null)
  // Always starts closed: signing in lands on the chain, and the panel is
  // opened deliberately from there.
  const [adminOpen, setAdminOpen] = useState(false)

  const tick = useMarketTick()

  // Typing the admin keyword anywhere opens the account manager. Disabled while
  // the order ticket is up so the ticket's own inputs keep focus behaviour.
  useKeywordTrigger(ADMIN_KEYWORD, () => setAdminOpen(true), !ticket)

  // ---- Market data bootstrap -----------------------------------------------
  useEffect(() => {
    let active = true

    void (async () => {
      try {
        const [exps, tickers] = await Promise.all([fetchExpiries(), fetchTickers()])
        if (!active) return
        if (exps.length === 0) {
          setMarketError('No live XAUT option contracts are listed right now.')
          return
        }
        market.upsertMany(tickers)
        setExpiries(exps)
        setActiveExpiry((current) => current ?? exps[0].label)
      } catch (err) {
        if (active) setMarketError(err instanceof Error ? err.message : 'Could not load market data')
      }
    })()

    return () => {
      active = false
    }
  }, [])

  // Every product across every expiry, for position/order lookups.
  const productsBySymbol = useMemo(() => {
    const m = new Map<string, Product>()
    for (const exp of expiries) {
      for (const p of exp.calls.values()) m.set(p.symbol, p)
      for (const p of exp.puts.values()) m.set(p.symbol, p)
    }
    return m
  }, [expiries])

  // The fill engine needs product metadata (contract value, fee rates) by symbol.
  useEffect(() => {
    trading.registerProducts([...productsBySymbol.values()])
  }, [productsBySymbol, trading])

  const expiry = expiries.find((e) => e.label === activeExpiry) ?? null

  // ---- Live stream ---------------------------------------------------------
  const [stream] = useState(() => new MarketStream())

  useEffect(() => {
    stream
      .on('ticker', (t) => market.upsert(t))
      .on('spot', (p) => market.setSpot(p))
      .on('status', (s) => market.setStatus(s))
      .connect()
    return () => stream.close()
  }, [stream])

  // Subscribe to the visible expiry plus anything we hold or have resting, so
  // P&L and limit fills keep working while browsing a different expiry.
  useEffect(() => {
    const symbols = new Set<string>()
    if (expiry) {
      for (const p of expiry.calls.values()) symbols.add(p.symbol)
      for (const p of expiry.puts.values()) symbols.add(p.symbol)
    }
    for (const p of trading.positions) symbols.add(p.symbol)
    for (const o of trading.openOrders) symbols.add(o.symbol)
    stream.setSymbols([...symbols])
  }, [stream, expiry, trading.positions, trading.openOrders])

  // ---- Account summary ----------------------------------------------------
  const tickerFor = useCallback((symbol: string) => market.get(symbol), [])
  // Margin at the rate the venue publishes for that very contract, not at a rate
  // of ours. Undefined for a contract no longer in the chain, which is the one
  // case the engine's fallback is for.
  const imRateFor = useCallback(
    (symbol: string) => {
      const product = productsBySymbol.get(symbol)
      return product ? shortImRate(product) : undefined
    },
    [productsBySymbol],
  )
  const summary = useMemo(
    () =>
      summarizeAccount(
        Number(accounts.selected?.cash_balance ?? 0),
        Number(accounts.selected?.starting_balance ?? 0),
        trading.positions,
        tickerFor,
        market.spot,
        imRateFor,
      ),
    // The tick has to be a dependency, not merely a reason to re-render: the
    // marks this reads live outside React, so without it the memo hands back a
    // stale summary and the header's unrealized P&L freezes between fills.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [
      tick,
      accounts.selected?.cash_balance,
      accounts.selected?.starting_balance,
      trading.positions,
      tickerFor,
      imRateFor,
    ],
  )

  const openTicket = useCallback((product: Product, side: Side, presetPrice: number | null) => {
    setTicket({ product, side, presetPrice })
  }, [])

  if (marketError) {
    return (
      <Splash>
        <p className="text-neg">{marketError}</p>
        <button
          onClick={() => location.reload()}
          className="mt-3 rounded border border-raised-3 px-3 py-1 text-xs hover:border-ink-3"
        >
          Retry
        </button>
      </Splash>
    )
  }

  if (accounts.loading || expiries.length === 0) return <Splash>Loading market…</Splash>

  return (
    /* The page scrolls. The header, the expiries and the chain fill exactly one
       screen, and the panel grows downward from there rather than taking height
       off the chain — so a long list of positions is something you scroll to, not
       something that squeezes the book. */
    <div className="flex flex-col">
      <div className="flex h-screen flex-col">
        <TopBar
          accounts={accounts.accounts}
          selected={accounts.selected}
          summary={summary}
          email={email}
          onSelect={accounts.setSelectedId}
          onCreate={accounts.createAccount}
          onSetBalance={accounts.setStartingBalance}
          onReset={async (id) => {
            await accounts.resetAccount(id)
            await trading.reload()
          }}
          onArchive={(id) => accounts.setArchived(id, true)}
          onOpenAdmin={() => setAdminOpen(true)}
          adminKeyword={ADMIN_KEYWORD}
        />

        <div className="flex shrink-0 items-center gap-1 overflow-x-auto border-b border-line bg-surface px-2 py-1.5">
          <span className="mr-1 shrink-0 text-[10px] tracking-wider text-ink-4 uppercase">
            Expiry
          </span>
          {expiries.map((e) => (
            <button
              key={e.label}
              onClick={() => setActiveExpiry(e.label)}
              className={`shrink-0 rounded px-2.5 py-1 text-[12px] font-medium whitespace-nowrap transition-colors ${
                e.label === activeExpiry
                  ? 'border-[0.8px] border-brand-text text-brand-text'
                  : 'text-ink-3 hover:bg-sub hover:text-ink'
              }`}
            >
              {formatExpiry(e.label)}
            </button>
          ))}
        </div>

        {/* Fills what the header and the expiries leave of the screen, and keeps
            it — the panel below can no longer take height off it. */}
        <div className="flex min-h-0 flex-1 flex-col">
          {expiry && (
            <OptionChain expiry={expiry} positions={trading.positions} onPick={openTicket} />
          )}
        </div>
      </div>

      {/* As tall as its rows, the way Delta's is: a page of twenty shows twenty.
          Uncapped, because it grows below the fold now rather than upward into
          the chain, and the page scrolls to reach it. */}
      <div className="flex flex-col">
        <BottomPanel
          positions={trading.positions}
          openOrders={trading.openOrders}
          fills={trading.fills}
          productsBySymbol={productsBySymbol}
          onClosePosition={(pos, product) => trading.closePosition(pos, product)}
          onCancelOrder={trading.cancelOrder}
          onPickSymbol={(product) => openTicket(product, 'buy', null)}
        />
      </div>

      {ticket && (
        <OrderTicket
          request={ticket}
          position={trading.positions.find((p) => p.symbol === ticket.product.symbol)}
          available={summary.available}
          onClose={() => setTicket(null)}
          onSubmit={async (args) => {
            await trading.placeOrder(args)
          }}
        />
      )}

      {adminOpen && (
        <AdminPanel
          // Archived accounts included — the panel is where they get restored.
          accounts={accounts.allAccounts}
          selectedId={accounts.selectedId}
          email={email}
          onClose={() => setAdminOpen(false)}
          onSelect={accounts.setSelectedId}
          onCreate={accounts.createAccount}
          onRename={accounts.renameAccount}
          onSetStartingBalance={accounts.setStartingBalance}
          onReset={async (id) => {
            await accounts.resetAccount(id)
            await trading.reload()
          }}
          onSetArchived={accounts.setArchived}
          onDelete={async (id) => {
            await accounts.deleteAccount(id)
            await trading.reload()
          }}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------

function Splash({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-2 text-sm text-ink-3">
      {children}
    </div>
  )
}

function ConfigNotice() {
  return (
    <div className="flex h-full items-center justify-center p-6">
      <div className="max-w-lg rounded-lg border border-brand-text bg-brand/5 p-5 text-sm">
        <h1 className="font-semibold text-brand-text">Supabase is not configured</h1>
        <p className="mt-2 text-ink-2">
          Create <code className="rounded bg-raised-2 px-1 text-xs">.env.local</code> in the project
          root with your project credentials, then restart the dev server:
        </p>
        <pre className="mt-3 overflow-x-auto rounded bg-surface p-3 text-[12px] text-ink">
          {`VITE_SUPABASE_URL=https://xxxx.supabase.co\nVITE_SUPABASE_ANON_KEY=eyJ...`}
        </pre>
        <p className="mt-3 text-xs text-ink-3">
          See <code className="rounded bg-raised-2 px-1">docs/SETUP.md</code> for the full
          setup, including the SQL migration to run.
        </p>
      </div>
    </div>
  )
}
