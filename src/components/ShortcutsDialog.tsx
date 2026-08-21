import { Modal } from './ui/Modal'
import { shortcutLabel } from '../lib/shortcuts'
import { isDesktop } from '../lib/download'

const GROUPS: { title: string; items: { keys: string; label: string }[] }[] = [
  {
    title: 'Create',
    items: [
      { keys: shortcutLabel({ key: 'n', mod: true }), label: 'New invoice' },
      { keys: shortcutLabel({ key: 'n', mod: true, shift: true }), label: 'New receipt' },
      { keys: shortcutLabel({ key: 'i', mod: true }), label: 'Import a scanned receipt' },
    ],
  },
  {
    title: 'Navigate',
    items: [
      { keys: shortcutLabel({ key: 'k', mod: true }), label: 'Open the command palette' },
      { keys: '↑ ↓', label: 'Move through results' },
      { keys: '↵', label: 'Open the highlighted result' },
      { keys: 'Esc', label: 'Close a dialog or the palette' },
    ],
  },
  {
    title: 'Documents',
    items: [
      { keys: shortcutLabel({ key: 'p', mod: true }), label: 'Print the document on screen' },
      { keys: shortcutLabel({ key: 's', mod: true }), label: 'Export a backup' },
      { keys: '?', label: 'Show this list' },
    ],
  },
]

/** Reachable with "?" — the only place shortcuts are documented in-app. */
export function ShortcutsDialog({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Modal
      open={open}
      onClose={onClose}
      title="Keyboard shortcuts"
      description={
        isDesktop()
          ? 'These also appear in the application menu.'
          : 'Press ? at any time to see this list.'
      }
    >
      <div className="space-y-6">
        {GROUPS.map((group) => (
          <div key={group.title}>
            <h3 className="mb-2.5 text-[11.5px] font-semibold uppercase tracking-wider text-[color:var(--text-subtle)]">
              {group.title}
            </h3>
            <dl className="divide-y">
              {group.items.map((item) => (
                <div key={item.label} className="flex items-center justify-between gap-4 py-2">
                  <dt className="text-[14px]">{item.label}</dt>
                  <dd>
                    <kbd className="rounded-md border px-2 py-1 font-mono text-[12px] text-[color:var(--text-muted)]">
                      {item.keys}
                    </kbd>
                  </dd>
                </div>
              ))}
            </dl>
          </div>
        ))}
      </div>
    </Modal>
  )
}
