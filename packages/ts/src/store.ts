// ---------------------------------------------------------------------------
// createStore — wires an Adapter into a StoreInstance
// ---------------------------------------------------------------------------
//
// The store owns:
//   - The current CacheState (immutable value, replaced on every write)
//   - A subscriber registry (collection → Set<callback>)
//   - A model registry (collection → Model) for document enrichment
//   - Delegation to the adapter for remote subscribe / write

import { emptyCache } from './cache.js'
import type { Adapter, CacheState, Doc, Model, StoreInstance, Unsubscribe } from './types.js'

export interface StoreOptions {
  /** Per-collection model definitions. Keys are collection names. */
  models?: Record<string, Model>
}

export function createStore(adapter: Adapter, options?: StoreOptions): StoreInstance {
  let cache: CacheState = emptyCache()
  const models: Record<string, Model> = options?.models ?? {}

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

  function enrich(collection: string, doc: Doc): Doc {
    const model = models[collection]
    if (!model?.compute) return doc
    return Object.defineProperties(
      Object.assign(Object.create(null), doc),
      Object.getOwnPropertyDescriptors(model.compute),
    ) as Doc
  }

  return { adapter, getCache, setCache, notify, subscribe, enrich }
}
