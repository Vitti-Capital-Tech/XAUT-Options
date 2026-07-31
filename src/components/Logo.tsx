/**
 * The mark: a gold token with a rising line cut out of it.
 *
 * XAUT is tokenised gold, so the mark is a token and the palette is bullion
 * rather than the terminal's orange. It is drawn on a 32-unit grid with one
 * shape and one stroke, because the same geometry has to survive being a 16px
 * favicon — see public/favicon.svg, which is this file minus the sheen. A
 * favicon is never large enough, or on screen long enough, for a sheen to read.
 */

/** Pointy-top hexagon, centred on 16,16. */
const TOKEN = 'M16 2.2 L27.95 9.1 L27.95 22.9 L16 29.8 L4.05 22.9 L4.05 9.1 Z'

export function Logo({ size = 26 }: { size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 32 32"
      aria-hidden="true"
      className="shrink-0 drop-shadow-[0_1px_3px_rgba(0,0,0,0.5)]"
    >
      <defs>
        <linearGradient id="xaut-gold" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0%" stopColor="#ffeeb8" />
          <stop offset="32%" stopColor="#f4c556" />
          <stop offset="66%" stopColor="#dc9a17" />
          <stop offset="100%" stopColor="#9d6208" />
        </linearGradient>
        {/* The sheen: transparent at both edges so it reads as a crossing
            highlight rather than a bar sliding over the mark. */}
        <linearGradient id="xaut-sheen" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0%" stopColor="#ffffff" stopOpacity="0" />
          <stop offset="50%" stopColor="#ffffff" stopOpacity="0.8" />
          <stop offset="100%" stopColor="#ffffff" stopOpacity="0" />
        </linearGradient>
        <clipPath id="xaut-token">
          <path d={TOKEN} />
        </clipPath>
      </defs>

      <path d={TOKEN} fill="url(#xaut-gold)" />
      <path
        d="M10.2 20.4 L14.4 15.4 L18 18.3 L22.2 11.3"
        fill="none"
        stroke="#2a1a04"
        strokeWidth="2.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />

      <g clipPath="url(#xaut-token)">
        <g transform="rotate(18 16 16)">
          <rect className="logo-sheen" x="-14" y="-9" width="9" height="50" fill="url(#xaut-sheen)" />
        </g>
      </g>
    </svg>
  )
}
