// ---------------------------------------------------------------------------
// createMutate — pure factory for all state-changing operations
// ---------------------------------------------------------------------------
//
// Three call forms (keyed on the shape of `write`):
//
//   Write-only       write: (payload) => WriteDescriptor | WriteDescriptor[]
//   Read-then-write  read: (payload) => Query[],  write: (reads, payload) => WriteOp
//   Transaction      write: Array<(payload) => WriteDescriptor>  (all-or-nothing)
//
// Execution contract:
//   1. Snapshot pre-write cache state
//   2. Apply descriptor(s) to cache — synchronous, optimistic
//   3. Notify subscribers (useRead sees new cache immediately)
//   4. Dispatch async remote write
//   5a. Remote confirms — cache already correct; no action
//   5b. Remote differs  — adapter will push updated docs via subscribe
//   5c. Remote fails    — restore snapshot; notify subscribers (rollback)

import {
  applyWrites,
  snapshot as snapshotCache,
  restore as restoreCache,
  filterDocs,
  getCollection,
} from './cache.js'
import type {
  CacheState,
  Doc,
  Query,
  StoreInstance,
  WriteDescriptor,
  WriteOp,
} from './types.js'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type Payload = Record<string, unknown>

/** Write-only: payload → descriptor(s) */
interface WriteOnlyConfig<P extends Payload> {
  write: (payload: P) => WriteOp
  read?: undefined
}

/** Read-then-write: derive queries from payload, then write using read results */
interface ReadThenWriteConfig<P extends Payload> {
  read: (payload: P) => Query[]
  write: (reads: Doc[][], payload: P) => WriteOp
}

/** Transaction: array of per-step descriptor factories, applied atomically */
interface TransactionConfig<P extends Payload> {
  write: Array<(payload: P) => WriteDescriptor>
}

type MutateConfig<P extends Payload> =
  | WriteOnlyConfig<P>
  | ReadThenWriteConfig<P>
  | TransactionConfig<P>

function isReadThenWrite<P extends Payload>(
  config: MutateConfig<P>,
): config is ReadThenWriteConfig<P> {
  return 'read' in config && typeof config.read === 'function'
}

function isTransaction<P extends Payload>(
  config: MutateConfig<P>,
): config is TransactionConfig<P> {
  return Array.isArray(config.write)
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createMutate<P extends Payload>(
  store: StoreInstance,
  config: MutateConfig<P>,
): (payload: P) => Promise<WriteOp> {
  return async function mutate(payload: P): Promise<WriteOp> {
    const beforeSnapshot = snapshotCache(store.getCache())
    let operation: WriteOp

    if (isReadThenWrite(config)) {
      // Read from cache synchronously
      const queries = config.read(payload)
      const reads = queries.map(q => {
        const col = getCollection(store.getCache(), q.collection)
        return filterDocs(col, q.where)
      })
      operation = config.write(reads, payload)
    } else if (isTransaction(config)) {
      // Array of per-step factories → single atomic WriteDescriptor[]
      operation = (config.write as Array<(p: P) => WriteDescriptor>).map(fn =>
        fn(payload),
      )
    } else {
      operation = (config as WriteOnlyConfig<P>).write(payload)
    }

    // Optimistic: apply to cache immediately
    const descs: WriteDescriptor[] = Array.isArray(operation)
      ? operation
      : [operation]
    let nextCache: CacheState = store.getCache()
    try {
      nextCache = applyWrites(store.getCache(), descs)
    } catch {
      // If local application fails, do not proceed
      throw new Error('Optimistic cache update failed before remote write')
    }
    store.setCache(nextCache)

    // Notify all affected collections
    const collections = new Set(descs.map(d => d.collection))
    for (const col of collections) {
      store.notify(col)
    }

    // Async remote write
    try {
      await store.adapter.write(operation)
    } catch (err) {
      // Rollback: restore snapshot
      store.setCache(restoreCache(beforeSnapshot))
      for (const col of collections) {
        store.notify(col)
      }
      throw err
    }

    return operation
  }
}

