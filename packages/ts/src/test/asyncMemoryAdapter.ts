// ---------------------------------------------------------------------------
// AsyncMemoryAdapter — a deferred-delivery fake for testing async behaviour
// ---------------------------------------------------------------------------
// (ADR-0014)
//
// Unlike MemoryAdapter (synchronous), this fake DEFERS every subscribe-delivery
// and write-notification onto a pending queue that the test drains explicitly
// with `flush()`. That makes three things testable that the sync adapter hides:
//
//   1. The loading state — a subscriber sees nothing until the first flush.
//   2. Optimistic → remote → revert — `failNextWrite()` rejects a write so the
//      adapter's authoritative state stays at the pre-write value, which is what
//      a store would revert its optimistic cache back to (the source of truth).
//   3. Subscription hygiene — `subscriberCount()` lets a test assert that the
//      active subscriber count returns to zero after attach/detach cycles.
//
// It is a transport-only fake: it owns an authoritative cache and a delivery
// queue, nothing else. No timers — draining is explicit and deterministic.

import { applyWrites, emptyCache, filterDocs, getCollection } from '../cache.js'
import type {
  Adapter,
  CacheState,
  Doc,
  OnChangeCallback,
  Query,
  Unsubscribe,
  WriteDescriptor,
  WriteOp,
} from '../types.js'

interface Sub {
  id: number
  query: Query
  cb: OnChangeCallback
}

export interface AsyncMemoryAdapter extends Adapter {
  /** Drain all pending subscribe/write deliveries; resolves after callbacks run. */
  flush(): Promise<void>
  /** Force the next write() to reject — simulates a remote nack. */
  failNextWrite(error?: Error): void
  /** Active subscriber count, optionally scoped to one path. */
  subscriberCount(path?: string): number
  /** The adapter's authoritative docs for a query — what a client reverts to. */
  authoritative(query: Query): Doc[]
}

export function createAsyncMemoryAdapter(
  initial?: Record<string, Doc[]>,
): AsyncMemoryAdapter {
  let cache: CacheState = emptyCache()
  if (initial) {
    const seed: WriteDescriptor[] = []
    for (const [path, docs] of Object.entries(initial)) {
      for (const { id, ...fields } of docs) {
        seed.push({ path, id, fields, merge: false })
      }
    }
    cache = applyWrites(cache, seed)
  }

  const subs = new Map<number, Sub>()
  const pending: Array<() => void> = []
  let nextId = 1
  let failNext: Error | null = null

  function docsFor(query: Query): Doc[] {
    if (query.id) {
      const doc = cache.get(query.path)?.get(query.id)
      return doc ? [doc] : []
    }
    return filterDocs(getCollection(cache, query.path), query.where)
  }

  function schedule(fn: () => void): void {
    pending.push(fn)
  }

  async function flush(): Promise<void> {
    // Drain in FIFO order; deliveries scheduled mid-drain are drained too.
    while (pending.length > 0) {
      const fn = pending.shift()!
      fn()
    }
    await Promise.resolve()
  }

  function notify(touchedPaths: Set<string>): void {
    // Path-gated fan-out: only wake subscribers whose query path was written to,
    // then re-evaluate each woken query (matches the real cache contract — no
    // over-fire to unrelated collections).
    for (const sub of subs.values()) {
      if (!touchedPaths.has(sub.query.path)) continue
      const docs = docsFor(sub.query)
      schedule(() => {
        if (subs.has(sub.id)) sub.cb(docs)
      })
    }
  }

  function subscribe(query: Query, onChange: OnChangeCallback): Unsubscribe {
    const id = nextId++
    subs.set(id, { id, query, cb: onChange })
    // Defer the initial delivery — the loading state is observable until flush.
    const snapshot = docsFor(query)
    schedule(() => {
      if (subs.has(id)) onChange(snapshot)
    })
    return () => {
      subs.delete(id)
    }
  }

  async function write(operation: WriteOp): Promise<void> {
    if (failNext) {
      const err = failNext
      failNext = null
      // Reject WITHOUT touching the authoritative cache — the source of truth
      // stays at its prior value, which is what a store reverts its cache to.
      throw err
    }
    const descs: WriteDescriptor[] = Array.isArray(operation) ? operation : [operation]
    cache = applyWrites(cache, descs)
    notify(new Set(descs.map(d => d.path)))
  }

  return {
    subscribe,
    write,
    flush,
    failNextWrite(error?: Error) {
      failNext = error ?? new Error('AsyncMemoryAdapter: forced write failure')
    },
    subscriberCount(path?: string) {
      if (path === undefined) return subs.size
      let n = 0
      for (const sub of subs.values()) if (sub.query.path === path) n++
      return n
    },
    authoritative(query: Query) {
      return docsFor(query)
    },
  }
}
