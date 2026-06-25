// @vitest-environment jsdom
// ---------------------------------------------------------------------------
// query.test.ts — unit tests for useRead (returns Loadable, ADR-0013)
// ---------------------------------------------------------------------------
//
// useRead returns an explicit Loadable — no null/undefined sentinels:
//   { status: 'loading' } | { status: 'missing' } | { status: 'loaded', data }
//
// React hooks are tested using @testing-library/react renderHook.
// MemoryAdapter delivers results synchronously so most tests avoid async.

import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useRead } from '../src/useRead.js'
import { createStore } from '../src/store.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed } from '../src/test/index.js'
import type { Doc, Loadable, StoreInstance } from '../src/types.js'

function makeStore(): StoreInstance {
  return createStore(MemoryAdapter())
}

function mkDoc(overrides: Partial<Doc> & { id: string }): Doc {
  return { title: '', category: 'default', ...overrides }
}

// Assert the Loadable is loaded and return its data.
function loaded<T>(r: Loadable<Doc | Doc[]>): T {
  expect(r.status).toBe('loaded')
  return (r as { status: 'loaded'; data: T }).data
}

// ---------------------------------------------------------------------------
// Loading state
// ---------------------------------------------------------------------------

describe('loading state', () => {
  it('returns { status: loading } initially when adapter is async', () => {
    const asyncAdapter = {
      subscribe: vi.fn(() => () => {}),
      write: vi.fn(async () => {}),
    }
    const store = createStore(asyncAdapter)

    const { result } = renderHook(() => useRead(store, { path: 'tasks' }))
    expect(result.current).toEqual({ status: 'loading' })
  })
})

// ---------------------------------------------------------------------------
// Single-doc queries
// ---------------------------------------------------------------------------

describe('single-doc query (with id)', () => {
  it('returns { status: missing } when document is not found', () => {
    const store = makeStore()
    const { result } = renderHook(() =>
      useRead(store, { path: 'tasks', id: 'does-not-exist' }),
    )
    expect(result.current).toEqual({ status: 'missing' })
  })

  it('returns { status: loaded, data } when found', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'found', title: 'Found it' })] })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', id: 'found' }))
    const doc = loaded<Doc>(result.current)
    expect(doc.id).toBe('found')
    expect(doc.title).toBe('Found it')
  })

  it('updates when the doc changes', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'live', done: false })] })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', id: 'live' }))
    expect(loaded<Doc>(result.current).done).toBe(false)

    await act(async () => {
      await store.adapter.write({ path: 'tasks', id: 'live', fields: { done: true }, merge: true })
    })

    expect(loaded<Doc>(result.current).done).toBe(true)
  })

  it('returns { status: missing } after document is deleted', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'del-me' })] })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', id: 'del-me' }))
    expect(result.current.status).toBe('loaded')

    await act(async () => {
      await store.adapter.write({ path: 'tasks', id: 'del-me', delete: true })
    })

    expect(result.current).toEqual({ status: 'missing' })
  })
})

// ---------------------------------------------------------------------------
// Collection queries
// ---------------------------------------------------------------------------

describe('collection query', () => {
  it('returns { status: loaded, data: Doc[] }', () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'c1', title: 'Alpha' }), mkDoc({ id: 'c2', title: 'Beta' })],
    })

    const { result } = renderHook(() => useRead(store, { path: 'tasks' }))
    const docs = loaded<Doc[]>(result.current)
    expect(Array.isArray(docs)).toBe(true)
    expect(docs).toHaveLength(2)
  })

  it('returns loaded([]) when collection is empty (loaded-but-empty, not loading)', () => {
    const store = makeStore()
    const { result } = renderHook(() => useRead(store, { path: 'tasks' }))
    expect(loaded<Doc[]>(result.current)).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Where filter
// ---------------------------------------------------------------------------

describe('where filter', () => {
  it('returns only matching docs', () => {
    const store = makeStore()
    seed(store, {
      tasks: [
        mkDoc({ id: 'w1', done: false }),
        mkDoc({ id: 'w2', done: true }),
        mkDoc({ id: 'w3', done: false }),
      ],
    })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', where: { done: false } }))
    const docs = loaded<Doc[]>(result.current)
    expect(docs).toHaveLength(2)
    expect(docs.every(d => d.done === false)).toBe(true)
  })

  it('returns loaded([]) when no docs match', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'w4', done: true })] })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', where: { done: false } }))
    expect(loaded<Doc[]>(result.current)).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Fields projection
// ---------------------------------------------------------------------------

describe('fields projection', () => {
  it('returns only requested fields plus id', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'p1', title: 'Secret project', category: 'work' })] })

    const { result } = renderHook(() => useRead(store, { path: 'tasks', fields: ['title'] }))
    const docs = loaded<Doc[]>(result.current)
    expect(docs[0]).toEqual({ id: 'p1', title: 'Secret project' })
    expect(docs[0]).not.toHaveProperty('category')
  })

  it('single-doc projection returns only requested fields', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'p2', title: 'Hello', category: 'personal' })] })

    const { result } = renderHook(() =>
      useRead(store, { path: 'tasks', id: 'p2', fields: ['category'] }),
    )
    const doc = loaded<Doc>(result.current)
    expect(doc).toEqual({ id: 'p2', category: 'personal' })
    expect(doc).not.toHaveProperty('title')
  })
})

// ---------------------------------------------------------------------------
// Structural equality — no re-render when data unchanged
// ---------------------------------------------------------------------------

describe('structural equality (no unnecessary re-renders)', () => {
  it('preserves the Loadable reference when docs do not change', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'eq1', done: false }), mkDoc({ id: 'eq2', done: false })],
    })

    const { result } = renderHook(() => useRead(store, { path: 'tasks' }))
    const firstRef = result.current

    await act(async () => {
      await store.adapter.write({ path: 'notes', id: 'n1', fields: { text: 'hello' } })
    })

    expect(result.current).toBe(firstRef)
  })

  it('individual doc reference is stable when doc unchanged', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'eq3', done: false }), mkDoc({ id: 'eq4', done: false })],
    })

    const { result } = renderHook(() => useRead(store, { path: 'tasks' }))
    const doc4Before = loaded<Doc[]>(result.current).find(d => d.id === 'eq4')

    await act(async () => {
      await store.adapter.write({ path: 'tasks', id: 'eq3', fields: { done: true }, merge: true })
    })

    const doc4After = loaded<Doc[]>(result.current).find(d => d.id === 'eq4')
    expect(doc4After).toBe(doc4Before)
  })

  it('does trigger re-render when doc data changes', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'eq5', done: false })] })

    const renderCount = { count: 0 }
    const { result } = renderHook(() => {
      renderCount.count++
      return useRead(store, { path: 'tasks', id: 'eq5' })
    })

    const initialCount = renderCount.count
    expect(loaded<Doc>(result.current).done).toBe(false)

    await act(async () => {
      await store.adapter.write({ path: 'tasks', id: 'eq5', fields: { done: true }, merge: true })
    })

    expect(loaded<Doc>(result.current).done).toBe(true)
    expect(renderCount.count).toBeGreaterThan(initialCount)
  })
})
