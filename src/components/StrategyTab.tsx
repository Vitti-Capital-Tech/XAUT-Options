import { useEffect, useRef, useState } from 'react'
import { MONEYNESS_ORDER, type Moneyness } from '../lib/strategy'
import type { StrategyApi } from '../hooks/useAutoStrategy'

/**
 * The auto-strategy's controls — a compact bar above its trades table. The rule
 * is fixed (sell a call on a red 1h candle, a put on a green, stop at twice
 * entry), so there is nothing to toggle there; only whether it runs, the strike,
 * the size and the window. The positions and trade history it produces sit in
 * the panel below, on the strategy's own account.
 */
export function StrategyTab({ strategy }: { strategy: StrategyApi }) {
  const { config, setConfig, armed, setArmed, hasAccount } = strategy

  return (
    <div className="flex flex-wrap items-center gap-x-6 gap-y-4 border-b border-line bg-raised px-5 py-3.5">
      <Field label="Strike">
        <Select
          value={config.moneyness}
          onChange={(m) => setConfig({ moneyness: m })}
          options={MONEYNESS_ORDER.map((m) => ({ value: m, label: label(m) }))}
        />
      </Field>

      <Field label="Quantity">
        <div className="flex h-9 items-center rounded-md border border-raised-3 bg-surface pr-2.5 transition-colors focus-within:border-brand-text hover:border-ink-3">
          <input
            type="number"
            min={0.001}
            step={0.001}
            value={config.qty}
            onChange={(e) => {
              const n = Number(e.target.value)
              if (Number.isFinite(n) && n > 0) setConfig({ qty: n })
            }}
            className="num w-24 bg-transparent px-2.5 text-left text-[13px] text-ink focus:outline-none"
          />
          <span className="text-[11px] font-medium text-ink-3">XAUT</span>
        </div>
      </Field>

      <Field label="Window · IST">
        <div className="flex items-center gap-2">
          <TimePicker value={config.windowStart} onChange={(v) => setConfig({ windowStart: v })} />
          <span className="text-ink-4">–</span>
          <TimePicker value={config.windowEnd} onChange={(v) => setConfig({ windowEnd: v })} />
        </div>
      </Field>

      {/* Run / pause, held to the right so the controls read left-to-right and
          the switch sits on its own. */}
      <div className="ml-auto flex items-center gap-3">
        <span className={`text-[15px] font-semibold ${armed ? 'text-pos' : 'text-ink-3'}`}>
          {armed ? 'Running' : 'Paused'}
        </span>
        <RunSwitch on={armed} onChange={setArmed} disabled={!hasAccount} />
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------

function RunSwitch({
  on,
  onChange,
  disabled,
}: {
  on: boolean
  onChange: (on: boolean) => void
  disabled?: boolean
}) {
  return (
    <button
      role="switch"
      aria-checked={on}
      aria-label="Run auto-trade"
      disabled={disabled}
      title={disabled ? 'Create an auto account first' : on ? 'Pause auto-trade' : 'Run auto-trade'}
      onClick={() => onChange(!on)}
      className={`relative h-7 w-[52px] shrink-0 rounded-full border transition-colors disabled:opacity-30 ${
        on ? 'border-pos-solid bg-pos-solid' : 'border-raised-3 bg-raised-2'
      }`}
    >
      <span
        className={`absolute top-0.5 h-[22px] w-[22px] rounded-full bg-white shadow transition-all ${
          on ? 'left-[26px]' : 'left-0.5'
        }`}
      />
    </button>
  )
}

/**
 * A dark-theme dropdown, since the native select's chrome does not match the
 * terminal. A button shows the choice; a click opens a list that closes on an
 * outside click or a pick.
 */
function Select<T extends string>({
  value,
  options,
  onChange,
}: {
  value: T
  options: { value: T; label: string }[]
  onChange: (value: T) => void
}) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  useOutsideClose(ref, open, () => setOpen(false))

  const current = options.find((o) => o.value === value)

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={`flex h-9 w-28 items-center justify-between gap-2 rounded-md border bg-surface px-2.5 text-[13px] text-ink transition-colors hover:border-ink-3 ${
          open ? 'border-brand-text' : 'border-raised-3'
        }`}
      >
        <span className="num">{current?.label}</span>
        <Chevron open={open} />
      </button>

      {open && (
        <div className="absolute z-30 mt-1 max-h-60 w-full overflow-auto rounded-md border border-raised-3 bg-raised py-1 shadow-delta-lg">
          {options.map((o) => {
            const active = o.value === value
            return (
              <button
                key={o.value}
                type="button"
                onClick={() => {
                  onChange(o.value)
                  setOpen(false)
                }}
                className={`num flex w-full items-center px-3 py-1.5 text-left text-[13px] transition-colors ${
                  active ? 'bg-raised-2 text-brand-text' : 'text-ink-2 hover:bg-raised-2 hover:text-ink'
                }`}
              >
                {o.label}
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}

const ROW_H = 28
const HOURS = Array.from({ length: 24 }, (_, i) => String(i).padStart(2, '0'))
const MINUTES = Array.from({ length: 60 }, (_, i) => String(i).padStart(2, '0'))

/**
 * A dark time picker, so the field carries a clock without the native popup's
 * white chrome. The button shows HH:MM and a clock; a click opens two scroll
 * columns — hours and minutes — that centre on the current value.
 */
function TimePicker({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)
  const hourCol = useRef<HTMLDivElement>(null)
  const minCol = useRef<HTMLDivElement>(null)
  useOutsideClose(ref, open, () => setOpen(false))

  const m = /^(\d{1,2}):(\d{2})$/.exec(value)
  const hh = m ? m[1].padStart(2, '0') : '00'
  const mm = m ? m[2] : '00'

  // Centre each column on its current value when the picker opens.
  useEffect(() => {
    if (!open) return
    const centre = (col: HTMLDivElement | null, idx: number) => {
      if (col) col.scrollTop = idx * ROW_H - col.clientHeight / 2 + ROW_H / 2
    }
    centre(hourCol.current, Number(hh))
    centre(minCol.current, Number(mm))
  }, [open, hh, mm])

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={`flex h-9 items-center gap-2 rounded-md border bg-surface px-2.5 text-[13px] text-ink transition-colors hover:border-ink-3 ${
          open ? 'border-brand-text' : 'border-raised-3'
        }`}
      >
        <span className="num">
          {hh}:{mm}
        </span>
        <ClockIcon />
      </button>

      {open && (
        <div className="absolute z-30 mt-1 flex overflow-hidden rounded-md border border-raised-3 bg-raised shadow-delta-lg">
          <TimeColumn
            colRef={hourCol}
            items={HOURS}
            selected={hh}
            onPick={(h) => onChange(`${h}:${mm}`)}
          />
          <span className="w-px bg-line" />
          <TimeColumn
            colRef={minCol}
            items={MINUTES}
            selected={mm}
            onPick={(min) => onChange(`${hh}:${min}`)}
          />
        </div>
      )}
    </div>
  )
}

function TimeColumn({
  colRef,
  items,
  selected,
  onPick,
}: {
  colRef: React.RefObject<HTMLDivElement | null>
  items: string[]
  selected: string
  onPick: (v: string) => void
}) {
  return (
    <div ref={colRef} className="max-h-[168px] w-12 overflow-y-auto py-1">
      {items.map((it) => {
        const active = it === selected
        return (
          <button
            key={it}
            type="button"
            onClick={() => onPick(it)}
            style={{ height: ROW_H }}
            className={`num flex w-full items-center justify-center text-[12px] transition-colors ${
              active ? 'bg-raised-2 font-semibold text-brand-text' : 'text-ink-2 hover:bg-raised-2 hover:text-ink'
            }`}
          >
            {it}
          </button>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------

/** Close a popover on a click outside its ref while it is open. */
function useOutsideClose(
  ref: React.RefObject<HTMLElement | null>,
  open: boolean,
  close: () => void,
) {
  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (!ref.current?.contains(e.target as Node)) close()
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [ref, open, close])
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      width="10"
      height="10"
      viewBox="0 0 12 12"
      fill="none"
      className={`shrink-0 text-ink-3 transition-transform ${open ? 'rotate-180' : ''}`}
      aria-hidden
    >
      <path d="M3 4.5L6 7.5L9 4.5" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function ClockIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 16 16" fill="none" className="shrink-0 text-ink-3" aria-hidden>
      <circle cx="8" cy="8" r="6.25" stroke="currentColor" strokeWidth="1.3" />
      <path d="M8 4.75V8L10.25 9.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
        {label}
      </span>
      {children}
    </div>
  )
}

/** ITM2 → 'ITM 2', ATM → 'ATM', OTM1 → 'OTM 1'. */
function label(m: Moneyness): string {
  return m === 'ATM' ? 'ATM' : `${m.slice(0, 3)} ${m.slice(3)}`
}
