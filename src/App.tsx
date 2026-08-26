import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Login } from './components/Login'
import { TopBar, type Page } from './components/TopBar'
import { OptionChain } from './components/OptionChain'
import { OrderTicket, type TicketRequest } from './components/OrderTicket'
import { BottomPanel } from './components/BottomPanel'
import { StrategyTab } from './components/StrategyTab'
import { DeltaStrategyTab } from './components/DeltaStrategyTab'
import { AdminPanel } from './components/AdminPanel'
import { Toasts } from './components/Toasts'
import { useAuth } from './hooks/useAuth'
import { useAccounts } from './hooks/useAccounts'
import { useTrading } from './hooks/useTrading'
import { useAutoStrategy } from './hooks/useAutoStrategy'
import { useDeltaStrategy } from './hooks/useDeltaStrategy'
import { useKeywordTrigger } from './hooks/useKeywordTrigger'
import { market, useMarketTick } from './lib/marketStore'
import {
  MarketStream,
  PERP_SYMBOL,
  fetchExpiries,
  fetchPerp,
  fetchPerpTicker,
  fetchTickers,
  formatExpiry,
  type Expiry,
  type Product,
} from './lib/delta'
import { pickExpiry } from './lib/deltaStrategy'
import { shortImRate, summarizeAccount, type Side } from './engine/paper'
import { supabaseConfigured } from './lib/supabase'
import { ADMIN_KEYWORD } from './lib/admin'

/** Same namespace the selected account uses, so one prefix owns our storage. */
const PAGE_KEY = 'delta-paper.page'

export default function App() {
  const { session, user, loading: authLoading } = useAuth()

  if (!supabaseConfigured) return <ConfigNotice />
  if (authLoading) return <Splash>Loading…</Splash>
  if (!session) return <Login />
  return <Terminal userId={user!.id} email={user!.email} />
}

// ---------------------------------------------------------------------------

function Terminal({ userId, email }: { userId: string; email: string | undefined }) {
  // Four independent books, one per page: the chain trades manual accounts, the
  // auto strategy trades auto accounts, and the delta strategy trades two books
  // of its own — the delta account, which corrects its delta with options, and
  // the futures account, which corrects it by buying and selling the XAUT
  // perpetual instead. Same tables throughout, partitioned by account kind —
  // nothing is shared between them.
  const manualAccounts = useAccounts(userId, 'manual')
  const autoAccounts = useAccounts(userId, 'auto')
  const deltaAccounts = useAccounts(userId, 'delta')
  const futuresAccounts = useAccounts(userId, 'futures')
  const manualTrading = useTrading(manualAccounts.selectedId, manualAccounts.reload)
  const autoTrading = useTrading(autoAccounts.selectedId, autoAccounts.reload)
  const deltaTrading = useTrading(deltaAccounts.selectedId, deltaAccounts.reload)
  const futuresTrading = useTrading(futuresAccounts.selectedId, futuresAccounts.reload)

  const [expiries, setExpiries] = useState<Expiry[]>([])
  const [activeExpiry, setActiveExpiry] = useState<string | null>(null)
  const [marketError, setMarketError] = useState<string | null>(null)
  const [ticket, setTicket] = useState<TicketRequest | null>(null)
  // Always starts closed, whichever page is restored — the panel is opened
  // deliberately, never landed on.
  const [adminOpen, setAdminOpen] = useState(false)
  // Which top-level page is showing, remembered across reloads — watching a
  // strategy means refreshing the tab, and being thrown back to the chain every
  // time is its own small tax. Validated against the union rather than trusted,
  // so a stale or hand-edited value cannot render nothing.
  const [page, setPage] = useState<Page>(() => {
    const saved = localStorage.getItem(PAGE_KEY)
    return saved === 'chain' || saved === 'strategy' || saved === 'delta' || saved === 'futures'
      ? saved
      : 'chain'
  })

  useEffect(() => {
    localStorage.setItem(PAGE_KEY, page)
  }, [page])

  // The book the header, ticket and admin panel act on — whichever page is up.
  const accounts =
    page === 'chain'
      ? manualAccounts
      : page === 'strategy'
        ? autoAccounts
        : page === 'delta'
          ? deltaAccounts
          : futuresAccounts
  const trading =
    page === 'chain'
      ? manualTrading
      : page === 'strategy'
        ? autoTrading
        : page === 'delta'
          ? deltaTrading
          : futuresTrading

  const tick = useMarketTick()

  // Typing the admin keyword anywhere opens the account manager. Disabled while
  // the order ticket is up so the ticket's own inputs keep focus behaviour.
  useKeywordTrigger(ADMIN_KEYWORD, () => setAdminOpen(true), !ticket)

  // ---- Market data bootstrap -----------------------------------------------
  // Refetched on an interval, not just at mount: Delta lists new strikes (and
  // rolls expiries) through the day, and a chain frozen at page-load would never
  // show them — you would have to reload the tab to trade a strike opened after
  // you arrived. The websocket only streams quotes for symbols that already
  // exist in this list, so the list itself has to be refreshed over HTTP.
  const loadedOnce = useRef(false)
  useEffect(() => {
    let active = true

    const load = async () => {
      try {
        const [exps, tickers] = await Promise.all([fetchExpiries(), fetchTickers()])
        if (!active) return
        if (exps.length === 0) {
          setMarketError('No live XAUT option contracts are listed right now.')
          return
        }
        market.upsertMany(tickers)
        setExpiries(exps)
        // Keep the chosen expiry if it is still listed; otherwise fall to the
        // nearest, so a settled same-day expiry advances on its own rather than
        // leaving the chain blank.
        setActiveExpiry((current) =>
          current && exps.some((e) => e.label === current) ? current : exps[0].label,
        )
        loadedOnce.current = true
        setMarketError(null)
      } catch (err) {
        // A failed refresh must not blank a chain that is already up — only
        // surface the error when nothing has ever loaded.
        if (active && !loadedOnce.current) {
          setMarketError(err instanceof Error ? err.message : 'Could not load market data')
        }
      }
    }

    void load()
    const id = setInterval(load, 60_000)
    return () => {
      active = false
      clearInterval(id)
    }
  }, [])

  // ---- The perpetual -------------------------------------------------------
  // Fetched on its own, not filtered out of the chain's product list: it is one
  // contract behind one page, and tying it to the chain's much larger bootstrap
  // would take the futures page down every time that call had a bad minute.
  // Refetched hourly only to pick up a margin or leverage change — the contract
  // itself does not roll, which is the whole point of a perpetual.
  const [perp, setPerp] = useState<Product | null>(null)
  const [perpError, setPerpError] = useState<string | null>(null)

  useEffect(() => {
    let active = true

    const load = async () => {
      try {
        const [product, ticker] = await Promise.all([fetchPerp(), fetchPerpTicker()])
        if (!active) return
        market.upsert(ticker)
        setPerp(product)
        setPerpError(null)
      } catch (err) {
        // Same rule the chain follows: a failed refresh must not blank a page
        // that is already up.
        if (active && !perp) {
          setPerpError(err instanceof Error ? err.message : 'Could not load the perpetual contract')
        }
      }
    }

    void load()
    const id = setInterval(load, 3_600_000)
    return () => {
      active = false
      clearInterval(id)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // Every product across every expiry, plus the perpetual, for position/order
  // lookups. The perpetual belongs in here as much as any strike does: it is
  // what the positions table closes against and what the fill engine prices.
  const productsBySymbol = useMemo(() => {
    const m = new Map<string, Product>()
    for (const exp of expiries) {
      for (const p of exp.calls.values()) m.set(p.symbol, p)
      for (const p of exp.puts.values()) m.set(p.symbol, p)
    }
    if (perp) m.set(perp.symbol, perp)
    return m
  }, [expiries, perp])

  // The fill engine needs product metadata (contract value, fee rates) by symbol
  // — for both books, since either can hold a position needing a fill.
  useEffect(() => {
    const products = [...productsBySymbol.values()]
    manualTrading.registerProducts(products)
    autoTrading.registerProducts(products)
    deltaTrading.registerProducts(products)
    futuresTrading.registerProducts(products)
  }, [productsBySymbol, manualTrading, autoTrading, deltaTrading, futuresTrading])

  const expiry = expiries.find((e) => e.label === activeExpiry) ?? null

  // ---- Pricing helpers -----------------------------------------------------
  // Declared here rather than beside the account summary below because the delta
  // strategy's readout needs them, and that hook is set up further up the body.
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

  // ---- Auto strategy -------------------------------------------------------
  // Just the settings the server-side engine watches (see 0008_strategy_engine):
  // arming, strike, size and window for the selected auto account. The placing
  // and the stops run on the server, so nothing here depends on the tab.
  const strategy = useAutoStrategy(autoAccounts.selectedId, autoTrading.positions, autoTrading.reload)

  // ---- Delta management strategy -------------------------------------------
  // Settings and a readout only. The cycle itself runs on pg_cron (see
  // 0012_delta_strategy_engine), so the strategy trades with no tab open; the
  // positions here are what it needs to show Δp against the band.
  const deltaStrategy = useDeltaStrategy(
    deltaAccounts.selectedId,
    {
      positions: deltaTrading.positions,
      expiries,
      // The delta book's own cash, not the header's selected account: the margin
      // guard measures that book's blocked margin against that book's equity.
      cashBalance: Number(deltaAccounts.selected?.cash_balance ?? 0),
      imRateFor,
    },
    deltaTrading.reload,
  )
  const deltaExpiry = pickExpiry(expiries, deltaStrategy.config)

  // ---- The same strategy, hedged with futures ------------------------------
  // One hook, one settings table and one server-side engine; `futures` is what
  // tells all three that a breach of the band is answered by trading the
  // perpetual rather than by rolling an option. The engine reads the same thing
  // off the account's kind, so the page and the rule cannot disagree
  // (0044_futures_delta_hedge).
  const futuresStrategy = useDeltaStrategy(
    futuresAccounts.selectedId,
    {
      positions: futuresTrading.positions,
      expiries,
      cashBalance: Number(futuresAccounts.selected?.cash_balance ?? 0),
      imRateFor,
    },
    futuresTrading.reload,
    'futures',
  )
  const futuresExpiry = pickExpiry(expiries, futuresStrategy.config)

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
    const addChain = (e: Expiry | null) => {
      if (!e) return
      for (const p of e.calls.values()) symbols.add(p.symbol)
      for (const p of e.puts.values()) symbols.add(p.symbol)
    }
    addChain(expiry)
    // Both delta books pick strikes by premium across their whole expiry, so
    // those chains have to be streamed even while the chain page is showing a
    // different one. The futures book sells the same option pair at the open —
    // only its delta correction is different.
    addChain(deltaExpiry)
    addChain(futuresExpiry)
    // Every book's holdings, so P&L, limit fills and the strategies' marks keep
    // ticking whichever page is up.
    for (const p of manualTrading.positions) symbols.add(p.symbol)
    for (const o of manualTrading.openOrders) symbols.add(o.symbol)
    for (const p of autoTrading.positions) symbols.add(p.symbol)
    for (const o of autoTrading.openOrders) symbols.add(o.symbol)
    for (const p of deltaTrading.positions) symbols.add(p.symbol)
    for (const o of deltaTrading.openOrders) symbols.add(o.symbol)
    for (const p of futuresTrading.positions) symbols.add(p.symbol)
    for (const o of futuresTrading.openOrders) symbols.add(o.symbol)
    // Always, held or not: it is a single symbol, and the futures book needs its
    // mark to value a hedge and its funding rate to say what that hedge will pay
    // — the second of which is worth showing before there is a hedge at all. It
    // is also the one contract whose mark keeps costing money while nobody is
    // looking, since funding does not wait for the tab.
    symbols.add(PERP_SYMBOL)
    stream.setSymbols([...symbols])
  }, [
    stream,
    expiry,
    manualTrading.positions,
    manualTrading.openOrders,
    autoTrading.positions,
    autoTrading.openOrders,
    deltaTrading.positions,
    deltaTrading.openOrders,
    futuresTrading.positions,
    futuresTrading.openOrders,
    deltaExpiry,
    futuresExpiry,
  ])

  // ---- Account summary ----------------------------------------------------
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

  // Shared across both pages, so the nav, the account switcher and the feed
  // badge stay put as you move between the chain and the bot.
  const topBar = (
    <TopBar
      accounts={accounts.accounts}
      selected={accounts.selected}
      summary={summary}
      email={email}
      page={page}
      onNavigate={setPage}
      onSelect={accounts.setSelectedId}
      onCreate={accounts.createAccount}
      onSetBalance={accounts.setStartingBalance}
      onReset={async (id) => {
        await accounts.resetAccount(id)
        await trading.reload()
      }}
      onArchive={(id) => accounts.setArchived(id, true)}
      onOpenAdmin={() => setAdminOpen(true)}
    />
  )

  return (
    /* The page scrolls. The header, the expiries and the chain fill exactly one
       screen, and the panel grows downward from there rather than taking height
       off the chain — so a long list of positions is something you scroll to, not
       something that squeezes the book. */
    <div className="flex flex-col">
      {page === 'chain' ? (
        <>
          <div className="flex h-screen flex-col">
            {topBar}

            <ExpiryTabs expiries={expiries} active={activeExpiry} onSelect={setActiveExpiry} />

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
              fills={trading.fills}
              fillsTruncated={trading.fillsTruncated}
              onExportDay={(day) => trading.exportDay(day, manualAccounts.selected?.name ?? 'account')}
              productsBySymbol={productsBySymbol}
              onClosePosition={(pos, product) => trading.closePosition(pos, product)}
              onSetTpSl={trading.setTpSl}
              onPickSymbol={(product) => openTicket(product, 'buy', null)}
            />
          </div>
        </>
      ) : page === 'strategy' ? (
        <>
          {/* Same shape as the chain page: header, controls, expiries and chain
              take the screen, and the book grows below the fold rather than
              squeezing the chain.

              min-h-screen rather than h-screen, unlike the chain page, because the
              control bar above is tall and wraps. On a short viewport h-screen
              would resolve the chain's flex-1 to nothing and it would vanish; this
              way the section grows past the screen instead and the page scrolls. */}
          <div className="flex min-h-screen flex-col">
            {topBar}
            <StrategyTab strategy={strategy} expiries={expiries} />
            <ExpiryTabs expiries={expiries} active={activeExpiry} onSelect={setActiveExpiry} />
            {/* A floor as well as flex-1, for the same reason. */}
            <div className="flex min-h-[320px] flex-1 flex-col">
              {expiry && (
                <OptionChain
                  expiry={expiry}
                  // The auto book, so a held strike is marked on the page that
                  // trades it — not the chain page's manual positions.
                  positions={autoTrading.positions}
                  onPick={openTicket}
                />
              )}
            </div>
          </div>

          {/* The strategy's own book — its positions and trade history, on the
              auto account, entirely separate from the chain's. */}
          <div className="flex flex-col">
            <BottomPanel
              positions={autoTrading.positions}
              fills={autoTrading.fills}
              fillsTruncated={autoTrading.fillsTruncated}
              onExportDay={(day) => autoTrading.exportDay(day, autoAccounts.selected?.name ?? 'account')}
              productsBySymbol={productsBySymbol}
              emptyPositions="No open positions yet. Set it Running and it sells on each closed 1h candle."
              onClosePosition={(pos, product) => autoTrading.closePosition(pos, product)}
              onSetTpSl={autoTrading.setTpSl}
              onPickSymbol={(product) => openTicket(product, 'buy', null)}
            />
          </div>
        </>
      ) : page === 'delta' ? (
        <>
          {/* Same shape and the same min-h-screen reasoning as the auto page — and
              more so here, since this control bar carries the most fields of the
              three and wraps to several rows on a narrow window. */}
          <div className="flex min-h-screen flex-col">
            {topBar}
            <DeltaStrategyTab strategy={deltaStrategy} expiries={expiries} />
            <ExpiryTabs expiries={expiries} active={activeExpiry} onSelect={setActiveExpiry} />
            <div className="flex min-h-[320px] flex-1 flex-col">
              {expiry && (
                <OptionChain
                  expiry={expiry}
                  // The delta book, so a held strike is marked on the page that
                  // trades it.
                  positions={deltaTrading.positions}
                  onPick={openTicket}
                />
              )}
            </div>
          </div>

          {/* The delta strategy's own book, on the delta account — separate
              again from both the chain's and the auto strategy's. Why each leg
              was opened and each exit taken rides on the rows themselves. */}
          <div className="flex flex-col">
            <BottomPanel
              positions={deltaTrading.positions}
              fills={deltaTrading.fills}
              fillsTruncated={deltaTrading.fillsTruncated}
              onExportDay={(day) => deltaTrading.exportDay(day, deltaAccounts.selected?.name ?? 'account')}
              productsBySymbol={productsBySymbol}
              emptyPositions="No open positions. Set it Running and it sells its first pair at the session open."
              onClosePosition={(pos, product) => deltaTrading.closePosition(pos, product)}
              onSetTpSl={deltaTrading.setTpSl}
              onPickSymbol={(product) => openTicket(product, 'buy', null)}
            />
          </div>
        </>
      ) : (
        <>
          {/* The same page as the delta strategy's, because it is the same
              strategy: one control bar, the expiry strip and the chain it sells
              its pair from. What differs is under the hood — a breach is answered
              by trading the perpetual — and on the bar, where the roll controls
              give way to the hedge's leverage, size and funding.

              min-h-screen for the same reason as the other two strategy pages:
              the bar is tall and wraps, and h-screen would resolve the chain's
              flex-1 to nothing on a short viewport. */}
          <div className="flex min-h-screen flex-col">
            {topBar}
            <DeltaStrategyTab
              strategy={futuresStrategy}
              expiries={expiries}
              mode="futures"
              perp={perp}
              hedgePosition={futuresTrading.positions.find((p) => p.symbol === PERP_SYMBOL)}
            />
            {/* The contract behind the hedge, when its own fetch has failed. Worth
                saying rather than swallowing, but worth being precise about: the
                engine polls the perpetual server-side and hedges regardless. What
                is degraded here is the bar — the leverage ceiling and the funding
                clock are read off this product. */}
            {perpError && (
              <div className="border-b border-line bg-raised px-5 py-2 text-[12px] text-neg">
                The XAUT perpetual did not load — {perpError}. Hedging continues
                server-side; the leverage cap and funding clock above are unknown until it does.
              </div>
            )}
            <ExpiryTabs expiries={expiries} active={activeExpiry} onSelect={setActiveExpiry} />
            <div className="flex min-h-[320px] flex-1 flex-col">
              {expiry && (
                <OptionChain
                  expiry={expiry}
                  // The futures book, so a held strike is marked on the page that
                  // trades it.
                  positions={futuresTrading.positions}
                  onPick={openTicket}
                />
              )}
            </div>
          </div>

          {/* The futures book, on the futures account — separate again from the
              other three. Read in the options table rather than the perpetual
              one: this book is a short strangle that happens to carry a hedge,
              so the greeks and the reason each leg is on the book are what it is
              read by. The hedge's own row shows a delta of exactly its size and
              no gamma, which is what a linear contract has. */}
          <div className="flex flex-col">
            <BottomPanel
              positions={futuresTrading.positions}
              fills={futuresTrading.fills}
              fillsTruncated={futuresTrading.fillsTruncated}
              onExportDay={(day) => futuresTrading.exportDay(day, futuresAccounts.selected?.name ?? 'account')}
              productsBySymbol={productsBySymbol}
              emptyPositions="No open positions. Set it Running and it sells its first pair at the session open."
              onClosePosition={(pos, product) => futuresTrading.closePosition(pos, product)}
              onSetTpSl={futuresTrading.setTpSl}
              onPickSymbol={(product) => openTicket(product, 'buy', null)}
            />
          </div>
        </>
      )}

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

      {/* Mounted once, outside the page switch, so a confirmation raised on one
          page survives a move to another. */}
      <Toasts />
    </div>
  )
}

// ---------------------------------------------------------------------------

/**
 * The expiry strip above the chain. Extracted because all three pages carry the
 * chain now, and one selection is shared across them — browse to a date on the
 * strategy page and the chain page is already showing it when you switch.
 *
 * Deliberately not tied to a strategy's own traded expiry: the strip is for
 * reading the market, and a picker that silently moved under you when the
 * strategy rolled its date would be worse than one that stays where you put it.
 * The strategy's own date is on its control bar, a few pixels up.
 */
function ExpiryTabs({
  expiries,
  active,
  onSelect,
}: {
  expiries: Expiry[]
  active: string | null
  onSelect: (label: string) => void
}) {
  return (
    <div className="flex shrink-0 items-center gap-1 overflow-x-auto border-b border-line bg-surface px-2 py-1.5">
      <span className="mr-1 shrink-0 text-[10px] tracking-wider text-ink-4 uppercase">Expiry</span>
      {expiries.map((e) => (
        <button
          key={e.label}
          onClick={() => onSelect(e.label)}
          className={`shrink-0 rounded px-2.5 py-1 text-[12px] font-medium whitespace-nowrap transition-colors ${
            e.label === active
              ? 'border-[0.8px] border-brand-text text-brand-text'
              : 'text-ink-3 hover:bg-sub hover:text-ink'
          }`}
        >
          {formatExpiry(e.label)}
        </button>
      ))}
    </div>
  )
}

function Splash({ children }: { children: React.ReactNode }) {
  // min-h-screen, not h-full: #root is min-height now, so h-full has no definite
  // height to fill and the splash would collapse to the top of the page.
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-2 text-sm text-ink-3">
      {children}
    </div>
  )
}

function ConfigNotice() {
  return (
    <div className="flex min-h-screen items-center justify-center p-6">
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
