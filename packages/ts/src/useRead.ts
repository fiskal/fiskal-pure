// ---------------------------------------------------------------------------
// useRead — React hook for reading from the store
// ---------------------------------------------------------------------------
//
// Returns an explicit Loadable<Data | Data[]> (ADR-0013) — no null/undefined
// sentinels:
//   { status: 'loading' }            — no answer from the adapter yet
//   { status: 'missing' }            — single-item query whose id is absent
//   { status: 'loaded', data }       — a record, or a list (which may be empty)
//
// Backed by React's useSyncExternalStore so reads are tear-free and survive
// StrictMode's double-mount without double-subscribing.
//
// Referential stability: getSnapshot returns the SAME Loadable reference when
// the shaped value is unchanged, so useSyncExternalStore does not loop.
//
// Enrichment: both the snapshot source and the adapter callback route every
// record through store.enrich, so compute properties are present on the hook
// read path exactly as they are in wireView. (Terminology is generic "data",
// not "docs" — the library is not Firestore-specific.)

import { useCallback, useMemo, useRef, useSyncExternalStore } from 'react'
import { filterDocs, projectDoc } from './cache.js'
import { Loadable, type Doc, type Query, type StoreInstance } from './types.js'

type ReadValue = Loadable<Doc | Doc[]>

const NO_ID = '\x00NO_ID'

function applyProjection(data: Doc[], fields?: string[]): Doc[] {
  if (!fields || fields.length === 0) return data
  return data.map(d => projectDoc(d, fields))
}

function enrichData(store: StoreInstance, path: string, data: Doc[]): Doc[] {
  return data.map(d => store.enrich(path, d))
}

// Shared read path: enrich each record, then project. Used by both the snapshot
// source (selectData) and the adapter callback so the two cannot drift.
function readData(store: StoreInstance, path: string, data: Doc[], fields?: string[]): Doc[] {
  return applyProjection(enrichData(store, path, data), fields)
}

// Reads the current cache value for a query and returns enriched + projected
// data, or undefined while still loading (collection absent / item not cached).
// The `undefined` here is an INTERNAL loading sentinel; it never leaves this
// module — the public return shape is Loadable.
function selectData(store: StoreInstance, query: Query): Doc[] | undefined {
  const cache = store.getCache()

  if (query.id !== undefined) {
    const item = cache.get(query.path)?.get(query.id)
    if (!item) return undefined
    return readData(store, query.path, [item], query.fields)
  }

  if (!cache.has(query.path)) return undefined
  const col = cache.get(query.path)!
  const data = filterDocs(col, query.where)
  return readData(store, query.path, data, query.fields)
}

// Shapes a flat data list (or the loading sentinel) into a Loadable.
export function shapeLoadable(query: Query, data: Doc[] | undefined): ReadValue {
  if (data === undefined) return Loadable.loading()
  if (query.id !== undefined) {
    const first = data[0]
    return first ? Loadable.loaded(first) : Loadable.missing()
  }
  return Loadable.loaded(data)
}

function loadableEqual(a: ReadValue, b: ReadValue): boolean {
  if (a === b) return true
  if (a.status !== b.status) return false
  if (a.status === 'loaded' && b.status === 'loaded') {
    const ad = a.data
    const bd = b.data
    if (ad === bd) return true
    if (Array.isArray(ad) && Array.isArray(bd)) {
      if (ad.length !== bd.length) return false
      return ad.every((item, i) => item === bd[i])
    }
    return false
  }
  return true // both loading, or both missing
}

export function useRead(
  store: StoreInstance,
  query: Query,
): ReadValue {
  const queryRef = useRef<Query>(query)
  queryRef.current = query

  // Stable string keys for object/array deps — prevents infinite re-subscription
  // when query.where or query.fields are created inline (new ref on every render).
  const idKey = query.id ?? NO_ID
  const whereKey = query.where ? JSON.stringify(query.where) : ''
  const fieldsKey = query.fields ? query.fields.join('\x00') : ''

  const stateRef = useRef<{
    raw: Doc[] | undefined
    shapedFrom: Doc[] | undefined
    lastShaped: ReadValue
    hasShaped: boolean
  }>({ raw: undefined, shapedFrom: undefined, lastShaped: Loadable.loading(), hasShaped: false })

  // Reset the cached snapshot when the query identity changes so a new query
  // does not return a stale reference before its first adapter delivery.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  useMemo(() => {
    const cached = selectData(store, queryRef.current)
    stateRef.current = { raw: cached, shapedFrom: undefined, lastShaped: Loadable.loading(), hasShaped: false }
  }, [store, query.path, idKey, whereKey, fieldsKey])

  const subscribe = useCallback(
    (onStoreChange: () => void) => {
      return store.adapter.subscribe(queryRef.current, (raw: Doc[]) => {
        // Defense-in-depth: contract is Data[], but coerce null/bare-record from
        // a custom adapter so downstream enrich/project never throws.
        stateRef.current.raw = Array.isArray(raw) ? raw : raw == null ? [] : [raw as Doc]
        onStoreChange()
      })
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [store, query.path, idKey, whereKey, fieldsKey],
  )

  const getSnapshot = useCallback(
    (): ReadValue => {
      const q = queryRef.current
      const raw = stateRef.current.raw

      // Fast path: if the raw reference is unchanged since we last shaped, return
      // the cached Loadable — readData allocates fresh objects every call, so
      // re-shaping the same raw would yield a new reference and loop the store.
      if (stateRef.current.hasShaped && stateRef.current.shapedFrom === raw) {
        return stateRef.current.lastShaped
      }

      const data = raw === undefined ? undefined : readData(store, q.path, raw, q.fields)
      const next = shapeLoadable(q, data)

      if (stateRef.current.hasShaped && loadableEqual(stateRef.current.lastShaped, next)) {
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
