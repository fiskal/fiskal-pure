import { createStore, createMutate, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'
import type { Model } from '@fiskal/antifragile'

// ---------------------------------------------------------------------------
// Model — JSON schema + compute formatters
// ---------------------------------------------------------------------------

type TaskDoc = { createdAt: number; status: string }

const taskCompute: Model['compute'] = {
  // TypeScript does not allow `this` parameters on accessor getters.
  // Use function form and cast — the library applies these via Object.defineProperties,
  // so `this` is the doc at call time.
  get createdAtDisplay() {
    const self = this as unknown as TaskDoc
    return new Date(self.createdAt).toLocaleDateString(undefined, {
      month: 'short', day: 'numeric', year: 'numeric',
    })
  },
  get statusLabel() {
    const self = this as unknown as TaskDoc
    return self.status === 'active' ? 'In Progress' : 'Archived'
  },
}

export const TaskModel: Model = {
  schema: {
    type: 'object',
    properties: {
      id:        { type: 'string' },
      title:     { type: 'string', minLength: 1 },
      status:    { type: 'string', enum: ['active', 'archived'] },
      createdAt: { type: 'number' },
    },
    required: ['id', 'title', 'status', 'createdAt'],
  },
  compute: taskCompute,
}

// ---------------------------------------------------------------------------
// Store — seed data, model, mutates all in one place
// ---------------------------------------------------------------------------

export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'task-1', title: 'Deploy to production', status: 'active', createdAt: Date.now() - 86_400_000 },
      { id: 'task-2', title: 'Write release notes',  status: 'active', createdAt: Date.now() - 3_600_000  },
      { id: 'task-3', title: 'Update dependencies',  status: 'active', createdAt: Date.now()              },
    ],
  }),
  { models: { tasks: TaskModel } },
)

export const addTask = createMutate<{ id: string; title: string }>(store, {
  write: ({ id, title }: { id: string; title: string }) => ({
    collection: 'tasks',
    id,
    fields: { title, status: 'active', createdAt: Date.now() },
    merge: false as const,
  }),
})

export const archiveTask = createMutate<{ id: string }>(store, {
  write: ({ id }: { id: string }) => ({
    collection: 'tasks',
    id,
    fields: { status: 'archived' },
    merge: true as const,
  }),
})

// wireView bound to this store and its mutates — the only connection point
type AnyMutate = (payload?: Record<string, unknown>) => Promise<unknown>
export const wireView = createWireView(store, {
  addTask:     addTask as unknown as AnyMutate,
  archiveTask: archiveTask as unknown as AnyMutate,
})
