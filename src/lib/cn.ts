type ClassValue = string | number | false | null | undefined | ClassValue[]

/** Tiny class-name joiner — no need for a dependency to do this. */
export function cn(...values: ClassValue[]): string {
  const out: string[] = []
  const walk = (value: ClassValue) => {
    if (!value) return
    if (Array.isArray(value)) value.forEach(walk)
    else out.push(String(value))
  }
  values.forEach(walk)
  return out.join(' ')
}
