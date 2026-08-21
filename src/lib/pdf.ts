import { slugify, isDesktop } from './download'
import type { Document } from '../types'

/**
 * Printing is deliberately the browser's own print dialog: it is the one path
 * that produces a pixel-perfect PDF on every platform (and "Save as PDF" is
 * right there in the dialog). The print stylesheet in index.css hides
 * everything except the document sheet.
 */
export function printDocument(): void {
  window.print()
}

/**
 * Renders the document sheet to a real PDF via html2pdf. Loaded lazily —
 * html2canvas + jsPDF are large and most sessions never touch them.
 *
 * The sheet deliberately has no fixed A4 height (see DocumentSheet): capturing
 * a 297mm-tall element rounds up to a second page, so every short invoice used
 * to come out as a two-page PDF with a blank page 2. The paper look on screen
 * comes from SheetPreview instead.
 */
export async function generatePdfBlob(element: HTMLElement): Promise<Blob> {
  const { default: html2pdf } = await import('html2pdf.js')

  return (await html2pdf()
    .set({
      margin: 0,
      filename: 'document.pdf',
      image: { type: 'jpeg', quality: 0.98 },
      html2canvas: { scale: 2, useCORS: true, backgroundColor: '#ffffff', logging: false },
      jsPDF: { unit: 'mm', format: 'a4', orientation: 'portrait' },
      // Never slice a line-item row or the totals block down the middle.
      pagebreak: { mode: ['css', 'legacy'], avoid: ['tr', '.avoid-break'] },
    })
    .from(element)
    .outputPdf('blob')) as Blob
}

export const pdfFilename = (doc: Document): string =>
  `${doc.kind}-${slugify(doc.number)}-${slugify(doc.client.name)}.pdf`

/**
 * A desktop email client cannot be handed an attachment through `mailto:` —
 * no mail app supports it. So we do the honest thing: save the PDF first,
 * then open a pre-written email and tell the user to attach the file we just
 * saved for them.
 */
export function buildMailto(options: {
  to?: string
  subject: string
  body: string
}): string {
  const params = new URLSearchParams()
  params.set('subject', options.subject)
  params.set('body', options.body)
  // URLSearchParams encodes spaces as "+", which mail clients show literally.
  const query = params.toString().replace(/\+/g, '%20')
  return `mailto:${encodeURIComponent(options.to ?? '')}?${query}`
}

export function openMailClient(url: string): void {
  if (isDesktop()) {
    // Electron's window-open handler routes mailto: to the OS mail client.
    window.open(url, '_blank')
  } else {
    window.location.href = url
  }
}
