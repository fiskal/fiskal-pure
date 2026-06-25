// ---------------------------------------------------------------------------
// Core types for fiskal-pure TypeScript package
// ---------------------------------------------------------------------------

/** Any document stored in the cache. Must have an `id` string. */
export type Doc = { id: string } & Record<string, unknown>

// ---------------------------------------------------------------------------
// Loadable — the canonical three-state read contract (ADR-0013)
// ---------------------------------------------------------------------------
//
// loading  — the query has not yet been answered by the adapter
// missing  — a single-doc query whose id is absent (never occurs for collections)
// loaded   — a Doc, or a Doc[] (which may legitimately be empty)
//
// On TS the default prop encoding stays `undefined | null | T` for zero-ceremony
// pure views (undefined=loading, null=missing, value=loaded). `Loadable<T>` is
// the explicit tagged form for views/tests that branch on the loading state.
// Swift uses `enum Loadable<T>` directly (it has no `undefined`).

export type Loadable<T> =
  | { status: 'loading' }
  | { status: 'missing' }
  | { status: 'loaded'; data: T }

export const Loadable = {
  loading: <T>(): Loadable<T> => ({ status: 'loading' }),
  missing: <T>(): Loadable<T> => ({ status: 'missing' }),
  loaded: <T>(data: T): Loadable<T> => ({ status: 'loaded', data }),
} as const

/** A query against a collection or a single document. */
export interface Query {
  path: string
  id?: string
  where?: Record<string, unknown>
  fields?: string[]
}

// ---------------------------------------------------------------------------
// Atomic operation sentinels
// These are replaced by adapter-native operations at write time.
// ---------------------------------------------------------------------------

// An atomic operation is a plain TUPLE — never a function call — so a write
// stays pure, serialisable data that round-trips identically across platforms:
//
//   ['::increment', 1]
//   ['::arrayUnion', ['done', 'urgent']]   // second element is the list of items
//   ['::arrayRemove', ['done']]
//   ['::serverTimestamp']                  // no value
//   ['::delete']                           // no value
//
// The first element is the op name (carrying the `::` sentinel prefix); the
// optional second element is the value the op needs.
export type AtomicOpName =
  | '::arrayUnion'
  | '::arrayRemove'
  | '::increment'
  | '::serverTimestamp'
  | '::delete'

export type AtomicOp = readonly [AtomicOpName] | readonly [AtomicOpName, unknown]

export function isAtomicOp(v: unknown): v is AtomicOp {
  return (
    Array.isArray(v) &&
    v.length >= 1 &&
    v.length <= 2 &&
    typeof v[0] === 'string' &&
    (v[0] as string).startsWith('::')
  )
}

// ---------------------------------------------------------------------------
// Write descriptors
// ---------------------------------------------------------------------------

/** Fields may contain plain values or AtomicOp sentinels. */
export type FieldMap = Record<string, unknown | AtomicOp>

export interface WriteDescriptor {
  path: string
  id: string
  /** When absent, an existing doc is left unchanged (patch); with fields, missing fields are preserved by default. */
  fields?: FieldMap
  /** merge defaults to true (patch existing fields); pass merge:false to fully replace the document. Default: true. */
  merge?: boolean
  /** If true, delete the document entirely. */
  delete?: boolean
}

/** A single write, an array of writes (all applied atomically), or a transaction callback. */
export type Write = WriteDescriptor
export type WriteOp = Write | Write[]

// ---------------------------------------------------------------------------
// Adapter protocol
// ---------------------------------------------------------------------------

export type OnChangeCallback = (docs: Doc[]) => void
export type Unsubscribe = () => void

export interface Adapter {
  /**
   * Subscribe to a collection or document query.
   * Calls `onChange` immediately with current data, then on every change.
   * Returns an unsubscribe function.
   */
  subscribe(query: Query, onChange: OnChangeCallback): Unsubscribe

  /**
   * Write one or more descriptors to the backing store.
   * When given an array, all writes are applied atomically.
   */
  write(operation: WriteOp): Promise<void>
}

// ---------------------------------------------------------------------------
// Cache snapshot (immutable value)
// ---------------------------------------------------------------------------

/** Structural-sharing cache: outer map is collection name, inner map is doc id. */
export type CacheState = ReadonlyMap<string, ReadonlyMap<string, Doc>>

// ---------------------------------------------------------------------------
// Model — schema + compute getters + computer methods per collection
// ---------------------------------------------------------------------------

export interface Model {
  /** JSON Schema used to validate writes before they reach the adapter. */
  schema?: Record<string, unknown>
  /**
   * Closure-based compute properties. Each key maps to a function that receives
   * the raw document and returns a plain value (for simple derived fields) or a
   * function (for dependent computes that take a sibling document).
   *
   * The store calls each function eagerly at read time and assigns the result as
   * a plain property on the enriched doc — safe to destructure, safe to spread.
   *
   * Simple:    statusLabel: (doc) => doc.status === 'active' ? 'In Progress' : 'Archived'
   * Dependent: progress:    (doc) => (sprint) => doc.done / sprint.total
   */
  compute?: Record<string, (doc: Record<string, unknown>) => unknown>
}

// ---------------------------------------------------------------------------
// Error document — written to `errors/` collection on write failure
// ---------------------------------------------------------------------------

export type ErrorKind = 'permission' | 'network' | 'validation' | 'conflict' | 'unknown'

export interface ErrorDoc extends Doc {
  action: string
  kind: ErrorKind
  message: string
  payload?: Record<string, unknown>
  writes?: WriteDescriptor[]
  at: number
  resolved: boolean
}

// ---------------------------------------------------------------------------
// Mutate types
// ---------------------------------------------------------------------------

export type MutateFn = (payload?: Record<string, unknown>) => Promise<unknown>

export interface MutateSpec<P = Record<string, unknown>> {
  write: (payload: P) => WriteOp
}

// ---------------------------------------------------------------------------
// Store instance
// ---------------------------------------------------------------------------

export interface StoreInstance {
  adapter: Adapter
  getCache(): CacheState
  setCache(next: CacheState): void
  /** Notify all subscribers for the given path. */
  notify(path: string): void
  /** Subscribe to cache changes for a given path. */
  subscribe(path: string, cb: () => void): Unsubscribe
  /**
   * Apply model compute descriptors to a raw doc. Returns the doc unchanged
   * when no model is registered for the path (identity function).
   */
  enrich(path: string, doc: Doc): Doc
  /** Per-collection model registry (schema + compute). Used by mutate for validation. */
  models: Record<string, Model>
  mutates: Record<string, MutateFn>
}
