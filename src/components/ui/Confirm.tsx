import { useCallback, useState, type ReactNode } from 'react'
import { Button } from './Button'
import { Modal } from './Modal'

interface ConfirmOptions {
  title: string
  message: ReactNode
  confirmLabel?: string
  cancelLabel?: string
  destructive?: boolean
}

/**
 * Promise-based confirmation, so a delete handler reads top to bottom:
 *   `if (!(await confirm({...}))) return`
 */
export function useConfirm() {
  const [state, setState] = useState<
    (ConfirmOptions & { resolve: (value: boolean) => void }) | null
  >(null)

  const confirm = useCallback(
    (options: ConfirmOptions) =>
      new Promise<boolean>((resolve) => setState({ ...options, resolve })),
    [],
  )

  const settle = (value: boolean) => {
    state?.resolve(value)
    setState(null)
  }

  const dialog = (
    <Modal
      open={state !== null}
      onClose={() => settle(false)}
      title={state?.title ?? ''}
      size="sm"
      footer={
        <>
          <Button variant="ghost" onClick={() => settle(false)}>
            {state?.cancelLabel ?? 'Cancel'}
          </Button>
          <Button
            variant={state?.destructive ? 'danger' : 'primary'}
            onClick={() => settle(true)}
            autoFocus
          >
            {state?.confirmLabel ?? 'Confirm'}
          </Button>
        </>
      }
    >
      <div className="text-[15px] leading-relaxed text-[color:var(--text-muted)]">
        {state?.message}
      </div>
    </Modal>
  )

  return { confirm, dialog }
}
