import { cn } from '../../lib/cn'
import { Card } from './Card'

/**
 * Placeholder blocks shown while a Dexie live query resolves. The alternative
 * — rendering nothing — reads as a blank flash on every navigation, which makes
 * a local-first app feel slower than it is.
 */
export function Skeleton({ className }: { className?: string }) {
  return (
    <div
      className={cn('animate-pulse rounded-md bg-ink-200/70 dark:bg-white/[0.08]', className)}
      aria-hidden
    />
  )
}

/** Wrapper that announces a loading region to assistive technology once. */
function Loading({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div role="status" aria-busy="true" aria-label={label} className="animate-fade-in">
      {children}
    </div>
  )
}

export function PageHeaderSkeleton() {
  return (
    <div className="mb-6 flex flex-wrap items-end justify-between gap-4">
      <div className="space-y-2">
        <Skeleton className="h-8 w-52" />
        <Skeleton className="h-4 w-72" />
      </div>
      <div className="flex gap-2.5">
        <Skeleton className="h-10 w-28" />
        <Skeleton className="h-10 w-32" />
      </div>
    </div>
  )
}

/** Matches the row height and column widths of DocumentRow. */
export function ListSkeleton({ rows = 5, label = 'Loading' }: { rows?: number; label?: string }) {
  return (
    <Loading label={label}>
      <PageHeaderSkeleton />
      <Card padded={false}>
        <div className="border-b px-4 py-2.5">
          <Skeleton className="h-3 w-36" />
        </div>
        <div className="divide-y">
          {Array.from({ length: rows }, (_, index) => (
            <div key={index} className="flex items-center gap-4 px-4 py-4">
              <div className="min-w-0 flex-1 space-y-2">
                <Skeleton className="h-4 w-28" />
                <Skeleton className="h-3 w-44" />
              </div>
              <Skeleton className="hidden h-3 w-20 sm:block" />
              <Skeleton className="hidden h-6 w-16 rounded-full md:block" />
              <Skeleton className="h-4 w-20" />
            </div>
          ))}
        </div>
      </Card>
    </Loading>
  )
}

export function StatsSkeleton({ tiles = 4 }: { tiles?: number }) {
  return (
    <div className="mb-7 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {Array.from({ length: tiles }, (_, index) => (
        <Card key={index} className="space-y-5">
          <Skeleton className="h-3 w-24" />
          <Skeleton className="h-8 w-32" />
          <Skeleton className="h-3 w-20" />
        </Card>
      ))}
    </div>
  )
}

export function DashboardSkeleton() {
  return (
    <Loading label="Loading your dashboard">
      <PageHeaderSkeleton />
      <div className="mb-7 grid grid-cols-1 gap-3 sm:grid-cols-3">
        {Array.from({ length: 3 }, (_, index) => (
          <Card key={index} className="flex items-center gap-4">
            <Skeleton className="h-11 w-11 rounded-xl" />
            <div className="flex-1 space-y-2">
              <Skeleton className="h-4 w-24" />
              <Skeleton className="h-3 w-16" />
            </div>
          </Card>
        ))}
      </div>
      <StatsSkeleton />
      <div className="grid grid-cols-1 gap-5 lg:grid-cols-[minmax(0,1.55fr)_minmax(0,1fr)]">
        {[6, 4].map((rows, cardIndex) => (
          <Card key={cardIndex} padded={false} className="min-w-0">
            <div className="px-5 py-5">
              <Skeleton className="h-5 w-48" />
            </div>
            <div className="divide-y">
              {Array.from({ length: rows }, (_, index) => (
                <div key={index} className="flex items-center gap-4 px-5 py-4">
                  <div className="min-w-0 flex-1 space-y-2">
                    <Skeleton className="h-4 w-32" />
                    <Skeleton className="h-3 w-24" />
                  </div>
                  <Skeleton className="h-4 w-20" />
                </div>
              ))}
            </div>
          </Card>
        ))}
      </div>
    </Loading>
  )
}

export function CardsSkeleton({ cards = 3, label = 'Loading' }: { cards?: number; label?: string }) {
  return (
    <Loading label={label}>
      <PageHeaderSkeleton />
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
        {Array.from({ length: cards }, (_, index) => (
          <Card key={index} className="space-y-4">
            <div className="flex gap-3">
              <Skeleton className="h-10 w-10 rounded-xl" />
              <div className="flex-1 space-y-2">
                <Skeleton className="h-4 w-32" />
                <Skeleton className="h-3 w-40" />
              </div>
            </div>
            <Skeleton className="h-3 w-48" />
            <Skeleton className="h-3 w-36" />
            <div className="border-t pt-3.5">
              <Skeleton className="h-5 w-24" />
            </div>
          </Card>
        ))}
      </div>
    </Loading>
  )
}

/** The document editor: form column plus preview column. */
export function EditorSkeleton() {
  return (
    <Loading label="Loading the editor">
      <div className="mb-6 flex items-center gap-3">
        <Skeleton className="h-8 w-20" />
        <div className="space-y-2">
          <Skeleton className="h-6 w-40" />
          <Skeleton className="h-3 w-32" />
        </div>
        <Skeleton className="ml-auto h-12 w-28" />
      </div>
      <div className="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1fr)_minmax(0,26rem)]">
        <div className="space-y-5">
          {[3, 5, 6].map((lines, cardIndex) => (
            <Card key={cardIndex} className="space-y-4">
              {Array.from({ length: lines }, (_, index) => (
                <Skeleton key={index} className="h-10 w-full" />
              ))}
            </Card>
          ))}
        </div>
        <Skeleton className="hidden h-[36rem] w-full xl:block" />
      </div>
    </Loading>
  )
}
