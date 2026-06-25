// ---------------------------------------------------------------------------
// Cache — immutable, structurally shared document store
// ---------------------------------------------------------------------------
//
// The cache is a two-level immutable Map:
//   collection name -> (doc id -> Doc)
//
// Structural sharing: writing to doc A replaces only the inner map for its
// collection, leaving all other collection maps — and all other docs within
// that collection — untouched (same reference).
//
// AtomicOp sentinels (::arrayUnion, ::arrayRemove, ::increment, ::delete)
// are resolved here so tests and MemoryAdapter share identical logic.

import {
  type AtomicOp,
  type CacheState,
  type Doc,
  type FieldMap,
  type WriteDescriptor,
  isAtomicOp,
} from './types.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function resolveField(current: unknown, op: AtomicOp): unknown {
  const [name, value] = op
  switch (name) {
    case '::arrayUnion': {
      const arr = Array.isArray(current) ? current : []
      const items = Array.isArray(value) ? value : [value]
      const additions = items.filter(v => !arr.includes(v))
      return [...arr, ...additions]
    }
    case '::arrayRemove': {
      const arr = Array.isArray(current) ? current : []
      const items = Array.isArray(value) ? value : [value]
      const removal = new Set(items)
      return arr.filter((v: unknown) => !removal.has(v))
    }
    case '::increment': {
      const base = typeof current === 'number' ? current : 0
      return base + (typeof value === 'number' ? value : 0)
    }
    case '::serverTimestamp':
      return new Date().toISOString()
    case '::delete':
      return undefined
  }
}

/** Apply a FieldMap on top of an existing doc, resolving AtomicOp sentinels. */
function applyFields(doc: Doc, fields: FieldMap): Doc {
  const next: Record<string, unknown> = { ...doc }
  for (const [key, value] of Object.entries(fields)) {
    if (isAtomicOp(value)) {
      const resolved = resolveField(next[key], value)
      if (resolved === undefined) {
        delete next[key]
      } else {
        next[key] = resolved
      }
    } else {
      next[key] = value
    }
  }
  return next as Doc
}

// ---------------------------------------------------------------------------
// Empty cache constructor
// ---------------------------------------------------------------------------

export function emptyCache(): CacheState {
  return new Map()
}

// ---------------------------------------------------------------------------
// Read helpers
// ---------------------------------------------------------------------------

export function getCollection(
  cache: CacheState,
  collection: string,
): ReadonlyMap<string, Doc> {
  return cache.get(collection) ?? new Map()
}

export function getDoc(
  cache: CacheState,
  collection: string,
  id: string,
): Doc | undefined {
  return cache.get(collection)?.get(id)
}

// ---------------------------------------------------------------------------
// Write — structural sharing
// ---------------------------------------------------------------------------

/**
 * Apply a single WriteDescriptor to the cache and return a new CacheState.
 * The returned cache shares all collection maps that were not touched.
 */
export function applyWrite(cache: CacheState, desc: WriteDescriptor): CacheState {
  const col = cache.get(desc.path) ?? new Map<string, Doc>()

  if (desc.delete) {
    if (!col.has(desc.id)) return cache
    const nextCol = new Map(col)
    nextCol.delete(desc.id)
    const nextCache = new Map(cache)
    nextCache.set(desc.path, nextCol)
    return nextCache
  }

  const existing = col.get(desc.id)

  let nextDoc: Doc
  if (desc.fields) {
    // Default is merge (patch existing). Only merge: false opts into full replacement.
    const base: Doc = desc.merge !== false ? (existing ?? { id: desc.id }) : { id: desc.id }
    nextDoc = applyFields(base, desc.fields)
  } else {
    // No fields provided — no-op for existing, create empty doc otherwise
    nextDoc = existing ?? { id: desc.id }
  }

  if (existing === nextDoc) return cache // nothing changed

  const nextCol = new Map(col)
  nextCol.set(desc.id, nextDoc)
  const nextCache = new Map(cache)
  nextCache.set(desc.path, nextCol)
  return nextCache
}

/**
 * Apply multiple WriteDescriptors atomically — each descriptor is applied in
 * order to the intermediate cache; the final state is returned as one value.
 * If any descriptor throws, none of the writes are visible (the original
 * cache reference is returned from the try/catch caller).
 */
export function applyWrites(cache: CacheState, descs: WriteDescriptor[]): CacheState {
  return descs.reduce(applyWrite, cache)
}

// ---------------------------------------------------------------------------
// Snapshot / restore
// ---------------------------------------------------------------------------

/**
 * Serialize a CacheState to a plain JSON-safe object.
 * Useful for snapshot testing and rollback checkpointing.
 */
export function snapshot(cache: CacheState): Record<string, Record<string, Doc>> {
  const out: Record<string, Record<string, Doc>> = {}
  for (const [col, docs] of cache) {
    out[col] = {}
    for (const [id, doc] of docs) {
      out[col][id] = { ...doc }  // shallow copy so snapshot is independent of live cache
    }
  }
  return out
}

/**
 * Restore a CacheState from a plain object (the inverse of snapshot).
 */
export function restore(raw: Record<string, Record<string, Doc>>): CacheState {
  const cache = new Map<string, ReadonlyMap<string, Doc>>()
  for (const [col, docs] of Object.entries(raw)) {
    const inner = new Map<string, Doc>()
    for (const [id, doc] of Object.entries(docs)) {
      inner.set(id, { ...doc })  // copy so mutating the raw snapshot doesn't affect restored cache
    }
    cache.set(col, inner)
  }
  return cache
}

// ---------------------------------------------------------------------------
// Query helpers
// ---------------------------------------------------------------------------

/** Filter a collection map by a where-clause (shallow equality per key). */
export function filterDocs(
  docs: ReadonlyMap<string, Doc>,
  where?: Record<string, unknown>,
): Doc[] {
  const all = Array.from(docs.values())
  if (!where || Object.keys(where).length === 0) return all
  return all.filter(doc =>
    Object.entries(where).every(([k, v]) => doc[k] === v),
  )
}

/** Project a doc down to a requested set of fields (always includes `id`). */
export function projectDoc(doc: Doc, fields: string[]): Doc {
  const out: Record<string, unknown> = { id: doc.id }
  for (const f of fields) {
    if (f in doc) out[f] = doc[f]
  }
  return out as Doc
}
