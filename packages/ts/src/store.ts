// ---------------------------------------------------------------------------
// createStore — wires an Adapter into a StoreInstance
// ---------------------------------------------------------------------------
//
// The store owns:
//   - The current CacheState (immutable value, replaced on every write)
//   - A subscriber registry (collection → Set<callback>)
//   - Delegation to the adapter for remote subscribe / write

import { emptyCache } from './cache.js'
import type { Adapter, CacheState, StoreInstance, Unsubscribe } from './types.js'

export function createStore(adapter: Adapter): StoreInstance {
  let cache: CacheState = emptyCache()

  // collection name → Set of change callbacks
  const subs = new Map<string, Set<() => void>>()

  function getCache(): CacheState {
    return cache
  }

  function setCache(next: CacheState): void {
    cache = next
  }

  function notify(collection: string): void {
    const callbacks = subs.get(collection)
    if (!callbacks) return
    for (const cb of callbacks) {
      cb()
    }
  }

  function subscribe(collection: string, cb: () => void): Unsubscribe {
    if (!subs.has(collection)) {
      subs.set(collection, new Set())
    }
    subs.get(collection)!.add(cb)
    return () => {
      subs.get(collection)?.delete(cb)
    }
  }

  return { adapter, getCache, setCache, notify, subscribe }
}
