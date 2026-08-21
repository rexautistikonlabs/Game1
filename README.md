# SimpleBooks

The simplest receipt & invoice bookkeeping app I could build. Offline-first, multi-company,
and it never asks you to make an account.

- **Invoices and receipts** with a clean printable template, automatic totals, and one-click
  print / PDF / email
- **Multiple companies** — a nonprofit and an LLC side by side, each with its own logo, tax ID,
  currency, numbering, expense categories and brand colour, switched from the top bar
- **Scanned receipt import** — drop in a photo or PDF and OCR reads the vendor, date and total,
  entirely on your own machine
- **Recurring invoices** — monthly, quarterly or yearly, generated as drafts you approve
- **Reports** — income, expenses, net and what you are owed, over any date range
- **CSV export** for invoices, receipts, expenses and reports, scoped to one company
- **JSON backup** of everything, restorable in one click
- **Command palette** — `Cmd/Ctrl+K` to switch company or find anything
- **No backend.** All data lives in IndexedDB on this computer. Nothing is ever uploaded.

---

## Quick start

```bash
npm install       # also copies the OCR engine + language model into public/ocr
npm run dev       # http://localhost:5173
```

On first launch SimpleBooks seeds two example companies — **Nonprofit Example** and
**For-Profit Example** — with clients, invoices, receipts and expenses, so the company switcher
is useful immediately. Delete them whenever you like, or reset them from
*Settings → Sample data*.

### Run it as a desktop app

```bash
npm run electron:dev      # Vite + Electron with hot reload
npm run electron:start    # production build, running in Electron
```

### Package an installer

```bash
npm run electron:build       # installer for the current platform, into release/
npm run electron:build:dir   # unpacked app directory (faster, for a smoke test)
```

Targets are configured in `electron-builder.yml`: DMG + ZIP on macOS, NSIS + portable on
Windows, AppImage + deb on Linux. Building for a platform other than your own needs that
platform's toolchain, so run the build on the OS you are targeting (or in CI).

**See [BUILD.md](BUILD.md)** for per-platform toolchains, signing and notarization, the
pitfalls worth knowing in advance, how to test an installer, and what the production CSP does.

### Other commands

| Command | What it does |
| --- | --- |
| `npm run build` | Type-check and build to `dist/` |
| `npm test` | Unit tests (totals, tax rules, OCR field extraction) |
| `npm run test:watch` | The same tests in watch mode |
| `npm run setup:ocr` | Re-copy the OCR assets into `public/ocr` |

---

## How it is put together

```
electron/
  main.cjs              Window, native menu, and the "Save as…" dialog bridge
  preload.cjs           The only surface exposed to the renderer (contextIsolation on)
scripts/
  setup-ocr-assets.mjs  Copies the Tesseract worker, WASM core and language model
                        out of node_modules into public/ocr, so OCR works offline
src/
  App.tsx               Routes, brand theming, desktop menu wiring
  types.ts              Every record shape in one place
  db/
    db.ts               Dexie schema, cascading delete, atomic number claiming
    seed.ts             The two example companies
  store/
    useApp.ts           Global UI state: active company, theme, toasts
    useCompanyData.ts   Company-scoped live queries
  lib/
    format.ts           Money, dates, and all total/tax arithmetic
    recurrence.ts       Recurring-invoice dates and generation
    reports.ts          Report figures and the report CSV
    shortcuts.ts        Global keyboard shortcut binding
    ocr.ts              Tesseract pipeline plus the vendor/date/total parsers
    csv.ts              Bookkeeping-friendly CSV shapes
    backup.ts           JSON export and restore
    pdf.ts              Print, PDF rendering, mailto composition
    download.ts         Native save dialog in Electron, plain download in a browser
  components/
    DocumentSheet.tsx   The printed invoice/receipt — A4-sized, fixed light colours
    …                   Editor, dialogs, and the UI primitives
  pages/                Dashboard, Documents, DocumentEdit, DocumentView,
                        Expenses, Reports, Clients, Settings, Welcome
```

**Stack**: React 18 + TypeScript + Vite · Tailwind CSS · Zustand · Dexie (IndexedDB) ·
Tesseract.js · pdf.js · html2pdf.js · React Hook Form + Zod · Lucide · Electron.

### A few decisions worth knowing about

**Totals are never stored.** Subtotal, tax and total are recomputed from the line items every
time they are displayed, so a document can never disagree with itself. A flat discount is
spread proportionally across lines before tax. See `computeTotals` in `src/lib/format.ts`.

**Overdue is not a status.** The stored statuses are Draft, Sent and Paid; "Overdue" is derived
from an unpaid invoice whose due date has passed, so it can never go stale.

**Documents snapshot their client.** Each invoice keeps its own copy of the client's name and
address as it was when issued. Editing or deleting a client never rewrites history.

**Numbers are claimed atomically.** `claimNextNumber` reads and increments the company's
counter inside a single Dexie transaction, so two fast clicks cannot produce a duplicate. A
number is claimed on first save, so unsaved drafts never burn one.

**Recurring invoices have no scheduler.** One document per series carries the cadence and the
date of the next copy; anything due is generated while the app is open — on startup, or from
the "Generate next" button. Generation runs in a transaction that re-checks whether the series
is still due, so a click racing the startup pass cannot produce two invoices for the same
date. The catch-up pass caps at 12 per series so a long-dormant series does not flood you.

**Categories are a picklist, not a foreign key.** Expenses store the category *name*, so
renaming or deleting a category cannot rewrite what an old expense says it was for — the same
reasoning as the client snapshots. Renaming does offer to carry existing expenses across.

**Reports are a view, never a stored figure.** Income counts a document on the day it was
marked paid; "outstanding" is every unpaid invoice as of today, so it deliberately does not
move when you change the date range.

**Printing uses the browser's own print dialog.** It is the one path that produces a correct
PDF on every platform, and "Save as PDF" is already in that dialog. The document sheet is laid
out at real A4 size and scaled down for the screen, so what you see is what prints.
`Save as PDF` renders the same element through html2pdf when you want the file directly.

**Email is honest about attachments.** No mail client on any platform accepts an attachment
from a `mailto:` link. So SimpleBooks saves the PDF, opens a pre-written email, and tells you
to drag the file in — rather than pretending to attach it.

### OCR, and why it works offline

`npm install` copies three things into `public/ocr`:

- `worker.min.js` — the Tesseract worker
- `tesseract-core*.wasm.js` — the recognition engine
- `tessdata/eng.traineddata.gz` — the English language model (~11 MB), taken from the
  `@tesseract.js-data/eng` dev dependency

The app loads all of them from disk, so scanning a receipt makes **zero network requests**.
If the language model is ever missing, Tesseract.js falls back to downloading it once and
caching it in IndexedDB; that is the only situation in which SimpleBooks touches the network.

`public/ocr` is generated, so it is not committed — `npm install` recreates it.

Extraction (`src/lib/ocr.ts`) is deliberately plain heuristics, and the extracted values are
always shown for review before anything is saved. It handles US and European date orders,
comma decimal separators, thousands separators, "subtotal" vs "total" vs "amount due", tax
rates printed beside tax amounts, and cash/change lines that would otherwise beat the total.
PDF receipts are rendered to an image by pdf.js first. `npm test` covers these cases.

### Where your data lives

Everything is in one IndexedDB database named `simplebooks` — companies, clients, documents,
expenses, and the original scan images (as data URLs, so backups are self-contained). In the
desktop app that database lives in Electron's user-data directory; in a browser it belongs to
that browser profile.

There is no sync and no cloud, which means **the backup button in Settings is the only copy you
will get**. `Export backup (JSON)` writes the whole database to a single file, and
`Restore from backup` puts it back.

## Keyboard shortcuts

Press `?` in the app for this list.

| Shortcut | Action |
| --- | --- |
| `Cmd/Ctrl + K` | Command palette — switch company, jump anywhere, find a record |
| `Cmd/Ctrl + N` | New invoice |
| `Cmd/Ctrl + Shift + N` | New receipt |
| `Cmd/Ctrl + I` | Import a scanned receipt |
| `Cmd/Ctrl + S` | Export a backup |
| `Cmd/Ctrl + P` | Print the document on screen |
| `?` | Show all shortcuts |
| `Esc` | Close a dialog or the palette |

Shortcuts with a modifier work while you are typing in a field; bare-key ones do not, so a `?`
in an invoice description stays a `?`.

## Browser support

Any current Chrome, Edge, Firefox or Safari. The app is desktop-first but the layout holds up
down to phone width. Print output is A4.
