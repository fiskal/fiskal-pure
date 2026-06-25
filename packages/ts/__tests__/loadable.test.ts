// ---------------------------------------------------------------------------
// loadable.test.ts — the Loadable three-state contract (ADR-0013)
// ---------------------------------------------------------------------------
// Asserts the wire encoding (undefined|null|Doc|Doc[]) maps to the explicit
// tagged Loadable form identically for single-doc and collection queries.

import { describe, it, expect } from 'vitest'
import { toLoadable } from '../src/useRead.js'
import type { Doc, Query } from '../src/types.js'

const single: Query = { path: 'tasks', id: 'tasks/task-1' }
const collection: Query = { path: 'tasks' }
const doc: Doc = { id: 'tasks/task-1', title: 'Deploy' }

describe('toLoadable — single-doc query (3 states)', () => {
  it('undefined → loading', () => {
    expect(toLoadable(single, undefined)).toEqual({ status: 'loading' })
  })
  it('null → missing', () => {
    expect(toLoadable(single, null)).toEqual({ status: 'missing' })
  })
  it('Doc → loaded', () => {
    expect(toLoadable(single, doc)).toEqual({ status: 'loaded', data: doc })
  })
})

describe('toLoadable — collection query (2 states, no missing)', () => {
  it('undefined → loading', () => {
    expect(toLoadable(collection, undefined)).toEqual({ status: 'loading' })
  })
  it('empty array → loaded([]) (loaded-but-empty, never missing/loading)', () => {
    expect(toLoadable(collection, [])).toEqual({ status: 'loaded', data: [] })
  })
  it('populated array → loaded', () => {
    expect(toLoadable(collection, [doc])).toEqual({ status: 'loaded', data: [doc] })
  })
})
