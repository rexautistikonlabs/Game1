import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { HashRouter } from 'react-router-dom'
import { App } from './App'
// Inter is bundled rather than loaded from a CDN — the app has to render
// identically with the network unplugged.
import '@fontsource/inter/400.css'
import '@fontsource/inter/500.css'
import '@fontsource/inter/600.css'
import '@fontsource/inter/700.css'
import './index.css'

const container = document.getElementById('root')
if (!container) throw new Error('Root element is missing from index.html')

createRoot(container).render(
  <StrictMode>
    {/* Hash routing so the production build also works from file:// in Electron. */}
    <HashRouter>
      <App />
    </HashRouter>
  </StrictMode>,
)
