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
import { filterDocs, getCollection, projectDoc } from './cache.js'
import type { Doc, Query, StoreInstance } from './types.js'

type ReadResult = undefined | null | Doc | Doc[]

function selectDocs(store: StoreInstance, query: Query): Doc[] | undefined {
  const cache = store.getCache()

  if (query.id) {
    const doc = cache.get(query.collection)?.get(query.id)
    return doc ? [doc] : undefined
  }

  const col = getCollection(cache, query.collection)
  const docs = filterDocs(col, query.where)

  if (query.fields && query.fields.length > 0) {
    return docs.map(d => projectDoc(d, query.fields!))
  }

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

  const [result, setResult] = useState<ReadResult>(() => {
    // Try to read from cache synchronously on first render
    const cached = selectDocs(store, query)
    if (!cached) return undefined
    if (query.id) return cached.length > 0 ? cached[0] : null
    return cached
  })

  useEffect(() => {
    let settled = false

    const unsub = store.adapter.subscribe(queryRef.current, (docs: Doc[]) => {
      settled = true
      setResult(prev => {
        const next: ReadResult = queryRef.current.id
          ? docs.length > 0
            ? docs[0]
            : null
          : docs
        return shallowEqual(prev, next) ? prev : next
      })
    })

    // If the adapter didn't deliver synchronously, keep loading state.
    // The subscription callback will fire when data arrives.
    if (!settled) {
      // Check cache one more time — MemoryAdapter fires synchronously above
      // but async adapters (Firestore) will not have settled yet.
    }

    return unsub
  }, [store, query.collection, query.id, query.where, query.fields])

  return result
}
