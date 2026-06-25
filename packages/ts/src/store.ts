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
import { createMutate } from './mutate.js'
import type { Adapter, CacheState, Doc, Model, MutateFn, MutateSpec, StoreInstance, Unsubscribe } from './types.js'

export interface StoreOptions {
  /** Per-collection model definitions. Keys are collection names. */
  models?: Record<string, Model>
  /** Inline mutate declarations. Resolved into callable MutateFns on the store. */
  mutates?: Record<string, MutateSpec>
}

export function createStore(adapter: Adapter, options?: StoreOptions): StoreInstance {
  let cache: CacheState = emptyCache()
  const models: Record<string, Model> = options?.models ?? {}

  // path → Set of change callbacks
  const subs = new Map<string, Set<() => void>>()

  function getCache(): CacheState {
    return cache
  }

  function setCache(next: CacheState): void {
    cache = next
  }

  function notify(path: string): void {
    const callbacks = subs.get(path)
    if (!callbacks) return
    for (const cb of callbacks) {
      cb()
    }
  }

  function subscribe(path: string, cb: () => void): Unsubscribe {
    if (!subs.has(path)) {
      subs.set(path, new Set())
    }
    subs.get(path)!.add(cb)
    return () => {
      subs.get(path)?.delete(cb)
    }
  }

  function enrich(path: string, doc: Doc): Doc {
    const model = models[path]
    if (!model?.compute) return doc
    return Object.defineProperties(
      Object.assign(Object.create(null), doc),
      Object.getOwnPropertyDescriptors(model.compute),
    ) as Doc
  }

  // Build the store instance with a placeholder mutates map that gets populated below.
  // The mutates map is filled in after construction so createMutate can reference
  // the complete StoreInstance (which requires mutates to exist on it).
  const resolvedMutates: Record<string, MutateFn> = {}
  const store: StoreInstance = { adapter, getCache, setCache, notify, subscribe, enrich, mutates: resolvedMutates }

  // Resolve inline mutate specs into callable MutateFns
  if (options?.mutates) {
    for (const [name, spec] of Object.entries(options.mutates)) {
      resolvedMutates[name] = createMutate<Record<string, unknown>>(store, spec as Parameters<typeof createMutate>[1]) as MutateFn
    }
  }

  return store
}
