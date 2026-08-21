'use strict'

const { app, BrowserWindow, shell, Menu, dialog, ipcMain } = require('electron')
const path = require('node:path')
const fs = require('node:fs/promises')

// Only `npm run electron:dev` sets NODE_ENV=development. Every other unpackaged
// run (`npm run electron:start`) must load the built files, not a dev server
// that is not running.
const isDev = !app.isPackaged && process.env.NODE_ENV === 'development'
const DEV_URL = process.env.VITE_DEV_SERVER_URL || 'http://localhost:5173'

/** Generous ceiling for a JSON backup with embedded scan images. */
const MAX_SAVE_BYTES = 256 * 1024 * 1024

/** @type {BrowserWindow | null} */
let mainWindow = null

/** Only these schemes are ever handed to the OS. */
function isSafeExternalUrl(rawUrl) {
  try {
    const { protocol } = new URL(rawUrl)
    return protocol === 'http:' || protocol === 'https:' || protocol === 'mailto:'
  } catch {
    return false
  }
}

/** True for the app's own pages: the built files, or the dev server. */
function isInternalUrl(rawUrl) {
  try {
    const url = new URL(rawUrl)
    if (url.protocol === 'file:') return true
    if (!isDev) return false
    const devOrigin = new URL(DEV_URL).origin
    return url.origin === devOrigin
  } catch {
    return false
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 960,
    minHeight: 640,
    show: false,
    backgroundColor: '#f7f8f9',
    title: 'SimpleBooks',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      // The renderer must never be able to reach Node, even indirectly.
      nodeIntegrationInSubFrames: false,
      webviewTag: false,
      // IndexedDB must survive restarts — that is the whole database.
      sandbox: false,
    },
  })

  mainWindow.once('ready-to-show', () => mainWindow && mainWindow.show())

  if (isDev) {
    mainWindow.loadURL(DEV_URL)
  } else {
    mainWindow.loadFile(path.join(__dirname, '..', 'dist', 'index.html'))
  }

  // Any target="_blank" / external link opens in the real browser, not in-app.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (isSafeExternalUrl(url)) shell.openExternal(url)
    return { action: 'deny' }
  })

  // setWindowOpenHandler only covers window.open. This covers the other half:
  // an in-page navigation away from the app — whether from a stray link or from
  // markup that should never have been able to run.
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (isInternalUrl(url)) return
    event.preventDefault()
    if (isSafeExternalUrl(url)) shell.openExternal(url)
  })

  // Nothing in this app needs a camera, a microphone, or your location.
  mainWindow.webContents.session.setPermissionRequestHandler((_wc, _permission, callback) => {
    callback(false)
  })

  mainWindow.on('closed', () => {
    mainWindow = null
  })
}

function buildMenu() {
  const isMac = process.platform === 'darwin'
  const send = (channel) => () => mainWindow && mainWindow.webContents.send(channel)

  const template = [
    ...(isMac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'New Invoice', accelerator: 'CmdOrCtrl+N', click: send('menu:new-invoice') },
        { label: 'New Receipt', accelerator: 'CmdOrCtrl+Shift+N', click: send('menu:new-receipt') },
        { label: 'Import Scanned Receipt…', accelerator: 'CmdOrCtrl+I', click: send('menu:import-scan') },
        { type: 'separator' },
        { label: 'Find…', accelerator: 'CmdOrCtrl+K', click: send('menu:palette') },
        { type: 'separator' },
        { label: 'Backup Data…', accelerator: 'CmdOrCtrl+S', click: send('menu:backup') },
        { type: 'separator' },
        { label: 'Print', accelerator: 'CmdOrCtrl+P', click: send('menu:print') },
        { type: 'separator' },
        isMac ? { role: 'close' } : { role: 'quit' },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'forceReload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        { label: 'Keyboard Shortcuts', click: send('menu:shortcuts') },
        { type: 'separator' },
        {
          label: 'About SimpleBooks',
          click: () => {
            const options = {
              type: 'info',
              title: 'About SimpleBooks',
              message: `SimpleBooks ${app.getVersion()}`,
              detail:
                'The simplest receipt & invoice bookkeeping app.\n\n' +
                'All of your data lives on this computer only — nothing is ever uploaded.',
              buttons: ['OK'],
            }
            if (mainWindow) dialog.showMessageBox(mainWindow, options)
            else dialog.showMessageBox(options)
          },
        },
      ],
    },
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

/**
 * Writes a file the renderer generated (CSV, JSON backup, PDF) after asking the
 * user where to put it.
 *
 * Everything crossing this boundary is validated. The renderer is our own code,
 * but a privileged handler that trusts its input is exactly the thing that
 * turns a rendering bug into a filesystem bug.
 */
ipcMain.handle('save-file', async (event, payload) => {
  // Only the app's own top-level page may call this.
  const senderUrl = event.senderFrame?.url ?? ''
  if (!isInternalUrl(senderUrl)) return { saved: false, error: 'Refused: unrecognised caller.' }

  const { defaultName, data, filters } = payload ?? {}

  // `data` arrives structured-cloned; accept the typed-array shapes only.
  const bytes =
    data instanceof Uint8Array
      ? data
      : data instanceof ArrayBuffer
        ? new Uint8Array(data)
        : null
  if (!bytes) return { saved: false, error: 'Nothing to write.' }
  if (bytes.byteLength > MAX_SAVE_BYTES) {
    return { saved: false, error: 'That file is too large to save.' }
  }

  // Strip any directory component: the dialog's pre-filled name must never be
  // able to point somewhere else, even though the user still has to confirm.
  const safeName = path.basename(String(defaultName || 'simplebooks')).replace(/^\.+/, '') ||
    'simplebooks'

  const safeFilters = Array.isArray(filters)
    ? filters
        .filter(
          (filter) =>
            filter &&
            typeof filter.name === 'string' &&
            Array.isArray(filter.extensions) &&
            filter.extensions.every((extension) => /^[A-Za-z0-9]{1,10}$/.test(extension)),
        )
        .slice(0, 8)
    : undefined

  try {
    const result = await dialog.showSaveDialog(mainWindow ?? undefined, {
      defaultPath: safeName,
      filters: safeFilters?.length ? safeFilters : [{ name: 'All Files', extensions: ['*'] }],
    })
    if (result.canceled || !result.filePath) return { saved: false }

    // Async: a backup with embedded scan images can be tens of megabytes, and
    // a synchronous write of that size freezes the whole app.
    await fs.writeFile(result.filePath, bytes)
    return { saved: true, path: result.filePath }
  } catch (error) {
    // Disk full, no permission, path removed mid-dialog — report it rather than
    // rejecting the invoke with an opaque Electron error.
    return { saved: false, error: error instanceof Error ? error.message : 'Could not save.' }
  }
})

// Single-instance lock: a second launch focuses the window that already exists.
if (!app.requestSingleInstanceLock()) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore()
      mainWindow.focus()
    }
  })

  app.whenReady().then(() => {
    createWindow()
    buildMenu()
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) createWindow()
    })
  })

  // Belt and braces: apply the navigation guards to any webContents that comes
  // into existence, not only the one window we create ourselves.
  app.on('web-contents-created', (_event, contents) => {
    contents.setWindowOpenHandler(({ url }) => {
      if (isSafeExternalUrl(url)) shell.openExternal(url)
      return { action: 'deny' }
    })
    contents.on('will-attach-webview', (event) => event.preventDefault())
  })

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit()
  })
}
