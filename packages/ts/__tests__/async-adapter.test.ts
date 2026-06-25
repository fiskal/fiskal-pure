// ---------------------------------------------------------------------------
// async-adapter.test.ts — AsyncMemoryAdapter behaviour (ADR-0014)
// ---------------------------------------------------------------------------
// Proves the async fake makes the loading state, the revert-to-source-of-truth
// path, and subscription hygiene observable — none of which the synchronous
// MemoryAdapter can express.

import { describe, it, expect } from 'vitest'
import { createAsyncMemoryAdapter } from '../src/test/asyncMemoryAdapter.js'
import type { Doc } from '../src/types.js'

const seed = { tasks: [{ id: 'tasks/task-1', title: 'Deploy', status: 'active' }] }

describe('AsyncMemoryAdapter — loading state', () => {
  it('does NOT deliver synchronously on subscribe (loading is observable)', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    const deliveries: Doc[][] = []
    adapter.subscribe({ path: 'tasks' }, docs => deliveries.push(docs))

    // Nothing delivered yet — the consumer would still be in the loading state.
    expect(deliveries).toHaveLength(0)

    await adapter.flush()
    expect(deliveries).toHaveLength(1)
    expect(deliveries[0].map(d => d.id)).toEqual(['tasks/task-1'])
  })

  it('delivers a write update only after flush', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    const deliveries: Doc[][] = []
    adapter.subscribe({ path: 'tasks' }, docs => deliveries.push(docs))
    await adapter.flush() // initial

    void adapter.write({ path: 'tasks', id: 'tasks/task-2', fields: { title: 'Review' } })
    expect(deliveries).toHaveLength(1) // not yet seen
    await adapter.flush()
    expect(deliveries).toHaveLength(2)
    expect(deliveries[1].map(d => d.id)).toEqual(['tasks/task-1', 'tasks/task-2'])
  })
})

describe('AsyncMemoryAdapter — revert to source of truth', () => {
  it('a failed write rejects and leaves authoritative state unchanged', async () => {
    const adapter = createAsyncMemoryAdapter(seed)

    adapter.failNextWrite()
    await expect(
      adapter.write({ path: 'tasks', id: 'tasks/task-1', fields: { status: 'archived' } }),
    ).rejects.toThrow()

    // The adapter is the source of truth: the rejected write never landed, so a
    // store would revert its optimistic cache back to this authoritative value.
    const truth = adapter.authoritative({ path: 'tasks', id: 'tasks/task-1' })
    expect(truth[0].status).toBe('active')
  })

  it('the next write after a forced failure succeeds normally', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    adapter.failNextWrite()
    await adapter.write({ path: 'tasks', id: 'tasks/task-1', fields: { status: 'archived' } }).catch(() => {})

    await adapter.write({ path: 'tasks', id: 'tasks/task-1', fields: { status: 'archived' } })
    const truth = adapter.authoritative({ path: 'tasks', id: 'tasks/task-1' })
    expect(truth[0].status).toBe('archived')
  })
})

describe('AsyncMemoryAdapter — subscription hygiene', () => {
  it('subscriber count returns to zero after attach/detach cycles', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    expect(adapter.subscriberCount()).toBe(0)

    for (let i = 0; i < 10; i++) {
      const unsub = adapter.subscribe({ path: 'tasks' }, () => {})
      expect(adapter.subscriberCount('tasks')).toBe(1)
      unsub()
    }
    expect(adapter.subscriberCount()).toBe(0)
  })

  it('an unsubscribed subscriber receives no further deliveries', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    const deliveries: Doc[][] = []
    const unsub = adapter.subscribe({ path: 'tasks' }, docs => deliveries.push(docs))
    await adapter.flush()
    expect(deliveries).toHaveLength(1)

    unsub()
    void adapter.write({ path: 'tasks', id: 'tasks/task-2', fields: { title: 'Review' } })
    await adapter.flush()
    expect(deliveries).toHaveLength(1) // no delivery after unsubscribe
  })

  it('a write to an unrelated path does not wake a scoped subscriber', async () => {
    const adapter = createAsyncMemoryAdapter(seed)
    const deliveries: Doc[][] = []
    adapter.subscribe({ path: 'tasks' }, docs => deliveries.push(docs))
    await adapter.flush()
    expect(deliveries).toHaveLength(1)

    void adapter.write({ path: 'sprints', id: 'sprints/s1', fields: { name: 'Sprint 1' } })
    await adapter.flush()
    // The 'tasks' subscriber is NOT woken by a write to 'sprints' (path-gated).
    expect(deliveries).toHaveLength(1)
  })
})
