import { defineConfig, type Plugin } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath, URL } from 'node:url'

/**
 * A Content-Security-Policy for the packaged desktop app. It is injected only
 * into production builds — Vite's dev server needs an inline script and a
 * websocket for hot reload, and a policy strict enough to be worth having
 * would block both.
 *
 * `wasm-unsafe-eval` and `blob:` are required by Tesseract.js, which runs OCR
 * in a Web Worker backed by WebAssembly. The one remote host is the language
 * model CDN, used only as a fallback when the model was not bundled locally.
 */
const CSP = [
  "default-src 'self' file:",
  "script-src 'self' file: blob: 'wasm-unsafe-eval'",
  "worker-src 'self' file: blob:",
  "style-src 'self' file: 'unsafe-inline'",
  "img-src 'self' file: data: blob:",
  "font-src 'self' file: data:",
  "connect-src 'self' file: data: blob: https://tessdata.projectnaptha.com",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'none'",
].join('; ')

const contentSecurityPolicy = (): Plugin => ({
  name: 'simplebooks-csp',
  apply: 'build',
  transformIndexHtml: (html) =>
    html.replace(
      '<meta charset="UTF-8" />',
      `<meta charset="UTF-8" />\n    <meta http-equiv="Content-Security-Policy" content="${CSP}" />`,
    ),
})

export default defineConfig({
  plugins: [react(), contentSecurityPolicy()],
  // Relative base so the production build also works from file:// inside Electron.
  base: './',
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: { port: 5173, strictPort: true },
  build: { outDir: 'dist', chunkSizeWarningLimit: 1500 },
})
