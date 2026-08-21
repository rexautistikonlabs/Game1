import { useEffect } from 'react'

export interface Shortcut {
  /** Single character, or a key name like 'Escape'. Compared case-insensitively. */
  key: string
  /** Cmd on macOS, Ctrl elsewhere. */
  mod?: boolean
  shift?: boolean
  run: () => void
}

const isMac = (): boolean =>
  typeof navigator !== 'undefined' && /mac|iphone|ipad/i.test(navigator.platform || navigator.userAgent)

/** "⌘N" on a Mac, "Ctrl+N" everywhere else. */
export function shortcutLabel(shortcut: { key: string; mod?: boolean; shift?: boolean }): string {
  const parts: string[] = []
  if (shortcut.mod) parts.push(isMac() ? '⌘' : 'Ctrl')
  if (shortcut.shift) parts.push(isMac() ? '⇧' : 'Shift')
  parts.push(shortcut.key.length === 1 ? shortcut.key.toUpperCase() : shortcut.key)
  return isMac() ? parts.join('') : parts.join('+')
}

/**
 * Typing "n" in an invoice description must not open a new invoice, so
 * shortcuts with a modifier are allowed through while a field has focus, and
 * bare-key shortcuts are not.
 */
function isTypingTarget(target: EventTarget | null): boolean {
  const element = target as HTMLElement | null
  if (!element) return false
  const tag = element.tagName
  return (
    tag === 'INPUT' ||
    tag === 'TEXTAREA' ||
    tag === 'SELECT' ||
    element.isContentEditable === true
  )
}

/**
 * Registers global keyboard shortcuts for as long as the component is mounted.
 * Pass a stable array (a module constant or a memo) to avoid re-binding on
 * every render.
 */
export function useShortcuts(shortcuts: Shortcut[], enabled = true): void {
  useEffect(() => {
    if (!enabled) return

    const onKeyDown = (event: KeyboardEvent) => {
      // Never hijack an in-progress IME composition or an auto-repeat.
      if (event.isComposing || event.repeat) return

      const mod = isMac() ? event.metaKey : event.ctrlKey
      // A bare Alt/AltGr combination belongs to the OS or the input method.
      if (event.altKey) return

      for (const shortcut of shortcuts) {
        const wantsMod = shortcut.mod ?? false
        if (wantsMod !== mod) continue
        if ((shortcut.shift ?? false) !== event.shiftKey) continue
        if (event.key.toLowerCase() !== shortcut.key.toLowerCase()) continue
        if (!wantsMod && isTypingTarget(event.target)) continue

        event.preventDefault()
        shortcut.run()
        return
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [shortcuts, enabled])
}
