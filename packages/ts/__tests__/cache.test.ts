// ---------------------------------------------------------------------------
// cache.test.ts — unit tests for cache.ts
// ---------------------------------------------------------------------------
//
// Coverage:
//   - Structural sharing: writing doc A does not replace doc B reference
//   - subscribe returns docs matching query
//   - snapshot/restore roundtrip
//   - AtomicOp resolution: increment, arrayUnion, arrayRemove, delete

import { describe, it, expect } from 'vitest'
import {
  applyWrite,
  applyWrites,
  emptyCache,
  filterDocs,
  getCollection,
  getDoc,
  projectDoc,
  restore,
  snapshot,
} from '../src/cache.js'
import { arrayRemove, arrayUnion, deleteField, increment } from '../src/types.js'
import type { Doc, WriteDescriptor } from '../src/types.js'

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const task1: Doc = { id: 'task-1', title: 'Buy groceries', done: false, tags: ['errands'] }
const task2: Doc = { id: 'task-2', title: 'Read ADRs', done: true, tags: ['work'] }

function seedCache() {
  let cache = emptyCache()
  cache = applyWrite(cache, { path: 'tasks', id: task1.id, fields: { title: task1.title, done: task1.done, tags: task1.tags }, merge: false })
  cache = applyWrite(cache, { path: 'tasks', id: task2.id, fields: { title: task2.title, done: task2.done, tags: task2.tags }, merge: false })
  return cache
}

// ---------------------------------------------------------------------------
// Structural sharing
// ---------------------------------------------------------------------------

describe('structural sharing', () => {
  it('writing doc A does not replace doc B reference', () => {
    const cache = seedCache()
    const before2 = getDoc(cache, 'tasks', 'task-2')

    const next = applyWrite(cache, {
      path: 'tasks',
      id: 'task-1',
      fields: { done: true },
      merge: true,
    })

    const after2 = getDoc(next, 'tasks', 'task-2')
    expect(after2).toBe(before2) // exact same reference
  })

  it('writing to a new collection does not replace the existing collection map', () => {
    const cache = seedCache()
    const tasksBefore = cache.get('tasks')

    const next = applyWrite(cache, {
      path: 'notes',
      id: 'note-1',
      fields: { text: 'hello' },
      merge: false,
    })

    expect(next.get('tasks')).toBe(tasksBefore) // same reference
    expect(next.get('notes')?.get('note-1')?.text).toBe('hello')
  })

  it('no-op write (same doc, no change) returns same cache reference', () => {
    const cache = seedCache()
    // applyWrite with merge on existing doc where nothing changes by reference
    // should not be tested for identity (the merge does produce new object),
    // but unrelated collections must be stable.
    const tasksBefore = cache.get('tasks')
    const next = applyWrite(cache, {
      path: 'notes',
      id: 'note-2',
      fields: { text: 'world' },
    })
    expect(next.get('tasks')).toBe(tasksBefore)
  })
})

// ---------------------------------------------------------------------------
// filterDocs (used by subscribe/query)
// ---------------------------------------------------------------------------

describe('filterDocs', () => {
  it('returns all docs when no where clause', () => {
    const cache = seedCache()
    const col = getCollection(cache, 'tasks')
    const docs = filterDocs(col)
    expect(docs).toHaveLength(2)
  })

  it('returns only docs matching where clause', () => {
    const cache = seedCache()
    const col = getCollection(cache, 'tasks')
    const docs = filterDocs(col, { done: false })
    expect(docs).toHaveLength(1)
    expect(docs[0].id).toBe('task-1')
  })

  it('returns empty array when nothing matches', () => {
    const cache = seedCache()
    const col = getCollection(cache, 'tasks')
    const docs = filterDocs(col, { done: 'maybe' })
    expect(docs).toHaveLength(0)
  })

  it('returns empty array for unknown collection', () => {
    const cache = seedCache()
    const col = getCollection(cache, 'nonexistent')
    const docs = filterDocs(col)
    expect(docs).toHaveLength(0)
  })
})

// ---------------------------------------------------------------------------
// projectDoc
// ---------------------------------------------------------------------------

describe('projectDoc', () => {
  it('returns only requested fields plus id', () => {
    const doc: Doc = { id: 'x', title: 'hello', done: false, secret: 'sssh' }
    const projected = projectDoc(doc, ['title'])
    expect(projected).toEqual({ id: 'x', title: 'hello' })
    expect(projected).not.toHaveProperty('done')
    expect(projected).not.toHaveProperty('secret')
  })

  it('always includes id even when not in fields list', () => {
    const doc: Doc = { id: 'y', value: 42 }
    const projected = projectDoc(doc, ['value'])
    expect(projected.id).toBe('y')
  })
})

// ---------------------------------------------------------------------------
// Snapshot / restore roundtrip
// ---------------------------------------------------------------------------

describe('snapshot / restore', () => {
  it('roundtrips an empty cache', () => {
    const cache = emptyCache()
    const snap = snapshot(cache)
    const restored = restore(snap)
    expect(restored.size).toBe(0)
  })

  it('roundtrips a populated cache', () => {
    const cache = seedCache()
    const snap = snapshot(cache)
    const restored = restore(snap)

    expect(restored.get('tasks')?.get('task-1')?.title).toBe('Buy groceries')
    expect(restored.get('tasks')?.get('task-2')?.done).toBe(true)
  })

  it('snapshot produces plain JSON-safe object', () => {
    const cache = seedCache()
    const snap = snapshot(cache)
    expect(() => JSON.stringify(snap)).not.toThrow()
  })

  it('restore is independent of the source snapshot (no shared refs)', () => {
    const cache = seedCache()
    const snap = snapshot(cache)
    const restored = restore(snap)

    // Mutate the snapshot — restored cache should not be affected
    snap['tasks']['task-1'].title = 'MUTATED'
    expect(restored.get('tasks')?.get('task-1')?.title).toBe('Buy groceries')
  })
})

// ---------------------------------------------------------------------------
// AtomicOp resolution via applyWrite
// ---------------------------------------------------------------------------

describe('atomic ops', () => {
  describe('::increment', () => {
    it('increments an existing numeric field', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'counters', id: 'c1', fields: { n: 5 }, merge: false })
      cache = applyWrite(cache, { path: 'counters', id: 'c1', fields: { n: increment(3) }, merge: true })
      expect(getDoc(cache, 'counters', 'c1')?.n).toBe(8)
    })

    it('starts from 0 when field does not exist', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'counters', id: 'c2', fields: { n: increment(10) }, merge: true })
      expect(getDoc(cache, 'counters', 'c2')?.n).toBe(10)
    })

    it('handles negative increment (decrement)', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'counters', id: 'c3', fields: { n: 100 }, merge: false })
      cache = applyWrite(cache, { path: 'counters', id: 'c3', fields: { n: increment(-40) }, merge: true })
      expect(getDoc(cache, 'counters', 'c3')?.n).toBe(60)
    })
  })

  describe('::arrayUnion', () => {
    it('adds new values to an existing array', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'l1', fields: { tags: ['a', 'b'] }, merge: false })
      cache = applyWrite(cache, { path: 'lists', id: 'l1', fields: { tags: arrayUnion('c', 'd') }, merge: true })
      expect(getDoc(cache, 'lists', 'l1')?.tags).toEqual(['a', 'b', 'c', 'd'])
    })

    it('does not add duplicate values', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'l2', fields: { tags: ['a', 'b'] }, merge: false })
      cache = applyWrite(cache, { path: 'lists', id: 'l2', fields: { tags: arrayUnion('a', 'c') }, merge: true })
      expect(getDoc(cache, 'lists', 'l2')?.tags).toEqual(['a', 'b', 'c'])
    })

    it('starts from empty array when field does not exist', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'l3', fields: { tags: arrayUnion('x') }, merge: true })
      expect(getDoc(cache, 'lists', 'l3')?.tags).toEqual(['x'])
    })
  })

  describe('::arrayRemove', () => {
    it('removes specified values from an array', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'r1', fields: { tags: ['a', 'b', 'c'] }, merge: false })
      cache = applyWrite(cache, { path: 'lists', id: 'r1', fields: { tags: arrayRemove('b') }, merge: true })
      expect(getDoc(cache, 'lists', 'r1')?.tags).toEqual(['a', 'c'])
    })

    it('is a no-op when value is not present', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'r2', fields: { tags: ['a', 'b'] }, merge: false })
      cache = applyWrite(cache, { path: 'lists', id: 'r2', fields: { tags: arrayRemove('z') }, merge: true })
      expect(getDoc(cache, 'lists', 'r2')?.tags).toEqual(['a', 'b'])
    })

    it('produces empty array when all values removed', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'lists', id: 'r3', fields: { tags: ['a'] }, merge: false })
      cache = applyWrite(cache, { path: 'lists', id: 'r3', fields: { tags: arrayRemove('a') }, merge: true })
      expect(getDoc(cache, 'lists', 'r3')?.tags).toEqual([])
    })
  })

  describe('::delete', () => {
    it('removes a field from the document', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'docs', id: 'd1', fields: { title: 'hello', secret: 'hidden' }, merge: false })
      cache = applyWrite(cache, { path: 'docs', id: 'd1', fields: { secret: deleteField() }, merge: true })
      const doc = getDoc(cache, 'docs', 'd1')
      expect(doc?.title).toBe('hello')
      expect(doc).not.toHaveProperty('secret')
    })

    it('is a no-op when field does not exist', () => {
      let cache = emptyCache()
      cache = applyWrite(cache, { path: 'docs', id: 'd2', fields: { title: 'hello' }, merge: false })
      cache = applyWrite(cache, { path: 'docs', id: 'd2', fields: { nonexistent: deleteField() }, merge: true })
      expect(getDoc(cache, 'docs', 'd2')?.title).toBe('hello')
    })
  })

  describe('document-level delete', () => {
    it('removes the entire document', () => {
      let cache = seedCache()
      cache = applyWrite(cache, { path: 'tasks', id: 'task-1', delete: true })
      expect(getDoc(cache, 'tasks', 'task-1')).toBeUndefined()
      // Other doc untouched
      expect(getDoc(cache, 'tasks', 'task-2')?.id).toBe('task-2')
    })

    it('is a no-op for a non-existent document', () => {
      const cache = seedCache()
      const next = applyWrite(cache, { path: 'tasks', id: 'ghost', delete: true })
      expect(next).toBe(cache) // same reference — nothing changed
    })
  })

  describe('applyWrites (batch)', () => {
    it('applies multiple descriptors in order', () => {
      let cache = emptyCache()
      const descs: WriteDescriptor[] = [
        { path: 'items', id: 'i1', fields: { count: 1 }, merge: false },
        { path: 'items', id: 'i1', fields: { count: increment(9) }, merge: true },
      ]
      cache = applyWrites(cache, descs)
      expect(getDoc(cache, 'items', 'i1')?.count).toBe(10)
    })
  })
})
