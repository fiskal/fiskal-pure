// ---------------------------------------------------------------------------
// useRead — React hook for reading from the store
// ---------------------------------------------------------------------------
//
// Returns:
//   undefined   — loading (no data yet from adapter)
//   null        — doc not found (single-doc query with id)
//   Doc         — single document found
//   Doc[]       — collection query result (may be empty)
//
// Backed by React's useSyncExternalStore so reads are tear-free and survive
// StrictMode's double-mount without double-subscribing.
//
// Structural equality: re-render only fires when the data actually changes.
// getSnapshot returns the SAME reference when the shaped value is unchanged —
// structural sharing in the cache reuses object references, and shallowEqual
// then preserves the array/doc reference so React does not loop.
//
// Enrichment: both the snapshot source and the adapter callback route every
// doc through store.enrich, so compute properties are present on the hook read
// path exactly as they are in wireView.

import { useCallback, useMemo, useRef, useSyncExternalStore } from 'react'
import { filterDocs, projectDoc } from './cache.js'
import type { Doc, Query, StoreInstance } from './types.js'

type ReadResult = undefined | null | Doc | Doc[]

const NO_ID = '\x00NO_ID'

function applyProjection(docs: Doc[], fields?: string[]): Doc[] {
  if (!fields || fields.length === 0) return docs
  return docs.map(d => projectDoc(d, fields))
}

function enrichDocs(store: StoreInstance, path: string, docs: Doc[]): Doc[] {
  return docs.map(d => store.enrich(path, d))
}

// Shared read path: enrich each doc, then project. Used by both the snapshot
// source (selectDocs) and the adapter callback so the two cannot drift.
function readDocs(store: StoreInstance, path: string, docs: Doc[], fields?: string[]): Doc[] {
  return applyProjection(enrichDocs(store, path, docs), fields)
}

// Reads the current cache value for a query and returns enriched + projected
// docs, or undefined while still loading (collection absent / doc not yet cached).
function selectDocs(store: StoreInstance, query: Query): Doc[] | undefined {
  const cache = store.getCache()

  if (query.id !== undefined) {
    const doc = cache.get(query.path)?.get(query.id)
    if (!doc) return undefined
    return readDocs(store, query.path, [doc], query.fields)
  }

  // Only return results if the collection exists; undefined means "still loading"
  if (!cache.has(query.path)) return undefined
  const col = cache.get(query.path)!
  const docs = filterDocs(col, query.where)
  return readDocs(store, query.path, docs, query.fields)
}

// Shapes a flat doc list into the single-doc / collection ReadResult shape.
function shapeResult(query: Query, docs: Doc[] | undefined): ReadResult {
  if (!docs) return undefined
  if (query.id !== undefined) return docs.length > 0 ? docs[0] : null
  return docs
}

function shallowEqual(a: ReadResult, b: ReadResult): boolean {
  if (a === b) return true
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false
    return a.every((item, i) => item === b[i])
  }
  return false
}

export function useRead(
  store: StoreInstance,
  query: Query,
): ReadResult {
  const queryRef = useRef<Query>(query)
  queryRef.current = query

  // Stable string keys for object/array deps — prevents infinite re-subscription
  // when query.where or query.fields are created inline (new ref on every render).
  // idKey uses a sentinel distinct from '' so id:'' and absent-id produce
  // different subscription identities (matches wireView's id !== undefined).
  const idKey = query.id ?? NO_ID
  const whereKey = query.where ? JSON.stringify(query.where) : ''
  const fieldsKey = query.fields ? query.fields.join('\x00') : ''

  // Holds the docs most recently delivered by the adapter, and the last shaped
  // result we returned. lastShaped lets getSnapshot return a stable reference so
  // useSyncExternalStore does not re-render (or loop) when nothing changed.
  const stateRef = useRef<{
    raw: Doc[] | undefined
    shapedFrom: Doc[] | undefined
    lastShaped: ReadResult
    hasShaped: boolean
  }>({ raw: undefined, shapedFrom: undefined, lastShaped: undefined, hasShaped: false })

  // Reset the cached snapshot when the query identity changes so a new query
  // does not return a stale reference before its first adapter delivery.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useMemo(() => {
    const cached = selectDocs(store, queryRef.current)
    stateRef.current = { raw: cached, shapedFrom: undefined, lastShaped: undefined, hasShaped: false }
  }, [store, query.path, idKey, whereKey, fieldsKey])

  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      return store.adapter.subscribe(queryRef.current, (rawDocs: Doc[]) => {
        // Defense-in-depth: contract is Doc[], but coerce null/bare-doc from a
        // custom adapter so downstream enrich/project never throws.
        stateRef.current.raw = Array.isArray(rawDocs)
          ? rawDocs
          : rawDocs == null
            ? []
            : [rawDocs as Doc]
        onStoreChange()
      })
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [store, query.path, idKey, whereKey, fieldsKey],
  )

  const getSnapshot = useCallback(
    (): ReadResult => {
      const q = queryRef.current
      const raw = stateRef.current.raw

      // Fast path: if the raw docs reference is unchanged since we last shaped,
      // return the cached shaped value. This is essential because readDocs runs
      // enrich + projectDoc, both of which allocate fresh objects on every call —
      // re-shaping the same raw would yield a new reference each time and drive
      // useSyncExternalStore into an infinite re-render loop.
      if (stateRef.current.hasShaped && stateRef.current.shapedFrom === raw) {
        return stateRef.current.lastShaped
      }

      const docs = raw === undefined ? undefined : readDocs(store, q.path, raw, q.fields)
      const next = shapeResult(q, docs)

      // Preserve the previous reference when the shaped value is structurally
      // equal (e.g. a different raw array that filters/projects to the same docs).
      if (stateRef.current.hasShaped && shallowEqual(stateRef.current.lastShaped, next)) {
        stateRef.current.shapedFrom = raw
        return stateRef.current.lastShaped
      }
      stateRef.current.shapedFrom = raw
      stateRef.current.lastShaped = next
      stateRef.current.hasShaped = true
      return next
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [store, query.path, idKey, whereKey, fieldsKey],
  )

  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot)
}
