// ---------------------------------------------------------------------------
// Test utilities for fiskal-pure
// ---------------------------------------------------------------------------
//
// All helpers are framework-agnostic — they work with vitest and jest.
//
// API:
//   createTestStore(config?)      → StoreInstance with MemoryAdapter pre-wired
//   seed(store, data)             → write collections of docs into the store
//   reset(store)                  → clear all docs and reset to empty cache
//   resolveWrites(mutate, payload)→ Promise<WriteDescriptor[]>
//   shouldPass(mutate)            → vitest/jest helper that asserts success
//   shouldFail(mutate)            → vitest/jest helper that asserts rejection

import { createMemoryStore, type MemoryStore } from '../adapters/memory.js'
import { createStore } from '../store.js'
import { applyWrites, emptyCache, snapshot as cacheSnapshot, restore as cacheRestore } from '../cache.js'
import type {
  Doc,
  StoreInstance,
  WriteDescriptor,
  WriteOp,
} from '../types.js'

// ---------------------------------------------------------------------------
// TestStore — StoreInstance extended with test helpers
// ---------------------------------------------------------------------------

export interface TestStore extends StoreInstance {
  /** Seed collections from a map of { collectionName: Doc[] }. */
  seed(data: Record<string, Doc[]>): void
  /** Clear all docs and reset cache to empty. */
  reset(): void
}

// ---------------------------------------------------------------------------
// createTestStore
// ---------------------------------------------------------------------------

export function createTestStore(): TestStore {
  const ms: MemoryStore = createMemoryStore()
  const base = createStore(ms.adapter)

  function seed(data: Record<string, Doc[]>): void {
    for (const [collection, docs] of Object.entries(data)) {
      ms.seedCollection(collection, docs)
    }
    // Sync the base store's cache from memory store
    // MemoryAdapter is the backing store; base store cache is updated via subscribe.
    // For test purposes we directly sync the snapshot:
    base.setCache(ms.getCache())
  }

  function reset(): void {
    ms.clearAll()
    base.setCache(ms.getCache())
  }

  return {
    ...base,
    seed,
    reset,
  }
}

// ---------------------------------------------------------------------------
// seed — standalone helper for an existing StoreInstance
// ---------------------------------------------------------------------------

export function seed(store: StoreInstance, data: Record<string, Doc[]>): void {
  const descs: WriteDescriptor[] = []
  for (const [collection, docs] of Object.entries(data)) {
    for (const doc of docs) {
      const { id, ...rest } = doc
      descs.push({
        path: collection,
        id,
        fields: rest,
        merge: false,
      })
    }
  }
  // Update store cache synchronously (for useState initializer reads)
  const nextCache = applyWrites(store.getCache(), descs)
  store.setCache(nextCache)
  // Also write to the adapter so its internal cache is in sync.
  // MemoryAdapter.write() is synchronous in practice. Failures are swallowed —
  // some tests use a mocked failing adapter; the store cache is still seeded above.
  store.adapter.write(descs).catch(() => {})
  // Notify store-level subscribers
  const paths = new Set(descs.map(d => d.path))
  for (const p of paths) {
    store.notify(p)
  }
}

// ---------------------------------------------------------------------------
// reset — standalone helper
// ---------------------------------------------------------------------------

export function reset(store: StoreInstance): void {
  // Re-initialise to empty cache
  // Note: adapter state cannot be cleared here — use createTestStore() for full isolation
  store.setCache(emptyCache())
}

// ---------------------------------------------------------------------------
// resolveWrites
// ---------------------------------------------------------------------------
//
// Runs a mutate function and captures the WriteDescriptors it produces.
// The function must accept a payload and return a Promise<WriteOp>.
// For store-bound mutates created with createMutate(), callers should wire
// an ephemeral store and pass the bound mutate here.

export async function resolveWrites<P extends Record<string, unknown>>(
  mutateFn: (payload: P) => Promise<WriteOp>,
  payload: P,
): Promise<WriteDescriptor[]> {
  const result = await mutateFn(payload)
  const descs: WriteDescriptor[] = Array.isArray(result)
    ? result
    : [result as WriteDescriptor]
  return descs
}

// ---------------------------------------------------------------------------
// shouldPass — vitest/jest helper factory
// ---------------------------------------------------------------------------
//
// Usage:
//   it('...', shouldPass(myMutate)({ payload: { id: '1' }, expected: [...] }))

export function shouldPass<P extends Record<string, unknown>>(
  mutateFn: (payload: P) => Promise<WriteOp>,
): (testCase: { payload: P; expected: WriteDescriptor[] }) => () => Promise<void> {
  return ({ payload, expected }) =>
    async () => {
      const descriptors = await resolveWrites(mutateFn, payload)
      // Deep equality check — allows vitest `expect` or manual assertion
      assertDeepEqual(descriptors, expected)
    }
}

// ---------------------------------------------------------------------------
// shouldFail — vitest/jest helper factory
// ---------------------------------------------------------------------------

export function shouldFail<P extends Record<string, unknown>>(
  mutateFn: (payload: P) => Promise<WriteOp>,
): (testCase: { payload: P }) => () => Promise<void> {
  return ({ payload }) =>
    async () => {
      let threw = false
      try {
        await mutateFn(payload)
      } catch {
        threw = true
      }
      if (!threw) {
        throw new Error(
          `shouldFail: expected mutate to throw for payload ${JSON.stringify(payload)}, but it resolved`,
        )
      }
    }
}

// ---------------------------------------------------------------------------
// Deep equality helper (no test framework dependency)
// ---------------------------------------------------------------------------

function assertDeepEqual(a: unknown, b: unknown, path = ''): void {
  if (a === b) return

  if (typeof a !== typeof b) {
    throw new Error(`Type mismatch at ${path || 'root'}: ${typeof a} !== ${typeof b}`)
  }

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) {
      throw new Error(
        `Array length mismatch at ${path || 'root'}: ${a.length} !== ${b.length}`,
      )
    }
    a.forEach((item, i) => assertDeepEqual(item, b[i], `${path}[${i}]`))
    return
  }

  if (
    a !== null &&
    b !== null &&
    typeof a === 'object' &&
    typeof b === 'object'
  ) {
    const aKeys = Object.keys(a as object).sort()
    const bKeys = Object.keys(b as object).sort()
    if (JSON.stringify(aKeys) !== JSON.stringify(bKeys)) {
      throw new Error(
        `Key mismatch at ${path || 'root'}: [${aKeys.join(',')}] !== [${bKeys.join(',')}]`,
      )
    }
    for (const key of aKeys) {
      assertDeepEqual(
        (a as Record<string, unknown>)[key],
        (b as Record<string, unknown>)[key],
        `${path}.${key}`,
      )
    }
    return
  }

  throw new Error(
    `Value mismatch at ${path || 'root'}: ${JSON.stringify(a)} !== ${JSON.stringify(b)}`,
  )
}

// ---------------------------------------------------------------------------
// Re-export commonly needed primitives for test files
// ---------------------------------------------------------------------------

export {
  arrayUnion,
  arrayRemove,
  increment,
  serverTimestamp,
  deleteField,
} from '../types.js'

export { snapshot as cacheSnapshot, restore as cacheRestore } from '../cache.js'

export { createAsyncMemoryAdapter, type AsyncMemoryAdapter } from './asyncMemoryAdapter.js'
