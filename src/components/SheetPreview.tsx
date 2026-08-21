import { useEffect, useRef, useState, type ReactNode } from 'react'
import { cn } from '../lib/cn'

/** A4 in CSS pixels at 96 dpi. Width is the sheet's own; height is the paper
 *  backdrop this component draws behind a short document. */
const SHEET_WIDTH = (210 / 25.4) * 96
const SHEET_HEIGHT = (297 / 25.4) * 96

/**
 * Shows the real, print-sized document sheet scaled down to fit whatever space
 * is available. Scaling (rather than a separate "preview" layout) means what
 * you see really is what prints.
 */
export function SheetPreview({
  children,
  className,
  maxScale = 1,
}: {
  children: ReactNode
  className?: string
  maxScale?: number
}) {
  const containerRef = useRef<HTMLDivElement>(null)
  const contentRef = useRef<HTMLDivElement>(null)
  const [scale, setScale] = useState(0.5)
  const [height, setHeight] = useState(0)

  useEffect(() => {
    const container = containerRef.current
    const content = contentRef.current
    if (!container || !content) return

    const measure = () => {
      const next = Math.min(maxScale, container.clientWidth / SHEET_WIDTH)
      setScale(next)
      setHeight(content.scrollHeight * next)
    }

    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(container)
    observer.observe(content)
    return () => observer.disconnect()
  }, [maxScale])

  return (
    <div ref={containerRef} className={cn('overflow-hidden', className)} style={{ height }}>
      <div
        ref={contentRef}
        style={{
          width: SHEET_WIDTH,
          // The document itself is only as tall as its content — this makes a
          // short invoice still look like a full sheet of paper on screen.
          minHeight: SHEET_HEIGHT,
          background: '#ffffff',
          transform: `scale(${scale})`,
          transformOrigin: 'top left',
        }}
        className="shadow-lift"
      >
        {children}
      </div>
    </div>
  )
}
