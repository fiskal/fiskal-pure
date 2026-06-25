/// <reference types="vite/client" />
// ---------------------------------------------------------------------------
// Render + subscription tracer — dev-only, zero overhead in production
// ---------------------------------------------------------------------------
//
// Usage:
//   traceRender('TaskItem')              → logs every render with a count
//   traceSubscription('tasks', 3, 0.8)  → logs subscription callback timing
//   traceMutate('archiveTask', payload) → logs mutate invocation
//   printTraceReport()                  → summary table to console

const DEV = import.meta.env.DEV

// Per-component render counts (persists across re-mounts in strict mode)
const renderCounts = new Map<string, number>()
const subscriptionTimings: Array<{ name: string; docs: number; ms: number }> = []
const mutateLog: Array<{ action: string; payload: unknown; at: number }> = []

export function traceRender(name: string): void {
  if (!DEV) return
  const n = (renderCounts.get(name) ?? 0) + 1
  renderCounts.set(name, n)
  console.debug(`[render] ${name} #${n}`)
}

export function traceSubscription(name: string, docsCount: number, ms: number): void {
  if (!DEV) return
  subscriptionTimings.push({ name, docs: docsCount, ms })
  console.debug(`[subscription] ${name} → ${docsCount} doc(s) in ${ms.toFixed(2)}ms`)
}

export function traceMutate(action: string, payload: unknown): void {
  if (!DEV) return
  mutateLog.push({ action, payload, at: performance.now() })
  console.debug(`[mutate] ${action}`, payload)
}

export function printTraceReport(): void {
  if (!DEV) return
  console.group('[antifragile trace report]')

  console.group('render counts')
  const sorted = [...renderCounts.entries()].sort((a, b) => b[1] - a[1])
  console.table(Object.fromEntries(sorted.map(([k, v]) => [k, { renders: v }])))
  console.groupEnd()

  if (subscriptionTimings.length > 0) {
    console.group('subscription timings')
    const byName = new Map<string, { calls: number; totalMs: number; maxMs: number }>()
    for (const { name, docs, ms } of subscriptionTimings) {
      const entry = byName.get(name) ?? { calls: 0, totalMs: 0, maxMs: 0 }
      byName.set(name, {
        calls: entry.calls + 1,
        totalMs: entry.totalMs + ms,
        maxMs: Math.max(entry.maxMs, ms),
      })
    }
    console.table(
      Object.fromEntries(
        [...byName.entries()].map(([k, v]) => [
          k,
          { calls: v.calls, avgMs: (v.totalMs / v.calls).toFixed(2), maxMs: v.maxMs.toFixed(2) },
        ]),
      ),
    )
    console.groupEnd()
  }

  if (mutateLog.length > 0) {
    console.group('mutate log')
    console.table(mutateLog.map(m => ({ action: m.action, at: m.at.toFixed(1) })))
    console.groupEnd()
  }

  console.groupEnd()
}

// Expose on window for manual inspection in browser console
if (DEV) {
  ;(window as unknown as Record<string, unknown>).antifragileTrace = {
    renderCounts: () => Object.fromEntries(renderCounts),
    subscriptionTimings: () => [...subscriptionTimings],
    mutateLog: () => [...mutateLog],
    report: printTraceReport,
    reset: () => {
      renderCounts.clear()
      subscriptionTimings.length = 0
      mutateLog.length = 0
    },
  }
}
