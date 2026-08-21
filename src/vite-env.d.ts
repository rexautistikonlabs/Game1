/// <reference types="vite/client" />

/** html2pdf.js ships no types; this is the small slice of its API we use. */
declare module 'html2pdf.js' {
  interface Html2PdfOptions {
    margin?: number | number[]
    filename?: string
    image?: { type?: string; quality?: number }
    html2canvas?: Record<string, unknown>
    jsPDF?: Record<string, unknown>
    pagebreak?: Record<string, unknown>
  }

  interface Html2PdfChain {
    set(options: Html2PdfOptions): Html2PdfChain
    from(element: HTMLElement | string): Html2PdfChain
    save(): Promise<void>
    outputPdf(type: 'blob'): Promise<Blob>
    outputPdf(type?: string): Promise<unknown>
    toPdf(): Html2PdfChain
  }

  export default function html2pdf(): Html2PdfChain
}
