import { useEffect, useId, useRef, useState } from 'react'

/**
 * The controls a strategy bar is built from — a labelled field, a dark dropdown,
 * a dark time picker, a number box and the run switch.
 *
 * They live here rather than in one tab because both strategies wear the same
 * bar: the auto strategy's row of four, and the delta strategy's much longer set
 * of band and roll parameters. The native select and time popups bring white
 * chrome that does not belong in the terminal, which is why these are hand-built.
 */

/**
 * A labelled control, with an optional `?` that explains the setting on hover.
 *
 * Every parameter here reads as jargon until someone tells you what it does, and
 * a strategy bar is exactly where a wrong guess costs money — so the explanation
 * sits on the label rather than in a document nobody has open.
 */
export function Field({
  label,
  help,
  children,
}: {
  label: string
  help?: string
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="flex items-center gap-1 text-[10px] font-semibold tracking-[0.14em] text-ink-3 uppercase">
        {label}
        {help && <HelpTip label={label} text={help} />}
      </span>
      {children}
    </div>
  )
}

/**
 * The `?` and its bubble. Shown on hover for a mouse and on focus for a keyboard
 * or a tap — no click handler, because a tap focuses the button and a tap
 * elsewhere blurs it, which is the behaviour we want anyway.
 *
 * Hand-built rather than a `title` attribute: the native tooltip is slow to
 * appear, cannot be reached by keyboard, and brings the same white chrome the
 * selects here already avoid.
 */
function HelpTip({ label, text }: { label: string; text: string }) {
  const [hover, setHover] = useState(false)
  const [focus, setFocus] = useState(false)
  const id = useId()
  const open = hover || focus

  return (
    <span className="relative inline-flex">
      <button
        type="button"
        aria-label={`What does ${label} do?`}
        aria-expanded={open}
        aria-describedby={open ? id : undefined}
        onMouseEnter={() => setHover(true)}
        onMouseLeave={() => setHover(false)}
        onFocus={() => setFocus(true)}
        onBlur={() => setFocus(false)}
        onKeyDown={(e) => {
          if (e.key === 'Escape') e.currentTarget.blur()
        }}
        className={`flex h-[13px] w-[13px] items-center justify-center rounded-full border text-[9px] leading-none font-bold transition-colors ${
          open ? 'border-brand-text text-brand-text' : 'border-ink-4 text-ink-4 hover:text-ink-2'
        }`}
      >
        ?
      </button>

      {open && (
        <span
          id={id}
          role="tooltip"
          className="absolute top-[19px] left-0 z-40 w-64 rounded-md border border-raised-3 bg-raised px-3 py-2.5 text-[11.5px] leading-[1.5] font-normal tracking-normal text-ink-2 normal-case shadow-delta-lg"
        >
          {text}
        </span>
      )}
    </span>
  )
}

/**
 * A dark-theme dropdown, since the native select's chrome does not match the
 * terminal. A button shows the choice; a click opens a list that closes on an
 * outside click or a pick.
 */
export function Select<T extends string>({
  value,
  options,
  onChange,
  width = 'w-28',
}: {
  value: T
  options: { value: T; label: string }[]
  onChange: (value: T) => void
  width?: string
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
        className={`flex h-9 ${width} items-center justify-between gap-2 rounded-md border bg-surface px-2.5 text-[13px] text-ink transition-colors hover:border-ink-3 ${
          open ? 'border-brand-text' : 'border-raised-3'
        }`}
      >
        <span className="num truncate">{current?.label ?? value}</span>
        <Chevron open={open} />
      </button>

      {open && (
        <div className="absolute z-30 mt-1 max-h-60 w-full min-w-max overflow-auto rounded-md border border-raised-3 bg-raised py-1 shadow-delta-lg">
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
                className={`num flex w-full items-center px-3 py-1.5 text-left text-[13px] whitespace-nowrap transition-colors ${
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

/**
 * A number box in the same shell as the dropdowns, with an optional unit tail.
 *
 * Typing is kept as text and only committed when it parses, so clearing the box
 * to retype does not slam a zero into the config on the way through.
 */
export function NumInput({
  value,
  onChange,
  step = 1,
  min,
  max,
  unit,
  width = 'w-20',
}: {
  value: number
  onChange: (v: number) => void
  step?: number
  min?: number
  /**
   * Upper bound, checked on commit as `min` is. Worth setting wherever the database
   * has a matching constraint: a value it will reject is not saved, and the write
   * fails after the box already shows the new number.
   */
  max?: number
  unit?: string
  width?: string
}) {
  const [draft, setDraft] = useState<string | null>(null)

  return (
    <div className="flex h-9 items-center rounded-md border border-raised-3 bg-surface pr-2.5 transition-colors focus-within:border-brand-text hover:border-ink-3">
      <input
        type="number"
        step={step}
        min={min}
        max={max}
        value={draft ?? value}
        onChange={(e) => {
          setDraft(e.target.value)
          const v = Number(e.target.value)
          if (
            e.target.value !== '' &&
            Number.isFinite(v) &&
            (min === undefined || v >= min) &&
            (max === undefined || v <= max)
          ) {
            onChange(v)
          }
        }}
        onBlur={() => setDraft(null)}
        className={`num ${width} bg-transparent px-2.5 text-left text-[13px] text-ink focus:outline-none`}
      />
      {unit && <span className="text-[11px] font-medium text-ink-3">{unit}</span>}
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
export function TimePicker({ value, onChange }: { value: string; onChange: (v: string) => void }) {
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

/**
 * ISO weekday numbers, Monday 1 to Sunday 7 — `extract(isodow)`'s numbering, and
 * what the settings column stores, so the two never need translating.
 */
export const ISO_DAYS = [1, 2, 3, 4, 5, 6, 7] as const
const DAY_INITIALS = ['M', 'T', 'W', 'T', 'F', 'S', 'S']
const DAY_NAMES = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday']

/**
 * Which days of the week a strategy trades — seven toggles in one shell, so the
 * whole week reads at a glance rather than as a dropdown you have to open.
 *
 * The days are the *session's* own, read on its own clock — IST for both engines.
 * An empty selection is a valid off state, and the engines read it as one: no day
 * is a trading day, so nothing is ever opened.
 */
export function DayPicker({ value, onChange }: { value: number[]; onChange: (v: number[]) => void }) {
  const set = new Set(value)
  const toggle = (d: number) => {
    const next = new Set(set)
    if (next.has(d)) next.delete(d)
    else next.add(d)
    onChange(ISO_DAYS.filter((x) => next.has(x)))
  }

  return (
    <div className="flex h-9 items-center gap-0.5 rounded-md border border-raised-3 bg-surface px-1">
      {ISO_DAYS.map((d, i) => {
        const on = set.has(d)
        return (
          <button
            key={d}
            type="button"
            aria-pressed={on}
            title={DAY_NAMES[i]}
            onClick={() => toggle(d)}
            className={`num h-7 w-6 rounded text-[12px] transition-colors ${
              on
                ? 'bg-raised-2 font-semibold text-brand-text'
                : 'text-ink-4 hover:bg-raised-2 hover:text-ink-2'
            }`}
          >
            {DAY_INITIALS[i]}
          </button>
        )
      })}
    </div>
  )
}

/**
 * A hairline between groups of controls on a strategy bar.
 *
 * Sixteen fields in one wrapping row read as a wall; the rules split into a few
 * plain groups — when it trades, what it sells, the band, the rolls, the exits —
 * and a rule at each seam makes that structure visible without a second row of
 * headings.
 *
 * Hidden below `lg`, where the row wraps enough that a rule would land mid-line and
 * separate nothing.
 */
export function GroupRule() {
  return <span aria-hidden className="hidden h-9 w-px self-center bg-line lg:block" />
}

export function RunSwitch({
  on,
  onChange,
  disabled,
  title,
}: {
  on: boolean
  onChange: (on: boolean) => void
  disabled?: boolean
  title?: string
}) {
  return (
    <button
      role="switch"
      aria-checked={on}
      aria-label="Run strategy"
      disabled={disabled}
      title={title ?? (on ? 'Pause' : 'Run')}
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

// ---------------------------------------------------------------------------

/** Close a popover on a click outside its ref while it is open. */
export function useOutsideClose(
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

export function Chevron({ open }: { open: boolean }) {
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

export function ClockIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 16 16" fill="none" className="shrink-0 text-ink-3" aria-hidden>
      <circle cx="8" cy="8" r="6.25" stroke="currentColor" strokeWidth="1.3" />
      <path d="M8 4.75V8L10.25 9.5" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}
