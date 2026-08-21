'use strict'

const { app, BrowserWindow, shell, Menu, dialog, ipcMain } = require('electron')
const path = require('node:path')
const fs = require('node:fs')

// Only `npm run electron:dev` sets NODE_ENV=development. Every other unpackaged
// run (`npm run electron:start`) must load the built files, not a dev server
// that is not running.
const isDev = !app.isPackaged && process.env.NODE_ENV === 'development'
const DEV_URL = process.env.VITE_DEV_SERVER_URL || 'http://localhost:5173'

/** @type {BrowserWindow | null} */
let mainWindow = null

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 860,
    minWidth: 960,
    minHeight: 640,
    show: false,
    backgroundColor: '#f7f8f9',
    title: 'SimpleBooks',
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
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
    if (/^https?:|^mailto:/.test(url)) shell.openExternal(url)
    return { action: 'deny' }
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
        {
          label: 'About SimpleBooks',
          click: () => {
            dialog.showMessageBox(mainWindow ?? undefined, {
              type: 'info',
              title: 'About SimpleBooks',
              message: `SimpleBooks ${app.getVersion()}`,
              detail:
                'The simplest receipt & invoice bookkeeping app.\n\n' +
                'All of your data lives on this computer only — nothing is ever uploaded.',
              buttons: ['OK'],
            })
          },
        },
      ],
    },
  ]

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

// Renderer asks the main process to write a file it generated (CSV / JSON backup).
ipcMain.handle('save-file', async (_event, { defaultName, data, filters }) => {
  const result = await dialog.showSaveDialog(mainWindow ?? undefined, {
    defaultPath: defaultName,
    filters: filters ?? [{ name: 'All Files', extensions: ['*'] }],
  })
  if (result.canceled || !result.filePath) return { saved: false }
  fs.writeFileSync(result.filePath, Buffer.from(data))
  return { saved: true, path: result.filePath }
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

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit()
  })
}
