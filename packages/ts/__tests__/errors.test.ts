// ---------------------------------------------------------------------------
// errors.test.ts — unit tests for errors collection (ADR-0008)
// ---------------------------------------------------------------------------

import { describe, it, expect, vi } from 'vitest'
import { createStore } from '../src/store.js'
import { createMutate } from '../src/mutate.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed, resolveWrites } from '../src/test/index.js'
import { filterDocs, getCollection } from '../src/cache.js'
import type { ErrorDoc } from '../src/types.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getErrors(store: ReturnType<typeof createStore>): ErrorDoc[] {
  const col = getCollection(store.getCache(), 'errors')
  return filterDocs(col) as unknown as ErrorDoc[]
}

function makeFailingStore() {
  const adapter = MemoryAdapter()
  const write = vi.spyOn(adapter, 'write').mockRejectedValue(new Error('Network unavailable'))
  const store = createStore(adapter)
  return { store, adapter, write }
}

// ---------------------------------------------------------------------------
// Write failure writes ErrorDoc
// ---------------------------------------------------------------------------

describe('errors collection on write failure', () => {
  it('writes an ErrorDoc to errors/ when remote write fails', async () => {
    const { store } = makeFailingStore()

    const archiveTask = createMutate(store, {
      action: 'ArchiveTask',
      write: ({ id }) => ({
        path: 'tasks',
        id: String(id),
        fields: { status: 'archived' },
        merge: true,
      }),
    })

    seed(store, { tasks: [{ id: 'task-1', title: 'Deploy', status: 'active' }] })

    await archiveTask({ id: 'task-1' }).catch(() => {})

    const errors = getErrors(store)
    expect(errors).toHaveLength(1)
    expect(errors[0]?.action).toBe('ArchiveTask')
    expect(errors[0]?.kind).toBe('network')
    expect(errors[0]?.resolved).toBe(false)
  })

  it('error kind is "unknown" for generic errors', async () => {
    const adapter = MemoryAdapter()
    vi.spyOn(adapter, 'write').mockRejectedValue(new Error('something broke'))
    const store = createStore(adapter)

    const doThing = createMutate(store, {
      action: 'DoThing',
      write: () => ({ path: 'things', id: 'x', fields: { v: 1 } }),
    })

    await doThing({}).catch(() => {})

    const errors = getErrors(store)
    expect(errors[0]?.kind).toBe('unknown')
  })

  it('error kind is "permission" for permission errors', async () => {
    const adapter = MemoryAdapter()
    vi.spyOn(adapter, 'write').mockRejectedValue(new Error('permission denied'))
    const store = createStore(adapter)

    const doThing = createMutate(store, {
      action: 'PermissionTest',
      write: () => ({ path: 'things', id: 'x', fields: { v: 1 } }),
    })

    await doThing({}).catch(() => {})

    const errors = getErrors(store)
    expect(errors[0]?.kind).toBe('permission')
  })

  it('error doc records the payload that was passed to the mutate', async () => {
    const { store } = makeFailingStore()

    const doThing = createMutate(store, {
      action: 'RecordPayload',
      write: ({ id, title }) => ({
        path: 'things',
        id: String(id),
        fields: { title },
        merge: false,
      }),
    })

    await doThing({ id: 'thing-1', title: 'Test payload' }).catch(() => {})

    const errors = getErrors(store)
    expect(errors[0]?.payload?.['id']).toBe('thing-1')
    expect(errors[0]?.payload?.['title']).toBe('Test payload')
  })

  it('successful write does not add to errors collection', async () => {
    const store = createStore(MemoryAdapter())
    const doThing = createMutate(store, {
      action: 'GoodWrite',
      write: () => ({ path: 'things', id: 'x', fields: { v: 1 } }),
    })

    await doThing({})

    const errors = getErrors(store)
    expect(errors).toHaveLength(0)
  })

  it('cache is rolled back when remote write fails', async () => {
    const { store } = makeFailingStore()

    seed(store, { tasks: [{ id: 'task-2', status: 'active' }] })

    const archiveTask = createMutate(store, {
      action: 'ArchiveTask',
      write: ({ id }) => ({
        path: 'tasks',
        id: String(id),
        fields: { status: 'archived' },
        merge: true,
      }),
    })

    await archiveTask({ id: 'task-2' }).catch(() => {})

    const col = getCollection(store.getCache(), 'tasks')
    const task = filterDocs(col, { id: 'task-2' })[0]
    expect(task?.status).toBe('active')
  })

  it('multiple failures accumulate independent ErrorDocs', async () => {
    const adapter = MemoryAdapter()
    vi.spyOn(adapter, 'write').mockRejectedValue(new Error('Network unavailable'))
    const store = createStore(adapter)

    const doThing = createMutate(store, {
      action: 'AccumulateErrors',
      write: ({ id }) => ({ path: 'x', id: String(id), fields: { v: 1 } }),
    })

    await doThing({ id: 'a' }).catch(() => {})
    await doThing({ id: 'b' }).catch(() => {})

    const errors = getErrors(store)
    expect(errors).toHaveLength(2)
    expect(errors.every(e => e.action === 'AccumulateErrors')).toBe(true)
  })
})
