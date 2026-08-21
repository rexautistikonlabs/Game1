/**
 * Copies the Tesseract worker + WASM core out of node_modules into `public/ocr`
 * so OCR runs from local files instead of a CDN. That matters for a desktop
 * app: a packaged SimpleBooks must work with the network unplugged.
 *
 * The English language model (~11 MB) is copied out of the
 * `@tesseract.js-data/eng` dev dependency, so a plain `npm install` is all it
 * takes to have OCR work with the network unplugged. If that package is
 * missing we try a download, and failing that Tesseract.js fetches (and then
 * caches) the model on the first scan.
 *
 * Runs automatically after `npm install`; safe to re-run at any time.
 */
import { createWriteStream } from 'node:fs'
import { cp, mkdir, stat, rm } from 'node:fs/promises'
import { pipeline } from 'node:stream/promises'
import { Readable } from 'node:stream'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const outDir = path.join(root, 'public', 'ocr')
const tessdataDir = path.join(outDir, 'tessdata')

const CORE_FILES = [
  'tesseract-core.wasm.js',
  'tesseract-core-simd.wasm.js',
  'tesseract-core-lstm.wasm.js',
  'tesseract-core-simd-lstm.wasm.js',
]

const LANG_URL = 'https://tessdata.projectnaptha.com/4.0.0/eng.traineddata.gz'
const LANG_FILE = path.join(tessdataDir, 'eng.traineddata.gz')
const LANG_PACKAGE = path.join(
  root, 'node_modules', '@tesseract.js-data', 'eng', '4.0.0', 'eng.traineddata.gz',
)

const exists = (p) =>
  stat(p).then(
    () => true,
    () => false,
  )

async function copyWorkerAndCore() {
  await mkdir(outDir, { recursive: true })

  const worker = path.join(root, 'node_modules', 'tesseract.js', 'dist', 'worker.min.js')
  if (!(await exists(worker))) {
    console.warn('[ocr] tesseract.js not installed yet — skipping asset copy.')
    return false
  }
  await cp(worker, path.join(outDir, 'worker.min.js'))

  const coreDir = path.join(root, 'node_modules', 'tesseract.js-core')
  for (const file of CORE_FILES) {
    const from = path.join(coreDir, file)
    if (await exists(from)) await cp(from, path.join(outDir, file))
  }
  console.log('[ocr] Copied Tesseract worker + WASM core to public/ocr.')
  return true
}

async function installLanguageModel() {
  await mkdir(tessdataDir, { recursive: true })
  if (await exists(LANG_FILE)) {
    console.log('[ocr] English language model already present.')
    return
  }

  // Preferred path: the model ships in a dev dependency, so no network needed.
  if (await exists(LANG_PACKAGE)) {
    await cp(LANG_PACKAGE, LANG_FILE)
    console.log('[ocr] Installed the English language model from node_modules.')
    return
  }

  try {
    const response = await fetch(LANG_URL, { redirect: 'follow' })
    if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`)
    await pipeline(Readable.fromWeb(response.body), createWriteStream(LANG_FILE))
    console.log('[ocr] Downloaded the English language model for offline OCR.')
  } catch (error) {
    // Not fatal: OCR will fetch and cache the model on first use instead.
    await rm(LANG_FILE, { force: true })
    console.warn(
      `[ocr] Could not pre-download the language model (${error.message}). ` +
        'OCR will download it once, on your first scan.',
    )
  }
}

const copied = await copyWorkerAndCore()
if (copied) await installLanguageModel()
