// ---------------------------------------------------------------------------
// model.test.ts — unit tests for Model enrichment
// ---------------------------------------------------------------------------

import { describe, it, expect } from 'vitest'
import { createStore } from '../src/store.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed } from '../src/test/index.js'
import type { Model } from '../src/types.js'

// ---------------------------------------------------------------------------
// Fixtures — closure-based compute (no 'this', safe to destructure)
// ---------------------------------------------------------------------------

const TaskModel: Model = {
  compute: {
    // Simple: receives doc, returns a plain value
    titleUpper: (doc) => String(doc['title'] ?? '').toUpperCase(),

    // Dependent: receives doc, returns a function that takes a sibling
    isOwnedBy: (doc) => (userId: string) => doc['ownerId'] === userId,
  },
}

// ---------------------------------------------------------------------------
// Simple compute enrichment
// ---------------------------------------------------------------------------

describe('model simple compute', () => {
  it('applies closure to doc delivered via store.enrich', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    seed(store, { tasks: [{ id: 'tasks/t1', title: 'hello', ownerId: 'u1' }] })

    const raw = store.getCache().get('tasks')?.get('tasks/t1') ?? { id: 'x' }
    const enriched = store.enrich('tasks', raw)

    expect((enriched as Record<string, unknown>)['titleUpper']).toBe('HELLO')
  })

  it('compute result is a plain value — safe to destructure', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t2', title: 'world', ownerId: 'u2' }
    const enriched = store.enrich('tasks', doc) as Record<string, unknown>

    const { titleUpper } = enriched   // ← destructuring works; no 'this' binding
    expect(titleUpper).toBe('WORLD')
  })

  it('enrich is identity when no model registered for collection', () => {
    const store = createStore(MemoryAdapter())
    const doc = { id: 'other/x', title: 'noop' }
    const result = store.enrich('other', doc)
    expect(result).toBe(doc)
  })

  it('enrich is identity when model has no compute', () => {
    const store = createStore(MemoryAdapter(), {
      models: { tasks: { schema: { type: 'object' } } },
    })
    const doc = { id: 'tasks/t3', title: 'plain' }
    const result = store.enrich('tasks', doc)
    expect(result).toBe(doc)
  })
})

// ---------------------------------------------------------------------------
// Dependent compute — closure captures the doc, returns a function
// ---------------------------------------------------------------------------

describe('model dependent compute', () => {
  it('dependent compute returns a callable function on the enriched doc', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t4', title: 'test', ownerId: 'user-42' }
    const enriched = store.enrich('tasks', doc) as Record<string, unknown>

    const isOwnedBy = enriched['isOwnedBy'] as (id: string) => boolean
    expect(isOwnedBy('user-42')).toBe(true)
    expect(isOwnedBy('user-99')).toBe(false)
  })

  it('dependent compute is safe to destructure — closure holds the doc', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t5', title: 'owned', ownerId: 'alice' }
    const enriched = store.enrich('tasks', doc) as Record<string, unknown>

    // Destructure and call without 'this' — works because it is a closure
    const { isOwnedBy } = enriched as { isOwnedBy: (id: string) => boolean }
    expect(isOwnedBy('alice')).toBe(true)
    expect(isOwnedBy('bob')).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Per-collection model registry
// ---------------------------------------------------------------------------

describe('per-collection model registry', () => {
  it('applies correct model for each collection', () => {
    const SprintModel: Model = {
      compute: {
        shortName: (doc) => String(doc['name'] ?? '').slice(0, 3).toUpperCase(),
      },
    }

    const store = createStore(MemoryAdapter(), {
      models: {
        tasks:   TaskModel,
        sprints: SprintModel,
      },
    })

    const task   = store.enrich('tasks',   { id: 'tasks/t1',   title: 'buy', ownerId: 'u1' })
    const sprint = store.enrich('sprints', { id: 'sprints/s1', name: 'alpha' })

    expect((task   as Record<string, unknown>)['titleUpper']).toBe('BUY')
    expect((sprint as Record<string, unknown>)['shortName']).toBe('ALP')
  })
})
