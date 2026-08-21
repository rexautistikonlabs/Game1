/**
 * A single place for "are you sure you want to leave?".
 *
 * The document editor holds unsaved work in component state, and every route
 * away from it — a keyboard shortcut, the command palette, the Back button —
 * used to discard that work without a word. The editor registers a guard while
 * it has unsaved changes; anything that navigates asks first.
 *
 * Deliberately a module-level slot rather than context: the callers are spread
 * across the app shell, and only one editor is ever mounted at a time.
 */
type Guard = () => boolean | Promise<boolean>

let guard: Guard | null = null

/** Registers the current guard. Pass null to clear it. */
export function setNavGuard(next: Guard | null): void {
  guard = next
}

/** Resolves true when it is safe to navigate away. */
export async function confirmNavigation(): Promise<boolean> {
  if (!guard) return true
  return await guard()
}
