import { EXPENSE_CATEGORIES } from '../types'

export interface OcrFields {
  vendor: string
  date: string
  total: number
  taxAmount: number
  category: string
}

export interface OcrResult extends OcrFields {
  text: string
  /** 0–100, straight from Tesseract — shown so the user knows when to look twice. */
  confidence: number
}

export type OcrProgress = (stage: string, progress: number) => void

/** Local worker/WASM copied into `public/ocr` by scripts/setup-ocr-assets.mjs. */
const assetUrl = (file: string): string => new URL(`ocr/${file}`, document.baseURI).href

let localLangChecked = false
let localLangPath: string | undefined

/**
 * Prefers the bundled language model so a packaged desktop app works offline.
 * If it was not pre-downloaded, we let Tesseract.js fetch it once from its CDN
 * — it caches the model in IndexedDB, so only the very first scan needs a
 * connection.
 */
async function resolveLangPath(): Promise<string | undefined> {
  if (localLangChecked) return localLangPath
  localLangChecked = true
  try {
    const response = await fetch(assetUrl('tessdata/eng.traineddata.gz'), { method: 'HEAD' })
    if (response.ok) localLangPath = new URL('ocr/tessdata', document.baseURI).href
  } catch {
    localLangPath = undefined
  }
  return localLangPath
}

const STAGE_LABELS: Record<string, string> = {
  'loading tesseract core': 'Starting the text engine',
  'initializing tesseract': 'Starting the text engine',
  'loading language traineddata': 'Loading the language model',
  'initializing api': 'Getting ready',
  'recognizing text': 'Reading your receipt',
}

/** Runs OCR over an image data-URL or blob URL. */
export async function recognizeImage(
  image: string | Blob,
  onProgress?: OcrProgress,
): Promise<{ text: string; confidence: number }> {
  const { createWorker } = await import('tesseract.js')
  const langPath = await resolveLangPath()

  const worker = await createWorker('eng', 1, {
    workerPath: assetUrl('worker.min.js'),
    corePath: new URL('ocr', document.baseURI).href,
    ...(langPath ? { langPath } : {}),
    logger: (message: { status: string; progress: number }) => {
      onProgress?.(
        STAGE_LABELS[message.status] ?? message.status,
        Math.round((message.progress ?? 0) * 100),
      )
    },
  })

  try {
    const { data } = await worker.recognize(image)
    return { text: data.text ?? '', confidence: Math.round(data.confidence ?? 0) }
  } finally {
    await worker.terminate()
  }
}

/**
 * Renders page 1 of a PDF to a PNG data-URL so it can be fed to OCR.
 * PDF.js is imported lazily — it is only needed for PDF receipts.
 */
export async function pdfFirstPageToImage(file: File | Blob): Promise<string> {
  const pdfjs = await import('pdfjs-dist')
  const workerUrl = await import('pdfjs-dist/build/pdf.worker.min.mjs?url')
  pdfjs.GlobalWorkerOptions.workerSrc = workerUrl.default

  const data = new Uint8Array(await file.arrayBuffer())
  const pdf = await pdfjs.getDocument({ data }).promise
  const page = await pdf.getPage(1)
  // 2× scale: receipts are small-print, and OCR accuracy tracks resolution.
  const viewport = page.getViewport({ scale: 2 })

  const canvas = document.createElement('canvas')
  canvas.width = Math.ceil(viewport.width)
  canvas.height = Math.ceil(viewport.height)
  const context = canvas.getContext('2d')
  if (!context) throw new Error('Could not prepare the PDF for reading.')
  context.fillStyle = '#ffffff'
  context.fillRect(0, 0, canvas.width, canvas.height)

  await page.render({ canvasContext: context, viewport }).promise
  const dataUrl = canvas.toDataURL('image/png')
  await pdf.destroy()
  return dataUrl
}

// ---------------------------------------------------------------------------
// Field extraction
//
// OCR gives us a wall of noisy text. These heuristics turn it into a first
// draft of an expense — the user always reviews and corrects it before saving,
// so "usually right" beats "cautious and empty".
// ---------------------------------------------------------------------------

const MONTHS = [
  'jan', 'feb', 'mar', 'apr', 'may', 'jun',
  'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
]

const pad = (n: number) => String(n).padStart(2, '0')

function isoDate(year: number, month: number, day: number): string | null {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  if (year < 100) year += year > 70 ? 1900 : 2000
  if (year < 1990 || year > 2100) return null
  const date = new Date(Date.UTC(year, month - 1, day))
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null
  return `${year}-${pad(month)}-${pad(day)}`
}

/** Pulls the most plausible receipt date out of raw OCR text. */
export function extractDate(text: string): string {
  const candidates: string[] = []

  // 2025-03-14 / 2025.03.14
  for (const m of text.matchAll(/\b(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})\b/g)) {
    const iso = isoDate(+m[1]!, +m[2]!, +m[3]!)
    if (iso) candidates.push(iso)
  }

  // 14/03/2025 or 03/14/2025 — ambiguous, so use the value that can only be
  // a day to decide which order this receipt uses.
  for (const m of text.matchAll(/\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})\b/g)) {
    const [a, b, year] = [+m[1]!, +m[2]!, +m[3]!]
    const iso = a > 12 ? isoDate(year, b, a) : isoDate(year, a, b)
    if (iso) candidates.push(iso)
  }

  // 14 Mar 2025 / Mar 14, 2025
  const monthNames = MONTHS.join('|')
  const dayFirst = new RegExp(`\\b(\\d{1,2})\\s+(${monthNames})[a-z]*\\.?,?\\s+(\\d{2,4})\\b`, 'gi')
  for (const m of text.matchAll(dayFirst)) {
    const iso = isoDate(+m[3]!, MONTHS.indexOf(m[2]!.toLowerCase()) + 1, +m[1]!)
    if (iso) candidates.push(iso)
  }
  const monthFirst = new RegExp(`\\b(${monthNames})[a-z]*\\.?\\s+(\\d{1,2}),?\\s+(\\d{2,4})\\b`, 'gi')
  for (const m of text.matchAll(monthFirst)) {
    const iso = isoDate(+m[3]!, MONTHS.indexOf(m[1]!.toLowerCase()) + 1, +m[2]!)
    if (iso) candidates.push(iso)
  }

  const todayIso = new Date().toISOString().slice(0, 10)
  // A receipt is never dated in the future; among the rest, the latest date on
  // the page is almost always the transaction date (not an expiry or a footer).
  const past = candidates.filter((d) => d <= todayIso).sort()
  return past.at(-1) ?? candidates.sort().at(-1) ?? todayIso
}

/** Turns "1.234,56" / "1,234.56" / "12.50" into a number. */
function parseAmount(raw: string): number | null {
  let cleaned = raw.replace(/[^\d.,-]/g, '')
  if (!cleaned) return null

  const lastComma = cleaned.lastIndexOf(',')
  const lastDot = cleaned.lastIndexOf('.')
  if (lastComma > -1 && lastDot > -1) {
    // Whichever separator comes last is the decimal point.
    cleaned = lastComma > lastDot
      ? cleaned.replace(/\./g, '').replace(',', '.')
      : cleaned.replace(/,/g, '')
  } else if (lastComma > -1) {
    // A lone comma is a decimal separator only when 1–2 digits follow it.
    cleaned = /,\d{1,2}$/.test(cleaned) ? cleaned.replace(',', '.') : cleaned.replace(/,/g, '')
  }

  const value = Number.parseFloat(cleaned)
  return Number.isFinite(value) && value >= 0 ? Math.round(value * 100) / 100 : null
}

const AMOUNT_PATTERN = /(?:[$€£¥₹]\s*)?-?\d{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{1,2})?|(?:[$€£¥₹]\s*)?-?\d+(?:[.,]\d{1,2})?/g

function amountsInLine(line: string): number[] {
  const found: number[] = []
  for (const match of line.matchAll(AMOUNT_PATTERN)) {
    const value = parseAmount(match[0])
    if (value !== null) found.push(value)
  }
  return found
}

/** Drops "8.8%" style rate figures so they cannot be mistaken for an amount. */
const stripRates = (line: string): string => line.replace(/\d+(?:[.,]\d+)?\s*%/g, ' ')

/**
 * Drops date-like tokens. Without this, "25.02.2026" contributes a stray
 * "2026" that can outweigh the real total on a receipt with no total keyword.
 */
const stripDates = (line: string): string =>
  line
    .replace(/\b\d{1,4}[-/.]\d{1,2}[-/.]\d{2,4}\b/g, ' ')
    .replace(/\b(19|20)\d{2}\b/g, ' ')

const TOTAL_KEYWORDS = [
  /\bgrand\s*total\b/i,
  /\bamount\s*(?:due|paid|charged)\b/i,
  /\btotal\s*(?:due|amount|paid|sale)\b/i,
  /\bbalance\s*due\b/i,
  /\btotal\b/i,
  /\bto\s*pay\b/i,
  // Common non-English wording, so a European receipt is not left to the
  // largest-number fallback.
  /\b(gesamt|gesamtbetrag|summe|zu\s*zahlen|betrag|totaal|totale|importe|montant|suma)\b/i,
]

const NEGATIVE_TOTAL_KEYWORDS = /\b(sub\s*-?\s*total|subtotal|tax|vat|gst|hst|change|cash|tip|discount|savings|tender)\b/i

/** Finds the amount that is most likely the receipt's grand total. */
export function extractTotal(text: string): number {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)

  for (const [priority, keyword] of TOTAL_KEYWORDS.entries()) {
    const matches: number[] = []
    for (const line of lines) {
      if (!keyword.test(line)) continue
      // "TOTAL" also appears inside "SUBTOTAL" — skip those unless we are
      // matching a very specific phrase like "grand total".
      if (priority >= 4 && NEGATIVE_TOTAL_KEYWORDS.test(line)) continue
      const amounts = amountsInLine(stripDates(stripRates(line)))
      if (amounts.length) matches.push(Math.max(...amounts))
    }
    // Later "TOTAL" lines win: a receipt's grand total sits below its subtotal.
    if (matches.length) return matches.at(-1)!
  }

  // No keyword anywhere — fall back to the largest amount on the receipt.
  const all = lines
    .flatMap((line) => amountsInLine(stripDates(stripRates(line))))
    .filter((n) => n > 0)
  return all.length ? Math.max(...all) : 0
}

const TAX_KEYWORD = /\b(sales\s*tax|tax|vat|gst|hst|iva|mwst)\b/i

export function extractTax(text: string, total: number): number {
  const lines = text.split(/\r?\n/).map((l) => l.trim()).filter(Boolean)
  const candidates: number[] = []

  for (const line of lines) {
    if (!TAX_KEYWORD.test(line)) continue
    // "Tax ID" / "VAT No." are identifiers, not amounts.
    if (/\b(id|no\.?|number|reg|registration|exempt)\b/i.test(line)) continue

    const amounts = amountsInLine(stripRates(line)).filter((a) => a > 0 && a < total)
    // The money column is on the right, so the last amount on the line is the
    // tax charged — anything before it is a rate or a line reference.
    if (amounts.length) candidates.push(amounts.at(-1)!)
  }
  if (!candidates.length) return 0
  // Tax is a fraction of the total; ignore anything too large to be one.
  const plausible = candidates.filter((c) => c <= total * 0.35)
  return plausible.length ? Math.max(...plausible) : 0
}

const VENDOR_NOISE =
  /^(receipt|invoice|tax invoice|customer copy|merchant copy|thank you|thanks|welcome|order|store|tel|phone|fax|www\.|http|date|time|cashier|server|table|terminal|card|visa|mastercard|amex|approved|auth|ref|transaction|subtotal|total|tax|vat|change|cash|qty|item|address)\b/i

/** The vendor's name is nearly always the first real line of a receipt. */
export function extractVendor(text: string): string {
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.replace(/\s{2,}/g, ' ').trim())
    .filter(Boolean)

  for (const raw of lines.slice(0, 8)) {
    // Strip decoration first — "*** CUSTOMER COPY ***" has to be recognised as
    // boilerplate, and it will not be while the asterisks are still attached.
    const line = raw.replace(/[|_*=~`#]+/g, ' ').replace(/\s{2,}/g, ' ').trim()
    if (line.length < 3) continue

    const letters = line.replace(/[^a-z]/gi, '').length
    if (letters < 3) continue
    if (VENDOR_NOISE.test(line)) continue
    // Skip lines that are mostly digits — those are dates, totals, phone numbers.
    if (letters / line.length < 0.5) continue

    // Receipt headers are often ALL CAPS; title-case reads better in a ledger.
    return line.length > 60 ? line.slice(0, 60).trim() : titleCaseIfShouting(line)
  }
  return ''
}

function titleCaseIfShouting(text: string): string {
  const isShouting = text === text.toUpperCase() && /[A-Z]{3}/.test(text)
  if (!isShouting) return text
  return text
    .toLowerCase()
    .replace(/\b([a-z])/g, (_, c: string) => c.toUpperCase())
    .replace(/\b(Llc|Inc|Ltd|Plc)\b/g, (m) => m.toUpperCase())
}

const CATEGORY_HINTS: [RegExp, (typeof EXPENSE_CATEGORIES)[number]][] = [
  [/\b(hotels?|motels?|inn|airlines?|airways|flights?|uber|lyft|taxi|rail|trains?|parking|tolls?|rental\s*car|hertz|avis|gas|fuel|petrol|shell|chevron|bp|amtrak|expedia|airbnb)\b/i, 'Travel'],
  [/\b(restaurants?|cafe|caf|coffee|starbucks|pizza|diner|bar|grill|catering|bakery|deli|lunch|dinner|breakfast|food|kitchen|brewing|taqueria)\b/i, 'Meals & Entertainment'],
  [/\b(staples|office\s*depot|officemax|paper|toner|ink\s*cartridge|stationery|pens?|envelopes?|binders?|notebooks?)\b/i, 'Office Supplies'],
  [/\b(subscriptions?|saas|adobe|microsoft|google\s*workspace|dropbox|slack|zoom|notion|figma|github|atlassian|hosting|domains?|licen[cs]es?)\b/i, 'Software & Subscriptions'],
  [/\b(apple\s*store|best\s*buy|laptops?|monitors?|printers?|hardware|computers?|cameras?|lenses?|equipment|rental)\b/i, 'Equipment'],
  [/\b(rent|lease|electric|water|internet|utility|utilities|gas\s*bill|comcast|verizon|at&t|natural)\b/i, 'Rent & Utilities'],
  [/\b(attorneys?|legal|law\s*(?:firm|office)|accountants?|accounting|cpa|consultants?|consulting|notary|audit|bookkeep)\b/i, 'Professional Services'],
  [/\b(advertis|marketing|facebook\s*ads|google\s*ads|billboard|flyers?|print\s*shop|promo|signage)\b/i, 'Marketing'],
  [/\b(usps|fedex|ups|dhl|postage|shipping|couriers?|stamps?|freight)\b/i, 'Postage & Shipping'],
  [/\b(insurance|liability|premiums?|policy)\b/i, 'Insurance'],
  [/\b(bank|credit\s*union|wire\s*fee|service\s*charge|stripe|paypal\s*fee|merchant\s*fee|interest)\b/i, 'Bank & Payment Fees'],
  [/\b(volunteers?|donations?|grants?|programs?|outreach|community|workshops?|scholarships?)\b/i, 'Program Expenses'],
]

export function guessCategory(text: string): string {
  for (const [pattern, category] of CATEGORY_HINTS) {
    if (pattern.test(text)) return category
  }
  return 'Other'
}

/** Turns raw OCR text into a draft expense the user can review. */
export function extractFields(text: string): OcrFields {
  const total = extractTotal(text)
  return {
    vendor: extractVendor(text),
    date: extractDate(text),
    total,
    taxAmount: extractTax(text, total),
    category: guessCategory(text),
  }
}

/** Full pipeline: file in, reviewable draft expense out. */
export async function scanReceipt(
  file: File,
  onProgress?: OcrProgress,
): Promise<OcrResult & { imageDataUrl: string }> {
  const isPdf = file.type === 'application/pdf' || /\.pdf$/i.test(file.name)

  onProgress?.(isPdf ? 'Opening the PDF' : 'Opening the image', 0)
  const imageDataUrl = isPdf
    ? await pdfFirstPageToImage(file)
    : await new Promise<string>((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(String(reader.result))
        reader.onerror = () => reject(new Error('Could not read that file.'))
        reader.readAsDataURL(file)
      })

  const { text, confidence } = await recognizeImage(imageDataUrl, onProgress)
  return { ...extractFields(text), text, confidence, imageDataUrl }
}
