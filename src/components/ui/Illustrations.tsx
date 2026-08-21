/**
 * Hand-drawn-feeling line illustrations for empty states. They use the active
 * company's brand colour, so an empty Invoices list still looks like *your* app.
 */
const stroke = 'var(--brand)'

export function InvoiceIllustration() {
  return (
    <svg width="132" height="132" viewBox="0 0 132 132" fill="none" aria-hidden>
      <rect x="12" y="20" width="82" height="100" rx="10" fill="var(--brand-soft)" />
      <rect
        x="30" y="10" width="82" height="100" rx="10"
        fill="var(--surface)" stroke={stroke} strokeWidth="2.5"
      />
      <path d="M45 34h34M45 48h52M45 62h52M45 76h30" stroke={stroke} strokeWidth="2.5" strokeLinecap="round" opacity="0.55" />
      <path d="M74 92h23" stroke={stroke} strokeWidth="3.5" strokeLinecap="round" />
      <circle cx="99" cy="97" r="17" fill="var(--surface)" stroke={stroke} strokeWidth="2.5" />
      <path d="M92 97l5 5 9-10" stroke={stroke} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function ReceiptIllustration() {
  return (
    <svg width="132" height="132" viewBox="0 0 132 132" fill="none" aria-hidden>
      <path
        d="M34 16h64v92l-8-6-8 6-8-6-8 6-8-6-8 6-8-6-8 6V16z"
        fill="var(--brand-soft)" transform="translate(-8 6)"
      />
      <path
        d="M40 14h64v96l-8-6-8 6-8-6-8 6-8-6-8 6-8-6-8 6V14z"
        fill="var(--surface)" stroke={stroke} strokeWidth="2.5" strokeLinejoin="round"
      />
      <path d="M54 36h36M54 50h36M54 64h22" stroke={stroke} strokeWidth="2.5" strokeLinecap="round" opacity="0.55" />
      <path d="M54 80h36" stroke={stroke} strokeWidth="3.5" strokeLinecap="round" />
    </svg>
  )
}

export function ScanIllustration() {
  return (
    <svg width="132" height="132" viewBox="0 0 132 132" fill="none" aria-hidden>
      <rect x="18" y="26" width="96" height="80" rx="12" fill="var(--brand-soft)" />
      <rect
        x="18" y="26" width="96" height="80" rx="12"
        stroke={stroke} strokeWidth="2.5" strokeDasharray="9 8" fill="none"
      />
      <rect x="46" y="40" width="40" height="52" rx="6" fill="var(--surface)" stroke={stroke} strokeWidth="2.5" />
      <path d="M56 54h20M56 64h20M56 74h12" stroke={stroke} strokeWidth="2.2" strokeLinecap="round" opacity="0.6" />
      <path d="M66 8v14M66 22l-6-6M66 22l6-6" stroke={stroke} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function ClientIllustration() {
  return (
    <svg width="132" height="132" viewBox="0 0 132 132" fill="none" aria-hidden>
      <circle cx="66" cy="50" r="22" fill="var(--brand-soft)" />
      <circle cx="66" cy="47" r="17" fill="var(--surface)" stroke={stroke} strokeWidth="2.5" />
      <path
        d="M32 112c0-18 15-30 34-30s34 12 34 30"
        fill="var(--surface)" stroke={stroke} strokeWidth="2.5" strokeLinecap="round"
      />
      <circle cx="26" cy="58" r="11" fill="var(--surface)" stroke={stroke} strokeWidth="2.2" opacity="0.55" />
      <circle cx="106" cy="58" r="11" fill="var(--surface)" stroke={stroke} strokeWidth="2.2" opacity="0.55" />
    </svg>
  )
}

export function CompanyIllustration() {
  return (
    <svg width="132" height="132" viewBox="0 0 132 132" fill="none" aria-hidden>
      <rect x="16" y="46" width="46" height="70" rx="8" fill="var(--brand-soft)" />
      <rect x="16" y="46" width="46" height="70" rx="8" stroke={stroke} strokeWidth="2.5" fill="none" />
      <rect x="70" y="22" width="46" height="94" rx="8" fill="var(--surface)" stroke={stroke} strokeWidth="2.5" />
      <path
        d="M28 60h10M46 60h6M28 76h10M46 76h6M28 92h10M46 92h6M82 38h10M100 38h6M82 56h10M100 56h6M82 74h10M100 74h6"
        stroke={stroke} strokeWidth="2.4" strokeLinecap="round" opacity="0.6"
      />
      <path d="M88 116v-18h10v18" stroke={stroke} strokeWidth="2.5" strokeLinecap="round" />
    </svg>
  )
}

export function SearchIllustration() {
  return (
    <svg width="120" height="120" viewBox="0 0 120 120" fill="none" aria-hidden>
      <circle cx="52" cy="52" r="30" fill="var(--brand-soft)" />
      <circle cx="52" cy="52" r="30" stroke={stroke} strokeWidth="2.5" fill="none" />
      <path d="M74 74l24 24" stroke={stroke} strokeWidth="4" strokeLinecap="round" />
      <path d="M40 52h24" stroke={stroke} strokeWidth="2.8" strokeLinecap="round" opacity="0.6" />
    </svg>
  )
}
