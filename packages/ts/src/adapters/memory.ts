// ---------------------------------------------------------------------------
// MemoryAdapter — in-process, synchronous adapter for tests and dev
// ---------------------------------------------------------------------------
//
// All writes are applied to the local cache immediately.
// subscribe() delivers docs synchronously on the first call and on every write.
// No network, no persistence — hermetic by design.

import { applyWrite, applyWrites, emptyCache, filterDocs, getCollection } from '../cache.js'
import {
  type Adapter,
  type CacheState,
  type Doc,
  type OnChangeCallback,
  type Query,
  type Unsubscribe,
  type WriteDescriptor,
  type WriteOp,
} from '../types.js'

interface Subscriber {
  query: Query
  callback: OnChangeCallback
}

function dataForQuery(cache: CacheState, query: Query): Doc[] {
  if (query.id) {
    const doc = cache.get(query.path)?.get(query.id)
    return doc ? [doc] : []
  }
  return filterDocs(getCollection(cache, query.path), query.where)
}

export function MemoryAdapter(initial?: Record<string, Doc[]>): Adapter {
  let cache: CacheState = emptyCache()
  if (initial) {
    for (const [collection, docs] of Object.entries(initial)) {
      for (const doc of docs) {
        const { id, ...fields } = doc
        cache = applyWrite(cache, { path: collection, id, fields, merge: false })
      }
    }
  }
  const subscribers: Set<Subscriber> = new Set()

  function notify(): void {
    for (const sub of subscribers) {
      sub.callback(dataForQuery(cache, sub.query))
    }
  }

  function subscribe(query: Query, onChange: OnChangeCallback): Unsubscribe {
    const sub: Subscriber = { query, callback: onChange }
    subscribers.add(sub)
    // Deliver current state synchronously
    onChange(dataForQuery(cache, query))
    return () => {
      subscribers.delete(sub)
    }
  }

  async function write(operation: WriteOp): Promise<void> {
    const descs: WriteDescriptor[] = Array.isArray(operation) ? operation : [operation]
    cache = applyWrites(cache, descs)
    notify()
  }

  return { subscribe, write }
}

/**
 * Expose cache read/write for test utilities (seed, reset).
 * Returns a store-like object that bundles the adapter with cache accessors.
 */
export interface MemoryStore {
  adapter: Adapter
  getCache(): CacheState
  seedCollection(collection: string, docs: Doc[]): void
  clearAll(): void
}

export function createMemoryStore(): MemoryStore {
  let cache: CacheState = emptyCache()
  const subscribers: Set<Subscriber> = new Set()

  function notify(): void {
    for (const sub of subscribers) {
      sub.callback(dataForQuery(cache, sub.query))
    }
  }

  const adapter: Adapter = {
    subscribe(query: Query, onChange: OnChangeCallback): Unsubscribe {
      const sub: Subscriber = { query, callback: onChange }
      subscribers.add(sub)
      onChange(dataForQuery(cache, query))
      return () => { subscribers.delete(sub) }
    },

    async write(operation: WriteOp): Promise<void> {
      const descs: WriteDescriptor[] = Array.isArray(operation) ? operation : [operation]
      cache = applyWrites(cache, descs)
      notify()
    },
  }

  function seedCollection(collection: string, docs: Doc[]): void {
    for (const doc of docs) {
      cache = applyWrite(cache, {
        path: collection,
        id: doc.id,
        fields: Object.fromEntries(Object.entries(doc).filter(([k]) => k !== 'id')),
        merge: false,
      })
    }
    notify()
  }

  function clearAll(): void {
    cache = emptyCache()
    notify()
  }

  return {
    adapter,
    getCache: () => cache,
    seedCollection,
    clearAll,
  }
}
