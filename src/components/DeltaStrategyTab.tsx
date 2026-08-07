import { useEffect, useState } from 'react'

/**
 * The Delta Management Strategy — a configuration and specification surface, not
 * a running engine. It lays out every parameter from the rules spec as an
 * editable field and flags the items still OPEN, so the strategy can be pinned
 * down before any of it is automated. Nothing here trades; the values persist
 * locally so a half-finished setup survives a reload.
 *
 * The nine OPEN items (target_landing especially, which every sizing formula
 * depends on) must be fixed before an engine can be built against this.
 */

const STORE_KEY = 'delta-mgmt-strategy-config'

interface Config {
  sessionOpen: string
  sessionClose: string
  bandLow: number
  bandHigh: number
  buffer: number
  itmTrigger: number
  maxRolls: number
  entryPremium: number
  minPremium: number
  bandDeltaLow: number
  bandDeltaHigh: number
  targetLanding: string // OPEN — kept as text so it can hold '' / a rule note
  nPairs: string // OPEN — number or 'capital-scaled'
}

const DEFAULTS: Config = {
  sessionOpen: '06:00',
  sessionClose: '22:00',
  bandLow: -1,
  bandHigh: 1,
  buffer: 0.4,
  itmTrigger: 5,
  maxRolls: 3,
  entryPremium: 4,
  minPremium: 2,
  bandDeltaLow: 0.15,
  bandDeltaHigh: 0.25,
  targetLanding: '',
  nPairs: '',
}

function load(): Config {
  try {
    const raw = localStorage.getItem(STORE_KEY)
    if (raw) return { ...DEFAULTS, ...JSON.parse(raw) }
  } catch {
    // ignore a corrupt or unavailable store — fall back to defaults
  }
  return DEFAULTS
}

const OPEN_ITEMS = [
  ['target_landing', 'The exact Δp value every correction (ITM roll and band correction) aims to land on — a single number, or a rule per side. Every sizing formula depends on it.'],
  ['Definition of a “roll”', 'For the per-side counter — one triggering pass, or one increment per distinct strike touched within a pass.'],
  ['N — entry pairs', 'How many call/put pairs to sell at daily entry, and whether it is fixed or scaled to capital/margin.'],
  ['Strike tie-break', 'Which strike wins when more than one sits near the entry premium — nearest from above, from below, or absolute closest.'],
  ['Expiry selection', 'Same expiry daily, or roll the nearest weekly/daily contract.'],
  ['Cycle frequency', 'The intraday loop: tick-driven, or polled on an interval.'],
  ['Exit-only re-entry', 'For a side that has gone exit-only and fully unwound — does band correction alone repopulate it, or does it need a deliberate re-entry sizing.'],
  ['Capital / margin breaker', 'A hard circuit breaker distinct from the roll logic, for a gap through several strikes at once.'],
  ['Simultaneous breach', 'When both sides breach the band and margin is limited — which side is corrected first.'],
] as const

export function DeltaStrategyTab() {
  const [cfg, setCfg] = useState<Config>(load)

  useEffect(() => {
    try {
      localStorage.setItem(STORE_KEY, JSON.stringify(cfg))
    } catch {
      // a full or unavailable store is not worth interrupting the edit for
    }
  }, [cfg])

  const set = <K extends keyof Config>(key: K, value: Config[K]) =>
    setCfg((c) => ({ ...c, [key]: value }))

  return (
    <div className="mx-auto w-full max-w-3xl px-4 py-6 sm:px-6">
      <div className="mb-5 flex flex-wrap items-center gap-3">
        <h1 className="text-lg font-bold text-ink">Delta Management Strategy</h1>
        <span className="rounded-sm border border-brand-text/40 bg-brand-muted px-1.5 py-0.5 text-[9px] font-bold tracking-wider text-brand-text uppercase">
          Draft
        </span>
      </div>
      <p className="mb-6 max-w-2xl text-[12px] leading-relaxed text-ink-3">
        A sell-only, delta-band strategy for XAUT options: sell symmetric call/put pairs at the
        daily open, keep net portfolio delta inside the band by rolling in-the-money shorts, and
        fall back to fresh out-of-the-money sells when nothing is left to roll. This screen defines
        the parameters — it does not trade. The items marked OPEN must be fixed before an engine can
        run against it.
      </p>

      <div className="space-y-4">
        <Section title="Session · Sydney (AEST/AEDT)">
          <Grid>
            <TimeField label="Open" value={cfg.sessionOpen} onChange={(v) => set('sessionOpen', v)} />
            <TimeField label="Close" value={cfg.sessionClose} onChange={(v) => set('sessionClose', v)} />
          </Grid>
          <Note>
            Sell the initial pairs at open; flatten every position at close and stand flat
            overnight. Roll counters and touched flags reset each open.
          </Note>
        </Section>

        <Section title="Delta band">
          <Grid>
            <NumField label="Lower (L)" value={cfg.bandLow} step={0.1} onChange={(v) => set('bandLow', v)} />
            <NumField label="Upper (U)" value={cfg.bandHigh} step={0.1} onChange={(v) => set('bandHigh', v)} />
            <NumField label="Buffer (B)" value={cfg.buffer} step={0.05} onChange={(v) => set('buffer', v)} />
          </Grid>
          <Note>Net portfolio delta Δp is kept inside [L, U]; the buffer is how far back from a breached edge a correction lands, if the band edge is used as the landing point.</Note>
        </Section>

        <Section title="Rolls & triggers">
          <Grid>
            <NumField label="ITM trigger (pts)" value={cfg.itmTrigger} step={1} onChange={(v) => set('itmTrigger', v)} />
            <NumField label="Max rolls / side" value={cfg.maxRolls} step={1} onChange={(v) => set('maxRolls', v)} />
          </Grid>
          <Note>A short leg this far in the money is flagged for management. Once a side has used its rolls, it goes exit-only for the rest of the session.</Note>
        </Section>

        <Section title="Premiums (USD)">
          <Grid>
            <NumField label="Entry premium" value={cfg.entryPremium} step={0.5} onChange={(v) => set('entryPremium', v)} />
            <NumField label="Min premium (floor)" value={cfg.minPremium} step={0.5} onChange={(v) => set('minPremium', v)} />
          </Grid>
          <Note>Daily entries and roll replacements target the entry premium; nothing is ever sold below the floor.</Note>
        </Section>

        <Section title="Band-correction delta">
          <Grid>
            <NumField label="Low" value={cfg.bandDeltaLow} step={0.05} onChange={(v) => set('bandDeltaLow', v)} />
            <NumField label="High" value={cfg.bandDeltaHigh} step={0.05} onChange={(v) => set('bandDeltaHigh', v)} />
          </Grid>
          <Note>When no ITM legs remain to roll, correct the band with fresh OTM sells in this delta range — deliberately further out than the entry strikes, so each contract moves Δp less.</Note>
        </Section>

        <Section title="Open — must be fixed before automation">
          <Grid>
            <TextField
              label="target_landing"
              open
              value={cfg.targetLanding}
              placeholder="e.g. 0, or -1 / +1 per side"
              onChange={(v) => set('targetLanding', v)}
            />
            <TextField
              label="N — entry pairs"
              open
              value={cfg.nPairs}
              placeholder="e.g. 3, or capital-scaled"
              onChange={(v) => set('nPairs', v)}
            />
          </Grid>

          <ul className="mt-3 space-y-2">
            {OPEN_ITEMS.map(([name, detail]) => (
              <li key={name} className="flex gap-2 text-[12px] leading-snug">
                <span className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-brand-text" />
                <span>
                  <span className="font-semibold text-ink">{name}</span>
                  <span className="text-ink-3"> — {detail}</span>
                </span>
              </li>
            ))}
          </ul>
        </Section>
      </div>

      <p className="mt-6 text-[10px] text-ink-4">
        Working rules specification, not trading or investment advice. Parameters are illustrative
        and must be reviewed and fixed by the strategy owner before any live or automated use.
      </p>
    </div>
  )
}

// ---------------------------------------------------------------------------

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="rounded-lg border border-line bg-raised p-4">
      <h2 className="mb-3 text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
        {title}
      </h2>
      {children}
    </section>
  )
}

function Grid({ children }: { children: React.ReactNode }) {
  return <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">{children}</div>
}

function FieldShell({ label, open, children }: { label: string; open?: boolean; children: React.ReactNode }) {
  return (
    <label className="flex flex-col gap-1">
      <span className="flex items-center gap-1.5 text-[10px] font-medium text-ink-3">
        {label}
        {open && (
          <span className="rounded-sm bg-brand-muted px-1 text-[8px] font-bold tracking-wider text-brand-text uppercase">
            Open
          </span>
        )}
      </span>
      {children}
    </label>
  )
}

const inputCls =
  'num w-full rounded-md border border-raised-3 bg-surface px-2.5 py-1.5 text-left text-[13px] text-ink focus:border-ink-3 focus:outline-none'

function NumField({
  label,
  value,
  step,
  onChange,
}: {
  label: string
  value: number
  step: number
  onChange: (v: number) => void
}) {
  return (
    <FieldShell label={label}>
      <input
        type="number"
        step={step}
        value={value}
        onChange={(e) => {
          const n = Number(e.target.value)
          if (Number.isFinite(n)) onChange(n)
        }}
        className={inputCls}
      />
    </FieldShell>
  )
}

function TextField({
  label,
  value,
  placeholder,
  open,
  onChange,
}: {
  label: string
  value: string
  placeholder?: string
  open?: boolean
  onChange: (v: string) => void
}) {
  return (
    <FieldShell label={label} open={open}>
      <input
        type="text"
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        className={`${inputCls} placeholder:text-ink-4`}
      />
    </FieldShell>
  )
}

function TimeField({ label, value, onChange }: { label: string; value: string; onChange: (v: string) => void }) {
  return (
    <FieldShell label={label}>
      <input type="time" value={value} onChange={(e) => onChange(e.target.value)} className={inputCls} />
    </FieldShell>
  )
}

function Note({ children }: { children: React.ReactNode }) {
  return <p className="mt-2.5 text-[11px] leading-relaxed text-ink-3">{children}</p>
}
