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
// Structural equality: re-render only fires when the data actually changes.
// Uses a shallow reference check on the docs array — structural sharing in
// the cache ensures the same object references are reused when unchanged.

import { useEffect, useRef, useState } from 'react'
import { filterDocs, projectDoc } from './cache.js'
import type { Doc, Query, StoreInstance } from './types.js'

type ReadResult = undefined | null | Doc | Doc[]

function applyProjection(docs: Doc[], fields?: string[]): Doc[] {
  if (!fields || fields.length === 0) return docs
  return docs.map(d => projectDoc(d, fields))
}

function selectDocs(store: StoreInstance, query: Query): Doc[] | undefined {
  const cache = store.getCache()

  if (query.id) {
    const doc = cache.get(query.path)?.get(query.id)
    if (!doc) return undefined
    return applyProjection([doc], query.fields)
  }

  // Only return results if the collection exists; undefined means "still loading"
  if (!cache.has(query.path)) return undefined
  const col = cache.get(query.path)!
  const docs = filterDocs(col, query.where)
  return applyProjection(docs, query.fields)
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
  const whereKey = query.where ? JSON.stringify(query.where) : ''
  const fieldsKey = query.fields ? query.fields.join('\x00') : ''

  const [result, setResult] = useState<ReadResult>(() => {
    const cached = selectDocs(store, query)
    if (!cached) return undefined
    if (query.id) return cached.length > 0 ? cached[0] : null
    return cached
  })

  useEffect(() => {
    let settled = false

    const unsub = store.adapter.subscribe(queryRef.current, (rawDocs: Doc[]) => {
      settled = true
      setResult(prev => {
        const q = queryRef.current
        const projected = applyProjection(rawDocs, q.fields)
        const next: ReadResult = q.id
          ? projected.length > 0
            ? projected[0]
            : null
          : projected
        return shallowEqual(prev, next) ? prev : next
      })
    })

    if (!settled) {
      // async adapter (Firestore) — stay in loading state until callback fires
    }

    return unsub
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [store, query.path, query.id ?? '', whereKey, fieldsKey])

  return result
}
