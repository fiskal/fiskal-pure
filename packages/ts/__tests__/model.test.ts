// ---------------------------------------------------------------------------
// model.test.ts — unit tests for Model enrichment (ADR-0007)
// ---------------------------------------------------------------------------

import { describe, it, expect } from 'vitest'
import { createStore } from '../src/store.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed } from '../src/test/index.js'
import { applyWrite, emptyCache } from '../src/cache.js'
import type { Model } from '../src/types.js'

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TaskModel: Model = {
  compute: {
    get titleUpper() {
      return String((this as Record<string, unknown>)['title'] ?? '').toUpperCase()
    },
    isOwnedBy(userId: string) {
      return (this as Record<string, unknown>)['ownerId'] === userId
    },
  },
}

// ---------------------------------------------------------------------------
// Getter enrichment
// ---------------------------------------------------------------------------

describe('model getter enrichment', () => {
  it('applies getter to doc delivered via store.enrich', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    seed(store, { tasks: [{ id: 'tasks/t1', title: 'hello', ownerId: 'u1' }] })

    const raw = store.getCache().get('tasks')?.get('tasks/t1') ?? { id: 'x' }
    const enriched = store.enrich('tasks', raw)

    expect((enriched as Record<string, unknown>)['titleUpper']).toBe('HELLO')
  })

  it('getter reads live field values from the enriched doc', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t2', title: 'world', ownerId: 'u2' }
    const enriched = store.enrich('tasks', doc)

    expect((enriched as Record<string, unknown>)['titleUpper']).toBe('WORLD')
  })

  it('enrich is identity when no model registered for collection', () => {
    const store = createStore(MemoryAdapter())
    const doc = { id: 'other/x', title: 'noop' }
    const result = store.enrich('other', doc)
    expect(result).toBe(doc)  // exact same reference
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
// Computer method enrichment
// ---------------------------------------------------------------------------

describe('model computer methods', () => {
  it('computer method is callable on enriched doc', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t4', title: 'test', ownerId: 'user-42' }
    const enriched = store.enrich('tasks', doc)
    const isOwnedBy = (enriched as Record<string, unknown>)['isOwnedBy'] as (id: string) => boolean

    expect(isOwnedBy.call(enriched, 'user-42')).toBe(true)
    expect(isOwnedBy.call(enriched, 'user-99')).toBe(false)
  })

  it('computer preserves this when called as method', () => {
    const store = createStore(MemoryAdapter(), { models: { tasks: TaskModel } })
    const doc = { id: 'tasks/t5', title: 'owned', ownerId: 'alice' }
    const enriched = store.enrich('tasks', doc) as unknown as {
      ownerId: string
      isOwnedBy(id: string): boolean
    }

    expect(enriched.isOwnedBy('alice')).toBe(true)
    expect(enriched.isOwnedBy('bob')).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// Multiple collections
// ---------------------------------------------------------------------------

describe('per-collection model registry', () => {
  it('applies correct model for each collection', () => {
    const SprintModel: Model = {
      compute: {
        get shortName() {
          const name = String((this as Record<string, unknown>)['name'] ?? '')
          return name.slice(0, 3).toUpperCase()
        },
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
