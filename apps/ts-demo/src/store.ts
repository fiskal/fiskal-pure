// ---------------------------------------------------------------------------
// Demo store — task management with MemoryAdapter
// ---------------------------------------------------------------------------
//
// TaskModel schema:  { id, title, status, createdAt }
// status values:     'active' | 'archived'
//
// This file is the only place the store is wired. Components import nothing
// from @fiskal/pure-ts — they receive data and callbacks as plain props.

import { createStore, createMutate, MemoryAdapter } from '@fiskal/pure-ts'
import { MemoryAdapter as MA } from '@fiskal/pure-ts/adapters/memory'

// ---------------------------------------------------------------------------
// Shared store instance — MemoryAdapter keeps everything in-process.
// ---------------------------------------------------------------------------

export const store = createStore(MA())

// ---------------------------------------------------------------------------
// Model schema (used as documentation; MemoryAdapter accepts any Doc shape)
// ---------------------------------------------------------------------------

export interface TaskDoc {
  id: string
  title: string
  status: 'active' | 'archived'
  createdAt: string
}

// ---------------------------------------------------------------------------
// Mutates
// ---------------------------------------------------------------------------

/** Create a new active task. */
export const addTask = createMutate<{ id: string; title: string }>(store, {
  write: ({ id, title }) => ({
    collection: 'tasks',
    id,
    fields: {
      title,
      status: 'active',
      createdAt: new Date().toISOString(),
    },
    merge: false,
  }),
})

/** Mark a task as archived. */
export const archiveTask = createMutate<{ id: string }>(store, {
  write: ({ id }) => ({
    collection: 'tasks',
    id,
    fields: { status: 'archived' },
    merge: true,
  }),
})
