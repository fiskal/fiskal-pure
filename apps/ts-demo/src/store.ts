import { createStore, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'
import type { Model } from '@fiskal/antifragile'

// ---------------------------------------------------------------------------
// Model — JSON schema + closure-based compute
// ---------------------------------------------------------------------------

const taskCompute: Model['compute'] = {
  statusLabel:      (doc) => doc['status'] === 'active' ? 'In Progress' : 'Archived',
  createdAtDisplay: (doc) => new Date(doc['createdAt'] as number).toLocaleDateString(undefined, {
    month: 'short', day: 'numeric', year: 'numeric',
  }),
}

// ---------------------------------------------------------------------------
// Store — seed data, model, and mutates all inline
// ---------------------------------------------------------------------------

export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'task-1', title: 'Deploy to production', status: 'active', createdAt: Date.now() - 86_400_000 },
      { id: 'task-2', title: 'Write release notes',  status: 'active', createdAt: Date.now() - 3_600_000  },
      { id: 'task-3', title: 'Update dependencies',  status: 'active', createdAt: Date.now()              },
    ],
  }),
  {
    models: {
      tasks: {
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
      },
    },
    mutates: {
      addTask: {
        write: (payload) => {
          const { id, title } = payload as { id: string; title: string }
          return {
            path: 'tasks',
            id,
            fields: { title, status: 'active', createdAt: Date.now() },
          }
        },
      },
      archiveTask: {
        write: (payload) => {
          const { id } = payload as { id: string }
          return { path: 'tasks', id, fields: { status: 'archived' } }
        },
      },
    },
  },
)

export const wireView = createWireView(store)
