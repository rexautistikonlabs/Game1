'use strict'

const { contextBridge, ipcRenderer } = require('electron')

const MENU_CHANNELS = [
  'menu:new-invoice',
  'menu:new-receipt',
  'menu:import-scan',
  'menu:palette',
  'menu:shortcuts',
  'menu:backup',
  'menu:print',
]

contextBridge.exposeInMainWorld('simplebooks', {
  isDesktop: true,
  platform: process.platform,

  /** Native "Save as…" dialog. `data` is a Uint8Array of file bytes. */
  saveFile: (defaultName, data, filters) =>
    ipcRenderer.invoke('save-file', { defaultName, data, filters }),

  /** Subscribe to a native menu command. Returns an unsubscribe function. */
  onMenu: (channel, handler) => {
    if (!MENU_CHANNELS.includes(channel)) return () => {}
    const listener = () => handler()
    ipcRenderer.on(channel, listener)
    return () => ipcRenderer.removeListener(channel, listener)
  },
})
