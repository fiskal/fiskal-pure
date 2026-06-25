# Antifragile — `@fiskal/antifragile`

State management for React and SwiftUI where data and views are separated by construction, not by convention.

---

## Contents

1. [The Problem](#1-the-problem)
2. [The Minimum](#2-the-minimum)
3. [Store Setup](#3-store-setup)
4. [Dependency Injection](#4-dependency-injection)
5. [Compute Properties](#5-compute-properties)
6. [Adapters](#6-adapters)
7. [History & Antifragility](#7-history--antifragility)
8. [Mutations](#8-mutations)
9. [wireView](#9-wireview)
10. [Queries](#10-queries)
11. [Advanced UI](#11-advanced-ui)
12. [Testing](#12-testing)
13. [SwiftUI](#13-swiftui)
14. [Migration](#14-migration)

---

## 1. The Problem

Every `useState`, `useEffect`, and `useContext` is logic inside a view. Logic in a view fails silently — no trace, no log, nothing to replay.

Antifragile removes hooks from views. Views are pure functions of their props. Every write is a named, serialisable record in the log. When something breaks, the full trace is already there — every mutation in order, all the data needed to fix it. Each failure is a one-look fix. The app gets stronger with every break.

---

## 2. The Minimum

A pure view. Zero library imports. Zero hooks.

```tsx
// TaskItem.tsx — no imports, no hooks
const TaskItemView = ({ task, setStatus }) => (
  <li>
    <span>{task.title}</span>
    <span>{task.status}</span>
    <button onClick={() => setStatus({ id: task.id, status: 'archived' })}>
      Archive
    </button>
  </li>
)
```

Wire it in the same file. The wire is a plain data declaration — not a hook, not a class:

```tsx
import { wireView } from './store'

const TaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['setStatus'],
  TaskItemView,
)
```

Test with plain props — no Provider, no store, no setup:

```tsx
render(
  <TaskItemView
    task={{ id: 'tasks/task-1', title: 'Deploy', status: 'active' }}
    setStatus={vi.fn()}
  />
)
```

`wireView` is the only import. The pure view has none.

---

## 3. Store Setup

One file. Seed data, schema, mutate, and `wireView` factory — all inline.

```ts
// store.ts
import { createStore, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'tasks/task-1', title: 'Deploy', status: 'active' },
    ],
  }),
  {
    models: {
      tasks: {
        schema: {
          type: 'object',
          properties: {
            id:     { type: 'string' },
            title:  { type: 'string' },
            status: { type: 'string', enum: ['active', 'archived'] },
          },
          required: ['id', 'title', 'status'],
        },
      },
    },
    mutates: {
      setStatus: {
        write: ({ id, status }) => ({
          path:   'tasks',
          id,
          fields: { status },
          // merge is the default — only status changes; all other fields survive
        }),
      },
    },
  },
)

export const wireView = createWireView(store)
```

**Document IDs use the full path** — `'tasks/task-1'`, not `'task-1'`. The prefix is the collection name. A query `{ id: 'tasks/task-1' }` resolves without a separate `path` field.

---

## 4. Dependency Injection

`wireView` registers each component by name. When another wired component has a prop matching that name, the registered component is injected automatically — no import, no export.

```tsx
// TaskList.tsx
import { wireView } from './store'

const TaskListView = ({ taskIds, TaskItem: Item }) => (
  <ul>
    {taskIds.map(({ id }) => (
      <Item key={id} taskId={id} />
    ))}
  </ul>
)

// TaskItem is injected automatically — the prop name matches the registered name
const TaskList = wireView(
  'TaskList',
  {
    taskIds: {
      path:  'tasks',
      where: { status: 'active' },
    },
  },
  [],
  TaskListView,
)
```

`TaskListView` receives `taskIds` from the store and `TaskItem` from the registry. Nothing to export, nothing to import.

Props that come from the parent (not the store) pass through directly. Typically these are IDs or parameters that scope the query:

```tsx
const TaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['setStatus'],
  TaskItemView,
)

// The parent passes taskId; wireView uses it in the query function
<TaskItem taskId="tasks/task-1" />
```

---

## 5. Compute Properties

Compute functions close over the document. The result is a plain value assigned eagerly at read time — safe to destructure, safe to spread, no `this` to lose.

**Simple — derives a value from the document's own fields:**

```ts
models: {
  tasks: {
    schema: { /* ... */ },
    compute: {
      statusLabel:      (doc) => doc.status === 'active' ? 'In Progress' : 'Archived',
      createdAtDisplay: (doc) => new Date(doc.createdAt).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      }),
    },
  },
},

// Component — plain property read; destructure freely
const TaskItemView = ({ task }) => {
  const { title, statusLabel, createdAtDisplay } = task  // ← safe to destructure
  return (
    <li>
      <span>{title}</span>
      <span>{statusLabel}</span>
      <span>{createdAtDisplay}</span>
    </li>
  )
}
```

**Dependent — closes over the document, returns a function that takes a sibling:**

```ts
compute: {
  // task.completionPercent is a function; call it with a sibling doc
  // Destructure it freely — the closure already captured the task doc
  completionPercent: (doc) => (sprint) =>
    Math.round((doc.completedItems / sprint.totalItems) * 100),
},

// Component
const SprintRowView = ({ task, sprint }) => {
  const { completionPercent } = task          // ← safe to destructure
  return <li>{completionPercent(sprint)}%</li>
}
```

**Schema versioning:**

Documents change shape over time. `versioning` tells the store how to roll a document forward (older storage → current app) or backward (current app → older storage). Each step describes one schema version boundary.

- **rollforward** — applied when a stored document is older than the current schema. Run in order: step 1 first, then step 2, etc. The function receives the old doc and returns the new one.
- **rollback** — applied when the current app writes to storage that expects an older schema (rolling deployment). Run in reverse order.

Migration happens at read time — nothing is written back to storage.

```ts
versioning: [
  // Step 1 — v1 → v2: added 'priority' field
  // rollforward: old docs missing 'priority' get the default
  // rollback:    remove 'priority' before writing to v1 storage
  {
    partialSchema: {
      priority: { type: 'string', enum: ['high', 'medium', 'low'] },
    },
    rollforward: (doc) => ({
      ...doc,
      priority: doc.priority ?? 'medium',
    }),
    rollback: (doc) => {
      const { priority, ...rest } = doc
      return rest
    },
  },

  // Step 2 — v2 → v3: renamed dueDate → due_at
  // rollforward: copy dueDate into due_at if present
  // rollback:    copy due_at back to dueDate
  {
    rollforward: (doc) =>
      doc.dueDate
        ? { ...doc, due_at: doc.dueDate }
        : doc,
    rollback: (doc) =>
      doc.due_at
        ? { ...doc, dueDate: doc.due_at }
        : doc,
  },
],
```

A v1 document arrives at the component as v3. During a rolling deployment both field names coexist — neither client gets `undefined`.

---

## 6. Adapters

One `createStore` call. Multiple adapters route by path prefix. No changes to components, queries, or mutates when you swap adapters.

The key `'default'` is a reserved name — it matches all paths not claimed by another adapter. All other keys are the path prefix for that store.

```ts
import { createStore, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter }       from '@fiskal/antifragile/adapters/memory'
import { LocalStorageAdapter } from '@fiskal/antifragile/adapters/localStorage'
import { FirestoreAdapter }    from '@fiskal/antifragile/adapters/firestore'

export const store = createStore({
  // 'default' — catches all paths not claimed below
  default: {
    adapter: FirestoreAdapter(firebaseApp),
    models:  { tasks: TaskModel },
  },

  // 'settings' — all paths starting with 'settings/'
  settings: {
    adapter: LocalStorageAdapter(),   // persisted locally; cross-tab sync
  },

  // 'ui' — all paths starting with 'ui/'
  ui: {
    adapter: MemoryAdapter(),         // ephemeral; resets on reload
  },
})

export const wireView = createWireView(store)
```

| Key | Paths matched | Behaviour |
|---|---|---|
| `default` | everything not claimed | FirestoreAdapter — real-time, cloud-synced |
| `settings` | `settings/*` | LocalStorageAdapter — local, persisted |
| `ui` | `ui/*` | MemoryAdapter — ephemeral, in-process |

---

## 7. History & Antifragility

Every write is stored in an append-only log as an immutable snapshot. Any prior state is recoverable without re-running code.

```ts
store.history.log()
// → [
//   {
//     action: 'SetStatus',
//     writes: [{ id: 'tasks/task-1', fields: { status: 'archived' } }],
//     at: 1750000060,
//   },
// ]

store.history.back()         // roll back last write (in-memory)
store.history.forward()      // replay rolled-back write
store.history.goto(3)        // jump to any snapshot by index
store.history.currentIndex() // save this before opening a wizard
```

When a bug is filed, the write log is the bug report. Every mutation is there — named, in order, with full field payloads. Replay the sequence locally, find the step that produced the wrong state, fix the write descriptor.

Snapshots use structural sharing — the log costs only the memory of what actually changed per write. Restoring a snapshot is O(1): replace the cache pointer, notify only the collections that changed between the current and target snapshot.

**Time travel is in-memory.** For persistent undo after a remote sync, issue a compensating write:

```ts
const last = store.history.log().at(-1)
if (last?.action === 'SetStatus') {
  await setStatus({ id: last.writes[0].id, status: 'active' })
}
```

---

## 8. Mutations

Every mutate is a named, serialisable write descriptor. Every write is synchronous against the cache (optimistic) and async against the backing store. On failure the cache rolls back and affected subscribers are notified automatically.

**Simple write:**

```ts
import { createMutate } from '@fiskal/antifragile'

const setStatus = createMutate(store, {
  write: ({ id, status }: { id: string; status: string }) => ({
    path:   'tasks',
    id,
    fields: { status },
  }),
})

setStatus({ id: 'tasks/task-1', status: 'archived' })
```

**Batch write** — multiple descriptors applied in sequence:

```ts
const archiveSprint = createMutate(store, {
  write: ({ sprintId, taskIds }: { sprintId: string; taskIds: string[] }) => [
    {
      path:   'sprints',
      id:     sprintId,
      fields: { archived: true },
    },
    ...taskIds.map(id => ({
      path:   'tasks',
      id,
      fields: { archived: true },
    })),
  ],
})
```

**ACID transaction** — the adapter receives the array as one indivisible unit. All succeed or none do. A component can roll back immediately if the transaction fails:

```ts
const transfer = createMutate(store, {
  write: ({ from, to, amount }: { from: string; to: string; amount: number }) => [
    { path: 'accounts', id: from, fields: { balance: ['::increment', -amount] } },
    { path: 'accounts', id: to,   fields: { balance: ['::increment', amount]  } },
  ],
})
```

```tsx
// Component rolls back on failure — no try/catch; errors land in errors/
const TransferView = ({ fromAccount, toAccount, transfer }) => (
  <button onClick={() => transfer({ from: fromAccount.id, to: toAccount.id, amount: 50 })}>
    Transfer $50
  </button>
)
// If the adapter rejects the transaction, both balances are restored
// and an error doc appears in errors/ for the ErrorBanner to show
```

**Atomic operations** — plain TUPLES, never function calls. A write stays pure, serialisable data: `['::op']` or `['::op', value]`. The `::` prefix marks the field as an atomic op.

Increment a numeric field:

```ts
write: ({ id }) => ({
  path: 'posts', id, fields: { views: ['::increment', 1] },
})
```

Add to an array without duplicates (the value is the list of items):

```ts
write: ({ id, tag }) => ({
  path: 'tasks', id, fields: { tags: ['::arrayUnion', [tag]] },
})
```

Remove from an array:

```ts
write: ({ id, tag }) => ({
  path: 'tasks', id, fields: { tags: ['::arrayRemove', [tag]] },
})
```

Delete a specific field from the document (no value):

```ts
write: ({ id }) => ({
  path: 'tasks', id, fields: { draftTitle: ['::delete'] },
})
```

Server-assigned timestamp at commit time (no value):

```ts
write: ({ id }) => ({
  path: 'tasks', id, fields: { updatedAt: ['::serverTimestamp'] },
})
```

---

## 9. wireView

`wireView` defines a container component. That container uses `useRead` internally for each query key, collects the results as plain props, and renders the pure view.

```ts
const TaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({
    task:   { path: 'tasks',   id: taskId },
    sprint: { path: 'sprints', id: 'sprints/current', fields: ['name', 'totalItems'] },
  }),
  ['setStatus'],
  TaskItemView,
)
```

**You never write a subscription.** `wireView` owns the entire subscribe/unsubscribe lifecycle — it subscribes when the container mounts, re-subscribes only when the query key actually changes, and unsubscribes on unmount. The pure view has no library import and no cleanup to write. This is enforced, not conventional: there is no subscription API exposed to a component file (ADR-0017).

**Under the covers — `wireView` is `useRead` + props assembly:**

```tsx
function TaskItem({ taskId }) {
  const task      = useRead({ path: 'tasks',   id: taskId })   // owns subscribe + cleanup
  const sprint    = useRead({ path: 'sprints', id: 'sprints/current', fields: ['name', 'totalItems'] })
  const setStatus = store.mutates.setStatus
  // wireView renders nothing until every query is loaded, then injects loaded data
  if (task.status !== 'loaded' || sprint.status !== 'loaded') return null
  return <TaskItemView task={task.data} sprint={sprint.data} setStatus={setStatus} />
}
```

`useRead` returns an explicit **`Loadable`** — never `null`/`undefined`:

```ts
type Loadable<T> =
  | { status: 'loading' }                 // no answer from the adapter yet
  | { status: 'missing' }                 // single-item query, id absent
  | { status: 'loaded'; data: T }         // a record, or a list (may be empty)
```

`wireView` consumes the `Loadable` for you and renders the view only once every query is loaded, injecting the plain loaded data — so the pure view reads `task.title` directly and never sees a loading sentinel. A view that wants a custom loading or not-found UI reads the `Loadable` itself via `useRead` in a container:

```tsx
const TaskCardView = ({ task }: { task: Loadable<Doc> }) => {
  if (task.status === 'loading') return <li>Loading…</li>
  if (task.status === 'missing') return <li>Not found.</li>
  return <li>{task.data.title}</li>
}
```

**JSON schema validation** — declared on the model, enforced at the read/write boundary. A write that fails the schema is rejected before it reaches the adapter. The store writes an error doc to `errors/` instead. No try/catch at the call site.

**Field narrowing** — subscribe only to the fields the component renders. Re-renders fire only when those specific fields change:

```ts
const TaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: {
      path:   'tasks',
      id:     taskId,
      fields: ['title', 'status'],   // re-renders only on title or status change
    },
  }),
  ['setStatus'],
  TaskItemView,
)
```

Start without narrowing. Add `fields` only when profiling shows the re-render is measurably expensive. The pure view does not change — only the query.

---

## 10. Queries

Query shapes depend on the backing store. The store resolves each query to an adapter-native call.

**Firestore:**

```ts
// Single document by full-path id
{ path: 'tasks', id: 'tasks/task-1' }

// All documents in a collection
{ path: 'tasks' }

// Filtered
{
  path:  'tasks',
  where: { status: 'active' },
}

// Filtered + sorted
{
  path:    'tasks',
  where:   { status: 'active' },
  orderBy: { createdAt: 'desc' },
}

// Filtered + sorted + limited
{
  path:    'tasks',
  where:   { status: 'active' },
  orderBy: { createdAt: 'desc' },
  limit:   20,
}
```

**LocalStorage:**

```ts
// Settings stored as a single flat document
{ path: 'settings', id: 'settings/app' }

// Write a single setting field
write: ({ theme }: { theme: string }) => ({
  path:   'settings',
  id:     'settings/app',
  fields: { theme },
})
```

---

## 11. Advanced UI

### Portals and modals without Context

A document id is a full path. Store the active id in `ui/` — any component can query it without Context or prop drilling.

```ts
const openModal  = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    path:   'ui',
    id:     'ui/modal/active',
    fields: { id },   // e.g. 'tasks/task-1' or 'sprints/sprint-A'
  }),
})

const closeModal = createMutate(store, {
  write: () => ({
    path:   'ui',
    id:     'ui/modal/active',
    delete: true,
  }),
})
```

```tsx
// Any component deep in the tree — openModal injected, no Context required
const TaskRow = wireView(
  'TaskRow',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['openModal'],
  TaskRowView,
)

// Shell at the root — reads the stored id
const ModalShell = wireView(
  'ModalShell',
  { active: { path: 'ui', id: 'ui/modal/active' } },
  ['closeModal'],
  ModalShellView,
)

// Detail uses the stored id as its own query
const ModalDetail = wireView(
  'ModalDetail',
  ({ activeId }) => ({
    item: { path: activeId.split('/')[0], id: activeId },
  }),
  ['closeModal'],
  ModalDetailView,
)
```

No `ReactDOM.createPortal`. No `React.createContext`. No type registry.

### No `useContext`, `useCallback`, or `useMemo`

```tsx
// useContext — replaced by wireView action injection
// BEFORE: const { setTheme } = useContext(ThemeContext)
// AFTER:  setTheme arrives as a prop via wireView — no Provider, no consumer

// useCallback — not needed; wireView action references are stable across renders
// BEFORE: const handleArchive = useCallback(() => setStatus({ id }), [id, setStatus])
// AFTER:  <button onClick={() => setStatus({ id, status: 'archived' })}>Archive</button>

// useMemo — filter in the query, not the component
// BEFORE: const active = useMemo(() => tasks.filter(t => t.status === 'active'), [tasks])
// AFTER:
const TaskList = wireView(
  'TaskList',
  {
    taskIds: {
      path:  'tasks',
      where: { status: 'active' },
    },
  },
  [],
  TaskListView,
)
```

### Error boundaries and error alerts

Write failures land in `errors/` automatically. Subscribe from any component — no try/catch at the call site.

```ts
const dismissError = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    path:   'errors',
    id,
    fields: { resolved: true },
  }),
})
```

```tsx
const ErrorBannerView = ({ errors, dismissError }) => (
  <ul>
    {errors.map(err => (
      <li key={err.id}>
        {err.message}
        <button onClick={() => dismissError({ id: err.id })}>Dismiss</button>
      </li>
    ))}
  </ul>
)

const ErrorBanner = wireView(
  'ErrorBanner',
  {
    errors: {
      path:  'errors',
      where: { resolved: false },
    },
  },
  ['dismissError'],
  ErrorBannerView,
)
```

### Just-in-time schema migration

See [Compute Properties — Schema versioning](#5-compute-properties) for how `rollforward` and `rollback` work. Here is the complete model with versioning applied:

```ts
const TaskModel = {
  schema: {
    type: 'object',
    properties: {
      id:       { type: 'string' },
      title:    { type: 'string' },
      status:   { type: 'string' },
      priority: { type: 'string', enum: ['high', 'medium', 'low'] },  // added v2
      due_at:   { type: 'number' },                                    // added v3
    },
    required: ['id', 'title', 'status'],
  },
  versioning: [
    // v1 → v2
    {
      rollforward: (doc) => ({ ...doc, priority: doc.priority ?? 'medium' }),
      rollback:    (doc) => { const { priority, ...rest } = doc; return rest },
    },
    // v2 → v3
    {
      rollforward: (doc) => doc.dueDate ? { ...doc, due_at: doc.dueDate } : doc,
      rollback:    (doc) => doc.due_at  ? { ...doc, dueDate: doc.due_at } : doc,
    },
  ],
}
```

### Infinite scroll with lookahead

Store the cursor in `ui/`. Append results to the collection on each page load. No component logic required.

```ts
const loadNextPage = createMutate(store, {
  read:  () => ({ cursor: { path: 'ui', id: 'ui/taskList/cursor' } }),
  write: async ({ cursor }) => {
    const page = await fetchTasks({ after: cursor?.lastId, limit: 20 })
    return [
      ...page.items.map(task => ({
        path:   'tasks',
        id:     task.id,
        fields: task,
      })),
      {
        path:   'ui',
        id:     'ui/taskList/cursor',
        fields: { lastId: page.items.at(-1)?.id, hasMore: page.hasMore },
      },
    ]
  },
})

const TaskList = wireView(
  'TaskList',
  {
    taskIds: {
      path:    'tasks',
      where:   { status: 'active' },
      orderBy: { createdAt: 'asc' },
    },
    cursor: {
      path: 'ui',
      id:   'ui/taskList/cursor',
    },
  },
  ['loadNextPage'],
  TaskListView,
)

const TaskListView = ({ taskIds, cursor, loadNextPage, TaskItem: Item }) => (
  <>
    <ul>{taskIds.map(({ id }) => <Item key={id} taskId={id} />)}</ul>
    {cursor?.hasMore && (
      <button onClick={() => loadNextPage()}>Load more</button>
    )}
  </>
)
```

---

## 12. Testing

No test harness. No Provider. No mock store. Pure views are plain functions — test them with plain props.

**Component test:**

```tsx
import { render, screen } from '@testing-library/react'
import { TaskItemView } from './TaskItem'

test('renders title', () => {
  render(
    <TaskItemView
      task={{ id: 'tasks/task-1', title: 'Deploy', status: 'active' }}
      setStatus={vi.fn()}
    />
  )
  expect(screen.getByText('Deploy')).toBeInTheDocument()
})
```

**Mutate test — assert on the write descriptor, no UI required:**

```ts
import { resolveWrites } from '@fiskal/antifragile/test'
import { setStatus } from './store'

test('setStatus writes the correct descriptor', async () => {
  const writes = await resolveWrites(setStatus, {
    id:     'tasks/task-1',
    status: 'archived',
  })
  expect(writes).toEqual([{
    path:   'tasks',
    id:     'tasks/task-1',
    fields: { status: 'archived' },
  }])
})
```

**Playwright — behaviour tests, full app in a real browser:**

```ts
test('archive a task', async ({ page }) => {
  await page.goto('/')
  await page
    .getByText('Deploy')
    .locator('..')
    .getByRole('button', { name: 'Archive' })
    .click()
  await expect(page.getByText('Deploy')).not.toBeVisible()
})
```

**TDD without a browser:** write the mutate test and component test first. Both pass without a DOM, without a server. Wire the app only when the logic is green. The pure view can be added or changed without touching any test cases — no test breakage from view changes, no test changes from logic changes.

---

## 13. SwiftUI

### Minimum viable example

```swift
// store.swift
import Antifragile

let setStatus = createMutate(action: "SetStatus") { (payload: [String: Any]) -> [Write] in
  guard
    let id     = payload["id"]     as? String,
    let status = payload["status"] as? String
  else { return [] }
  return [Write(path: "tasks", id: id, fields: ["status": status])]
}

let store = Store.createStore {
  BackingStoreConfig(
    name: "default",
    adapter: MemoryAdapter(initial: [
      "tasks": [
        "tasks/task-1": [
          "id":     "tasks/task-1",
          "title":  "Deploy",
          "status": "active",
        ],
      ],
    ]),
    models: [
      "tasks": TaskModel(schema: [
        "type": "object",
        "properties": [
          "id":     ["type": "string"],
          "title":  ["type": "string"],
          "status": ["type": "string"],
        ],
        "required": ["id", "title", "status"],
      ]),
    ],
    mutates: [setStatus]
  )
}
```

```swift
// TaskItem.swift — pure view + wire in the same file
import SwiftUI
import Antifragile   // for wireView only

struct TaskItemView: View {
  let task: [String: Any]
  let setStatus: ([String: Any]) async throws -> Void

  var body: some View {
    HStack {
      Text(task["title"] as? String ?? "")
      Spacer()
      Button("Archive") {
        Task { try? await setStatus(["id": task["id"] ?? "", "status": "archived"]) }
      }
    }
  }
}

// Wire — same file, nothing to export
let TaskItem = wireView(
  name: "TaskItem",
  queries: { props in
    ["task": ["path": "tasks", "id": props["taskId"] as? String ?? ""]]
  },
  actions: ["setStatus"],
  view: TaskItemView.init
)

// Test — plain struct init, no environment, no store
// TaskItemView(
//   task: ["id": "tasks/task-1", "title": "Deploy", "status": "active"],
//   setStatus: { _ in }
// )
```

### Compute properties

Closure-based; safe to destructure in Swift:

```swift
let TaskModel = TaskModel(
  schema: [ /* ... */ ],
  compute: [
    // Simple — receives the doc dictionary, returns a plain value
    "statusLabel": { doc in
      (doc["status"] as? String) == "active" ? "In Progress" : "Archived"
    },

    // Dependent — returns a function that takes a sibling doc
    "completionPercent": { doc in
      { (sprint: [String: Any]) -> Int in
        let done  = doc["completedItems"]    as? Int ?? 0
        let total = sprint["totalItems"] as? Int ?? 1
        return Int((Double(done) / Double(total)) * 100)
      }
    },
  ]
)

// View reads plain computed values — destructure freely
let statusLabel = task["statusLabel"] as? String ?? ""
```

### Multiple adapters

```swift
let store = Store.createStore {
  // 'default' — catches all paths not claimed below
  BackingStoreConfig(name: "default",  adapter: FirestoreAdapter(app: firebaseApp), models: [TaskModel])
  // 'settings' — all paths starting with 'settings/'
  BackingStoreConfig(name: "settings", adapter: UserDefaultsAdapter())
  // 'ui' — all paths starting with 'ui/'
  BackingStoreConfig(name: "ui",       adapter: MemoryAdapter())
}
```

### History

```swift
store.history.back()
store.history.log()
// → [{ action: "SetStatus", writes: [{ id: "tasks/task-1", fields: { status: "archived" } }], at: … }]
```

### Error alerts

```swift
let ErrorBanner = wireView(
  name: "ErrorBanner",
  queries: [
    "errors": [
      "path":  "errors",
      "where": ["resolved": false],
    ],
  ],
  actions: ["dismissError"],
  view: ErrorBannerView.init
)
```

### Just-in-time schema migration

```swift
let TaskModel = TaskModel(
  versioning: [
    // rollforward: called when a stored doc is older than the current schema
    // rollback:    called when writing back to storage that expects an older schema
    VersionStep(
      rollforward: { doc in
        var d = doc
        if d["priority"] == nil { d["priority"] = "medium" }
        return d
      },
      rollback: { doc in
        var d = doc
        d.removeValue(forKey: "priority")
        return d
      }
    ),
  ]
)
```

---

## 14. Migration

### From Redux / RTK

| Redux | Antifragile |
|---|---|
| `useSelector(selectTaskById(id))` inside component | `task` arrives as prop via `wireView` |
| `dispatch(setStatus(id))` inside component | `setStatus` arrives as prop via `wireView` |
| `createSelector` memoised computation | `compute` closure on model — always fresh |
| Reducer (function, opaque to serialise) | Write descriptor (plain data, serialisable) |
| `state.tasks.items[id].title` tree path | `{ path: 'tasks', id: taskId }` query |
| `try { await dispatch(...).unwrap() }` | Fire-and-forget; failures land in `errors/` |

### From TanStack Query

| TanStack | Antifragile |
|---|---|
| `useQuery({ queryKey, queryFn })` inside component | `wireView` subscription outside component |
| `queryClient.invalidateQueries(key)` after every mutation | Automatic — subscriptions stay open |
| `isLoading` / `isError` / `data` three states | one `Loadable`: `{ status: 'loading' \| 'missing' \| 'loaded', data }` |
| `onMutate` + `onError` rollback (hand-rolled) | Automatic rollback on every write failure |

### From Zustand

```ts
// Zustand — before (mutation logic inside a hook, imported in the component)
const useTaskStore = create((set) => ({
  tasks: [],
  archive: (id) => set(state => ({
    tasks: state.tasks.map(t =>
      t.id === id ? { ...t, status: 'archived' } : t
    ),
  })),
}))
const { tasks, archive } = useTaskStore()

// Antifragile — after (plain data descriptor; arrives as a prop)
const setStatus = createMutate(store, {
  write: ({ id, status }) => ({
    path: 'tasks', id, fields: { status },
  }),
})
// setStatus received as a prop via wireView — no store import in the component
```

### From SwiftUI `@EnvironmentObject`

```swift
// @EnvironmentObject — before
// AppStore: ObservableObject re-renders every @Published consumer on any change.
// A change to tasks[task-2].status re-renders a view that only shows tasks[task-1].

// Antifragile — after
// The TaskItem container subscribes to tasks/task-1 only.
// A write to tasks/task-2 does not reach it — no unnecessary re-render.
```

---

## Appendix · Architecture & data flow

The shape is identical on both platforms; only the host idioms differ
(`useRead` / React on TS, `@Query` / SwiftUI on Swift).

```
            PURE VIEW                         STORE
        (zero lib imports)        ┌───────────────────────────────────┐
       ┌────────────────┐         │   normalized in-memory cache      │
       │  TaskItemView  │◄──props─┤   path → id → Doc                 │
       │  (display only)│         │   immutable · structural sharing  │
       └──────┬─────────┘         │      ▲                 │          │
              │ event             │      │ notify(path)    │ getCache │
              ▼                   │      │ (SYNC)          ▼          │
       ┌────────────────┐  read   │  ┌───┴────────┐   ┌──────────┐    │
       │ wireView       │◄────────┤  │ subscribers│   │  enrich  │    │
       │ container      │         │  │ useRead /  │   │ compute  │    │
       │ (useRead +     │─mutate─►│  │ @Query     │   │ closures │    │
       │  bound actions)│         │  └────────────┘   └──────────┘    │
       └────────────────┘         │                                   │
                                  │  mutate pipeline                  │
                                  │   1. validate(schema)             │
                                  │   2. apply → cache      (SYNC)    │
                                  │   3. notify subscribers (SYNC)    │
                                  │   4. enqueue → adapter  (ASYNC)   │
                                  └───────────────┬───────────────────┘
                                                  │ async
                                       ┌──────────▼──────────┐
                                       │ ADAPTER (transport) │
                                       │ subscribe() write() │
                                       └──────────┬──────────┘
                          success: onChange ──────┼────── failure
                          → reconcile cache       │       → revert cache to
                            (source of truth)     │         adapter truth +
                                                  │         write errors/ doc
                                       ┌──────────▼──────────┐
                                       │   backing store     │
                                       │ Firestore/CloudKit/ │
                                       │ Gun/UserDefaults/…  │
                                       └─────────────────────┘
```

### Write lifecycle (optimistic, sync-first, async-confirmed)

Every write is applied **synchronously** to the normalized in-memory cache
first, so the UI updates on the same tick. The remote adapter is contacted
**asynchronously**. The cache is the optimistic projection; the adapter is the
source of truth.

```
mutate(payload)
   │
   ├─ 1. validate against model.schema ───── fail ─► throw + errors/ doc (cache untouched)
   │
   ├─ 2. apply WriteDescriptor to cache  ◄── SYNCHRONOUS, optimistic
   ├─ 3. notify(path) → subscribers re-render
   │
   └─ 4. adapter.write(descriptor)        ◄── ASYNCHRONOUS
            │
            ├─ ack  ─► adapter onChange reconciles cache with authoritative record
            │
            └─ nack ─► raise error, write errors/ doc,
                       REVERT cache to whatever the adapter reports as truth
```

Conflict resolution today is **last-write-wins** — there is no field-level
merge. The revert on failure restores the adapter's authoritative value, not a
merge of local + remote. Field-level merge / CRDT convergence is a planned,
opt-in strategy (it is not the default).

### Read path

```
view needs data
   │
   └─ wireView/useRead resolves query ─► read from cache (SYNC) ─► enrich (apply
        compute closures as plain props) ─► hand to view as props

        Loadable contract (identical on both platforms — no null/undefined):
          .loading   — query not yet answered by the adapter
          .missing   — single-item query, id absent (never for a collection)
          .loaded    — a record, or a list (which may be empty)

        TS:    { status: 'loading' | 'missing' | 'loaded', data }
        Swift: enum Loadable<T> { case loading; case missing; case loaded(T) }

        wireView renders the view only once every query is .loaded and injects
        the plain loaded data, so a pure view never branches on load state.
```
