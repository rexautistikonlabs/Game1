/** Bridge exposed by Electron's preload script, absent in a plain browser. */
interface SimpleBooksBridge {
  isDesktop: true
  platform: string
  saveFile: (
    defaultName: string,
    data: Uint8Array,
    filters?: { name: string; extensions: string[] }[],
  ) => Promise<{ saved: boolean; path?: string }>
  onMenu: (channel: string, handler: () => void) => () => void
}

declare global {
  interface Window {
    simplebooks?: SimpleBooksBridge
  }
}

export const isDesktop = (): boolean => Boolean(window.simplebooks?.isDesktop)

const EXTENSION_FILTERS: Record<string, { name: string; extensions: string[] }> = {
  csv: { name: 'CSV Spreadsheet', extensions: ['csv'] },
  json: { name: 'JSON Backup', extensions: ['json'] },
  pdf: { name: 'PDF Document', extensions: ['pdf'] },
}

/**
 * Saves a generated file. In Electron this opens the native "Save as…" dialog;
 * in a browser it falls back to a plain download link.
 */
export async function saveFile(
  filename: string,
  content: string | Blob,
  mimeType = 'text/plain;charset=utf-8',
): Promise<boolean> {
  const blob = typeof content === 'string' ? new Blob([content], { type: mimeType }) : content
  const extension = filename.split('.').pop()?.toLowerCase() ?? ''

  if (window.simplebooks?.saveFile) {
    const bytes = new Uint8Array(await blob.arrayBuffer())
    const filter = EXTENSION_FILTERS[extension]
    const result = await window.simplebooks.saveFile(
      filename,
      bytes,
      filter ? [filter] : undefined,
    )
    return result.saved
  }

  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  link.remove()
  // Revoke on the next tick so the download has definitely started.
  setTimeout(() => URL.revokeObjectURL(url), 1000)
  return true
}

export function readFileAsDataUrl(file: File | Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error('Could not read file'))
    reader.readAsDataURL(file)
  })
}

export function readFileAsText(file: File | Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error('Could not read file'))
    reader.readAsText(file)
  })
}

/** Registers an Electron menu handler; a no-op in the browser. */
export function onDesktopMenu(channel: string, handler: () => void): () => void {
  return window.simplebooks?.onMenu(channel, handler) ?? (() => {})
}

/** Slug safe for a filename on every platform. */
export const slugify = (text: string): string =>
  text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60) || 'simplebooks'
