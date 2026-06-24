// @vitest-environment jsdom
// ---------------------------------------------------------------------------
// query.test.ts — unit tests for useRead
// ---------------------------------------------------------------------------
//
// Coverage:
//   - returns undefined while loading (async adapter, no cache hit)
//   - returns null when doc not found (single-doc query with id)
//   - returns doc when found
//   - collection query returns array
//   - where filter returns only matching docs
//   - fields projection returns only requested fields
//   - re-render only on changed data (structural equality / reference stability)
//
// React hooks are tested using @testing-library/react renderHook.
// MemoryAdapter delivers results synchronously so most tests avoid
// async complexity.

import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useRead } from '../src/useRead.js'
import { createStore } from '../src/store.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed } from '../src/test/index.js'
import type { Doc, StoreInstance } from '../src/types.js'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeStore(): StoreInstance {
  return createStore(MemoryAdapter())
}

function mkDoc(overrides: Partial<Doc> & { id: string }): Doc {
  return { title: '', category: 'default', ...overrides }
}

// ---------------------------------------------------------------------------
// Loading state
// ---------------------------------------------------------------------------

describe('loading state', () => {
  it('returns undefined initially when adapter is async', () => {
    // Create an adapter that never delivers synchronously
    const asyncAdapter = {
      subscribe: vi.fn(() => () => {}),
      write: vi.fn(async () => {}),
    }
    const store = createStore(asyncAdapter)

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks' }),
    )
    // MemoryAdapter fires synchronously; async adapter does not
    expect(result.current).toBeUndefined()
  })
})

// ---------------------------------------------------------------------------
// Single-doc queries
// ---------------------------------------------------------------------------

describe('single-doc query (with id)', () => {
  it('returns null when document is not found', () => {
    const store = makeStore()
    // No docs seeded

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', id: 'does-not-exist' }),
    )
    expect(result.current).toBeNull()
  })

  it('returns the doc when found', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'found', title: 'Found it' })] })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', id: 'found' }),
    )
    const doc = result.current as Doc
    expect(doc?.id).toBe('found')
    expect(doc?.title).toBe('Found it')
  })

  it('updates when the doc changes', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'live', done: false })] })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', id: 'live' }),
    )

    expect((result.current as Doc)?.done).toBe(false)

    await act(async () => {
      await store.adapter.write({
        collection: 'tasks',
        id: 'live',
        fields: { done: true },
        merge: true,
      })
    })

    expect((result.current as Doc)?.done).toBe(true)
  })

  it('returns null after document is deleted', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'del-me' })] })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', id: 'del-me' }),
    )

    expect(result.current).not.toBeNull()

    await act(async () => {
      await store.adapter.write({ collection: 'tasks', id: 'del-me', delete: true })
    })

    expect(result.current).toBeNull()
  })
})

// ---------------------------------------------------------------------------
// Collection queries
// ---------------------------------------------------------------------------

describe('collection query', () => {
  it('returns an array of docs', () => {
    const store = makeStore()
    seed(store, {
      tasks: [
        mkDoc({ id: 'c1', title: 'Alpha' }),
        mkDoc({ id: 'c2', title: 'Beta' }),
      ],
    })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks' }),
    )
    const docs = result.current as Doc[]
    expect(Array.isArray(docs)).toBe(true)
    expect(docs).toHaveLength(2)
  })

  it('returns empty array when collection is empty', () => {
    const store = makeStore()

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks' }),
    )
    expect(result.current).toEqual([])
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

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', where: { done: false } }),
    )
    const docs = result.current as Doc[]
    expect(docs).toHaveLength(2)
    expect(docs.every(d => d.done === false)).toBe(true)
  })

  it('returns empty array when no docs match', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'w4', done: true })] })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', where: { done: false } }),
    )
    expect(result.current).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Fields projection
// ---------------------------------------------------------------------------

describe('fields projection', () => {
  it('returns only requested fields plus id', () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'p1', title: 'Secret project', category: 'work' })],
    })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', fields: ['title'] }),
    )
    const docs = result.current as Doc[]
    expect(docs[0]).toEqual({ id: 'p1', title: 'Secret project' })
    expect(docs[0]).not.toHaveProperty('category')
  })

  it('single-doc projection returns only requested fields', () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'p2', title: 'Hello', category: 'personal' })] })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks', id: 'p2', fields: ['category'] }),
    )
    const doc = result.current as Doc
    expect(doc).toEqual({ id: 'p2', category: 'personal' })
    expect(doc).not.toHaveProperty('title')
  })
})

// ---------------------------------------------------------------------------
// Structural equality — no re-render when data unchanged
// ---------------------------------------------------------------------------

describe('structural equality (no unnecessary re-renders)', () => {
  it('preserves array reference when docs do not change', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [mkDoc({ id: 'eq1', done: false }), mkDoc({ id: 'eq2', done: false })],
    })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks' }),
    )

    const firstRef = result.current

    // Write an unrelated doc — should not trigger re-render for tasks
    await act(async () => {
      await store.adapter.write({
        collection: 'notes',
        id: 'n1',
        fields: { text: 'hello' },
      })
    })

    // tasks array reference should be stable
    expect(result.current).toBe(firstRef)
  })

  it('individual doc reference is stable when doc unchanged', async () => {
    const store = makeStore()
    seed(store, {
      tasks: [
        mkDoc({ id: 'eq3', done: false }),
        mkDoc({ id: 'eq4', done: false }),
      ],
    })

    const { result } = renderHook(() =>
      useRead(store, { collection: 'tasks' }),
    )

    const docsBefore = result.current as Doc[]
    const doc4Before = docsBefore.find(d => d.id === 'eq4')

    // Update eq3 only
    await act(async () => {
      await store.adapter.write({
        collection: 'tasks',
        id: 'eq3',
        fields: { done: true },
        merge: true,
      })
    })

    const docsAfter = result.current as Doc[]
    const doc4After = docsAfter.find(d => d.id === 'eq4')

    // eq4 reference must be the same object (structural sharing)
    expect(doc4After).toBe(doc4Before)
  })

  it('does trigger re-render when doc data changes', async () => {
    const store = makeStore()
    seed(store, { tasks: [mkDoc({ id: 'eq5', done: false })] })

    const renderCount = { count: 0 }
    const { result } = renderHook(() => {
      renderCount.count++
      return useRead(store, { collection: 'tasks', id: 'eq5' })
    })

    const initialCount = renderCount.count
    expect((result.current as Doc)?.done).toBe(false)

    await act(async () => {
      await store.adapter.write({
        collection: 'tasks',
        id: 'eq5',
        fields: { done: true },
        merge: true,
      })
    })

    expect((result.current as Doc)?.done).toBe(true)
    expect(renderCount.count).toBeGreaterThan(initialCount)
  })
})
