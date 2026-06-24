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
//   5c. Remote fails    — restore snapshot; write ErrorDoc to errors/; notify

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
  ErrorKind,
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
  action?: string
  write: (payload: P) => WriteOp
  read?: undefined
}

/** Read-then-write: derive queries from payload, then write using read results */
interface ReadThenWriteConfig<P extends Payload> {
  action?: string
  read: (payload: P) => Query[]
  write: (reads: Doc[][], payload: P) => WriteOp
}

/** Transaction: array of per-step descriptor factories, applied atomically */
interface TransactionConfig<P extends Payload> {
  action?: string
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
// Error classification
// ---------------------------------------------------------------------------

function classifyError(err: unknown): ErrorKind {
  if (!(err instanceof Error)) return 'unknown'
  const msg = err.message.toLowerCase()
  if (msg.includes('permission') || msg.includes('403') || msg.includes('unauthorized') || msg.includes('forbidden')) return 'permission'
  if (msg.includes('network') || msg.includes('fetch') || msg.includes('timeout') || msg.includes('offline') || msg.includes('connection')) return 'network'
  if (msg.includes('conflict') || msg.includes('409')) return 'conflict'
  if (msg.includes('validation') || msg.includes('schema') || msg.includes('invalid')) return 'validation'
  return 'unknown'
}

// ---------------------------------------------------------------------------
// Error ID counter — guarantees unique IDs even for same-ms failures
// ---------------------------------------------------------------------------

let _errorSeq = 0

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

export function createMutate<P extends Payload>(
  store: StoreInstance,
  config: MutateConfig<P>,
): (payload: P) => Promise<WriteOp> {
  const action = config.action ?? 'unknown'

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
      // Rollback optimistic update
      store.setCache(restoreCache(beforeSnapshot))
      for (const col of collections) {
        store.notify(col)
      }

      // Write error doc to errors/ collection (always in-memory, never remote)
      const errorId = `${action}-${Date.now()}-${++_errorSeq}`
      const errorDesc: WriteDescriptor = {
        collection: 'errors',
        id: errorId,
        fields: {
          action,
          kind: classifyError(err),
          message: err instanceof Error ? err.message : String(err),
          payload: payload as Record<string, unknown>,
          writes: descs,
          at: Date.now(),
          resolved: false,
        },
        merge: false,
      }
      store.setCache(applyWrites(store.getCache(), [errorDesc]))
      store.notify('errors')

      throw err
    }

    return operation
  }
}
