// ---------------------------------------------------------------------------
// loadable.test.ts — the Loadable three-state contract (ADR-0013)
// ---------------------------------------------------------------------------
// Asserts the wire encoding (undefined|null|Doc|Doc[]) maps to the explicit
// tagged Loadable form identically for single-doc and collection queries.

import { describe, it, expect } from 'vitest'
import { shapeLoadable } from '../src/useRead.js'
import type { Doc, Query } from '../src/types.js'

// shapeLoadable takes the internal loading sentinel (`undefined` = not yet in
// cache) and a flat data list, and produces the explicit Loadable. No null or
// undefined ever leaves the read path — the result is always a tagged Loadable.
const single: Query = { path: 'tasks', id: 'tasks/task-1' }
const collection: Query = { path: 'tasks' }
const doc: Doc = { id: 'tasks/task-1', title: 'Deploy' }

describe('shapeLoadable — single-item query (3 states)', () => {
  it('loading sentinel → loading', () => {
    expect(shapeLoadable(single, undefined)).toEqual({ status: 'loading' })
  })
  it('empty result → missing', () => {
    expect(shapeLoadable(single, [])).toEqual({ status: 'missing' })
  })
  it('one item → loaded', () => {
    expect(shapeLoadable(single, [doc])).toEqual({ status: 'loaded', data: doc })
  })
})

describe('shapeLoadable — collection query (2 states, no missing)', () => {
  it('loading sentinel → loading', () => {
    expect(shapeLoadable(collection, undefined)).toEqual({ status: 'loading' })
  })
  it('empty list → loaded([]) (loaded-but-empty, never missing/loading)', () => {
    expect(shapeLoadable(collection, [])).toEqual({ status: 'loaded', data: [] })
  })
  it('populated list → loaded', () => {
    expect(shapeLoadable(collection, [doc])).toEqual({ status: 'loaded', data: [doc] })
  })
})
