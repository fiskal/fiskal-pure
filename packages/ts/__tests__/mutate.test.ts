// ---------------------------------------------------------------------------
// mutate.test.ts — unit tests for createMutate
// ---------------------------------------------------------------------------
//
// Coverage:
//   - Write-only mutate updates cache synchronously (optimistic)
//   - Read-then-write resolves reads from cache before writing
//   - Transaction: all writes applied atomically to cache
//   - Optimistic: cache updated before remote resolves
//   - Rollback: cache restored on remote failure
//   - shouldPass / shouldFail helpers work correctly

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createMutate } from '../src/mutate.js'
import { createStore } from '../src/store.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed, shouldPass, shouldFail, resolveWrites } from '../src/test/index.js'
import { getDoc } from '../src/cache.js'
import type { Doc, StoreInstance, WriteOp } from '../src/types.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeStore(): StoreInstance {
  return createStore(MemoryAdapter())
}

function mkDoc(overrides: Partial<Doc> & { id: string }): Doc {
  return { title: '', done: false, ...overrides }
}

// ---------------------------------------------------------------------------
// Write-only
// ---------------------------------------------------------------------------

describe('write-only mutate', () => {
  it('updates cache synchronously before remote resolves', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 't1', title: 'Original', done: false })] })

    let cacheStateAfterOptimistic: Doc | undefined
    let remoteResolved = false

    // Intercept adapter.write to inspect cache mid-flight
    const originalWrite = store.adapter.write.bind(store.adapter)
    vi.spyOn(store.adapter, 'write').mockImplementation(async (op) => {
      // Cache should already be updated before this runs
      cacheStateAfterOptimistic = getDoc(store.getCache(), 'tasks', 't1')
      remoteResolved = true
      return originalWrite(op)
    })

    const complete = createMutate<{ id: string }>(store, {
      write: ({ id }) => ({
        path: 'tasks',
        id,
        fields: { done: true },
        merge: true,
      }),
    })

    await complete({ id: 't1' })

    // Optimistic update was visible during the remote write
    expect(cacheStateAfterOptimistic?.done).toBe(true)
    expect(remoteResolved).toBe(true)
    // Final state also correct
    expect(getDoc(store.getCache(), 'tasks', 't1')?.done).toBe(true)
  })

  it('returns the WriteOp produced by the write function', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 't2' })] })

    const complete = createMutate<{ id: string }>(store, {
      write: ({ id }) => ({ path: 'tasks', id, fields: { done: true }, merge: true }),
    })

    const result = await complete({ id: 't2' })
    expect(result).toMatchObject({ path: 'tasks', id: 't2' })
  })
})

// ---------------------------------------------------------------------------
// Read-then-write
// ---------------------------------------------------------------------------

describe('read-then-write mutate', () => {
  it('resolves reads from cache before writing', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [
        mkDoc({ id: 'r1', title: 'Task A', done: false }),
        mkDoc({ id: 'r2', title: 'Task B', done: false }),
      ],
    })

    // Mutate that reads all undone tasks and marks them done
    const completeAll = createMutate<Record<string, never>>(store, {
      read: () => [{ path: 'tasks', where: { done: false } }],
      write: ([undoneTasks]) => undoneTasks.map(doc => ({
        path: 'tasks',
        id: doc.id,
        fields: { done: true },
        merge: true,
      })),
    })

    await completeAll({})

    expect(getDoc(store.getCache(), 'tasks', 'r1')?.done).toBe(true)
    expect(getDoc(store.getCache(), 'tasks', 'r2')?.done).toBe(true)
  })

  it('read receives only docs matching the query where clause', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [
        mkDoc({ id: 's1', done: false }),
        mkDoc({ id: 's2', done: true }),  // already done — should not be touched
      ],
    })

    const readCapture: Doc[][] = []
    const toggle = createMutate<Record<string, never>>(store, {
      read: () => [{ path: 'tasks', where: { done: false } }],
      write: (reads) => {
        readCapture.push(reads[0])
        return reads[0].map(doc => ({
          path: 'tasks',
          id: doc.id,
          fields: { done: true },
          merge: true,
        }))
      },
    })

    await toggle({})

    expect(readCapture[0]).toHaveLength(1)
    expect(readCapture[0][0].id).toBe('s1')
  })
})

// ---------------------------------------------------------------------------
// Transaction (atomic batch)
// ---------------------------------------------------------------------------

describe('transaction mutate', () => {
  it('applies all writes atomically — all succeed or none', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'txn1', done: false })],
      logs: [],
    })

    const archiveTask = createMutate<{ id: string }>(store, {
      write: [
        ({ id }) => ({ path: 'tasks', id, delete: true }),
        ({ id }) => ({ path: 'logs', id: `log-${id}`, fields: { action: 'archived', taskId: id }, merge: false }),
      ],
    })

    await archiveTask({ id: 'txn1' })

    expect(getDoc(store.getCache(), 'tasks', 'txn1')).toBeUndefined()
    expect(getDoc(store.getCache(), 'logs', 'log-txn1')?.action).toBe('archived')
  })

  it('applies all writes in the declared order', async () => {
    const store = makeStore()
    seed(store, { counters: [{ id: 'c1', value: 0 }] })

    const { increment } = await import('../src/types.js')

    const doubleIncrement = createMutate<Record<string, never>>(store, {
      write: [
        () => ({ path: 'counters', id: 'c1', fields: { value: increment(10) }, merge: true }),
        () => ({ path: 'counters', id: 'c1', fields: { value: increment(5) }, merge: true }),
      ],
    })

    await doubleIncrement({})

    expect(getDoc(store.getCache(), 'counters', 'c1')?.value).toBe(15)
  })
})

// ---------------------------------------------------------------------------
// Optimistic update
// ---------------------------------------------------------------------------

describe('optimistic update', () => {
  it('cache reflects the write before remote write resolves', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'opt1', done: false })] })

    let cacheSnapshot: Doc | undefined

    vi.spyOn(store.adapter, 'write').mockImplementation(async () => {
      // Capture cache state inside the async remote call
      cacheSnapshot = getDoc(store.getCache(), 'tasks', 'opt1')
    })

    const complete = createMutate<{ id: string }>(store, {
      write: ({ id }) => ({ path: 'tasks', id, fields: { done: true }, merge: true }),
    })

    await complete({ id: 'opt1' })
    expect(cacheSnapshot?.done).toBe(true)
  })
})

// ---------------------------------------------------------------------------
// Rollback
// ---------------------------------------------------------------------------

describe('rollback on remote failure', () => {
  it('restores pre-write cache state when remote write rejects', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'rb1', done: false })] })

    vi.spyOn(store.adapter, 'write').mockRejectedValue(new Error('network error'))

    const complete = createMutate<{ id: string }>(store, {
      write: ({ id }) => ({ path: 'tasks', id, fields: { done: true }, merge: true }),
    })

    await expect(complete({ id: 'rb1' })).rejects.toThrow('network error')

    // Cache should be rolled back to pre-write state
    expect(getDoc(store.getCache(), 'tasks', 'rb1')?.done).toBe(false)
  })

  it('restores pre-write cache for a batch write', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'rb2', done: false })],
      logs: [],
    })

    vi.spyOn(store.adapter, 'write').mockRejectedValue(new Error('server down'))

    const archiveTask = createMutate<{ id: string }>(store, {
      write: [
        ({ id }) => ({ path: 'tasks', id, delete: true }),
        ({ id }) => ({ path: 'logs', id: `log-${id}`, fields: { action: 'archived' }, merge: false }),
      ],
    })

    await expect(archiveTask({ id: 'rb2' })).rejects.toThrow('server down')

    // Both writes rolled back
    expect(getDoc(store.getCache(), 'tasks', 'rb2')).toBeDefined() // task restored
    expect(getDoc(store.getCache(), 'logs', 'log-rb2')).toBeUndefined() // log removed
  })
})

// ---------------------------------------------------------------------------
// shouldPass / shouldFail helpers
// ---------------------------------------------------------------------------

describe('shouldPass / shouldFail helpers', () => {
  // A simple mutate that fails on empty id
  function fakeMutate({ id }: { id: string }): Promise<WriteOp> {
    if (!id) return Promise.reject(new Error('id required'))
    return Promise.resolve({ path: 'tasks', id, fields: { done: true }, merge: true })
  }

  it('shouldPass asserts the returned descriptor matches expected', async () => {
    const run = shouldPass(fakeMutate)({
      payload: { id: 'x1' },
      expected: [{ path: 'tasks', id: 'x1', fields: { done: true }, merge: true }],
    })
    await expect(run()).resolves.toBeUndefined()
  })

  it('shouldPass throws when descriptor does not match', async () => {
    const run = shouldPass(fakeMutate)({
      payload: { id: 'x2' },
      expected: [{ path: 'tasks', id: 'WRONG', fields: { done: true }, merge: true }],
    })
    await expect(run()).rejects.toThrow()
  })

  it('shouldFail passes when mutate throws', async () => {
    const run = shouldFail(fakeMutate)({ payload: { id: '' } })
    await expect(run()).resolves.toBeUndefined()
  })

  it('shouldFail throws when mutate resolves instead of rejecting', async () => {
    const run = shouldFail(fakeMutate)({ payload: { id: 'valid' } })
    await expect(run()).rejects.toThrow('shouldFail')
  })

  it('resolveWrites returns descriptors without side effects', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'rw1', done: false })] })
    const descriptors = await resolveWrites(fakeMutate, { id: 'rw1' })
    expect(descriptors[0].path).toBe('tasks')
    expect(descriptors[0].id).toBe('rw1')
  })
})
