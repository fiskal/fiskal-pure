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
const TaskItem = ({ task, setStatus }) => (
  <li>
    <span>{task.title}</span>
    <span>{task.status}</span>
    <button onClick={() => setStatus({ id: task.id, status: 'archived' })}>
      Archive
    </button>
  </li>
)
```

Wire it in the same file. The wire is a plain data declaration:

```tsx
import { wireView } from './store'

wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['setStatus'],
  TaskItem,
)
```

Test with plain props — no Provider, no store, no setup:

```tsx
render(
  <TaskItem
    task={{ id: 'tasks/task-1', title: 'Deploy', status: 'active' }}
    setStatus={vi.fn()}
  />
)
```

`wireView` is the only import. `TaskItem` itself has none.

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
          path: 'tasks',
          id,
          fields: { status },
          // merge is the default — only status changes, all other fields survive
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

Wired components are not exported. `wireView` registers each component by name. When another wired component has a prop matching that name, the wired version is injected automatically.

```tsx
// TaskList.tsx
import { wireView } from './store'

const TaskList = ({ taskIds, TaskItem: Item }) => (
  <ul>
    {taskIds.map(({ id }) => (
      <Item key={id} taskId={id} />
    ))}
  </ul>
)

// WiredTaskItem is injected into TaskList's `TaskItem` prop automatically
// because it was registered above with that name. Nothing to export.
wireView(
  'TaskList',
  {
    taskIds: {
      path:  'tasks',
      where: { status: 'active' },
    },
  },
  [],
  TaskList,
)
```

Props that come from the parent (not the store) pass through directly. Typically these are IDs or parameters that scope the query:

```tsx
// Parent passes taskId — wireView uses it in the query function
wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['setStatus'],
  TaskItem,
)

// Usage — taskId is the only prop the parent provides
<WiredTaskItem taskId="tasks/task-1" />
```

---

## 5. Compute Properties

Getters run at read time on the enriched document. The view reads a plain value — it never knows computation happened.

**Basic — derived from the document's own fields:**

```ts
models: {
  tasks: {
    schema: { /* ... */ },
    compute: {
      get statusLabel(this: { status: string }) {
        return this.status === 'active' ? 'In Progress' : 'Archived'
      },
      get createdAtDisplay(this: { createdAt: number }) {
        return new Date(this.createdAt).toLocaleDateString(undefined, {
          month: 'short', day: 'numeric', year: 'numeric',
        })
      },
    },
  },
},

// Component — plain property read; no import, no function call
const TaskItem = ({ task }) => (
  <li>
    <span>{task.title}</span>
    <span>{task.statusLabel}</span>
    <span>{task.createdAtDisplay}</span>
  </li>
)
```

Never destructure getters — `this` is lost in strict mode:

```ts
const { statusLabel } = task   // WRONG — throws
const label = task.statusLabel // CORRECT
```

**Dependent — pass a sibling document as an argument:**

```ts
compute: {
  // Call as a method on the doc: task.completionPercent(sprint)
  // Never destructure: const { completionPercent } = task — 'this' is lost
  completionPercent(
    this: { completedItems: number },
    sprint: { totalItems: number },
  ) {
    return Math.round((this.completedItems / sprint.totalItems) * 100)
  },
},

// Component
const SprintRow = ({ task, sprint }) => (
  <li>{task.completionPercent(sprint)}%</li>
)
```

**Schema versioning — migrate documents at read time, never in storage:**

```ts
versioning: [
  // v1 → v2: added 'priority' field
  {
    partialSchema: {
      priority: { type: 'string', enum: ['high', 'medium', 'low'] },
    },
    rollforward: (doc) => ({ ...doc, priority: doc.priority ?? 'medium' }),
    rollback:    (doc) => { const { priority, ...rest } = doc; return rest },
  },
  // v2 → v3: renamed dueDate → due_at
  {
    rollforward: (doc) => doc.dueDate ? { ...doc, due_at: doc.dueDate } : doc,
    rollback:    (doc) => doc.due_at  ? { ...doc, dueDate: doc.due_at } : doc,
  },
],
```

A v1 document is delivered to the component as v3. No server migration job. During a rolling deployment both field names coexist — neither client gets `undefined`.

---

## 6. Adapters

One `createStore` call. Multiple adapters route by path prefix. No changes to components, queries, or mutates when you swap adapters.

```ts
import { createStore, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter }       from '@fiskal/antifragile/adapters/memory'
import { LocalStorageAdapter } from '@fiskal/antifragile/adapters/localStorage'
import { FirestoreAdapter }    from '@fiskal/antifragile/adapters/firestore'

export const store = createStore({
  default: {
    adapter: FirestoreAdapter(firebaseApp),  // tasks, sprints → Firestore
    models:  { tasks: TaskModel },
  },
  settings: {
    adapter: LocalStorageAdapter(),          // settings/* → localStorage; persisted
    paths:   ['settings/'],
  },
  ui: {
    adapter: MemoryAdapter(),               // ui/* → in-memory; resets on reload
    paths:   ['ui/'],
  },
})

export const wireView = createWireView(store)
```

Path-based routing is structural. A `ui/` write cannot reach Firestore — the prefix is the enforcement mechanism.

| Path prefix | Adapter | Behaviour |
|---|---|---|
| `tasks/`, `sprints/` | FirestoreAdapter | Real-time, cloud-synced, persisted |
| `settings/` | LocalStorageAdapter | Persisted locally, cross-tab sync |
| `ui/` | MemoryAdapter | Ephemeral, resets on reload |

---

## 7. History & Antifragility

Every write is stored in an append-only log as an immutable snapshot. Any prior state is recoverable without re-running code.

```ts
store.history.log()
// → [
//   { action: 'SetStatus', writes: [{ id: 'tasks/task-1', fields: { status: 'archived' } }], at: 1750000060 },
// ]

store.history.back()         // roll back last write (in-memory)
store.history.forward()      // replay rolled-back write
store.history.goto(3)        // jump to any snapshot by index
store.history.currentIndex() // snapshot index — save before opening a wizard
```

When a bug is filed, the write log is the bug report. Every mutation is there — named, in order, with full field payloads. Replay the sequence locally, find the step that produced the wrong state, fix the write descriptor.

Snapshots use structural sharing. The log costs only the memory of what actually changed per write, not a full copy. Restoring a snapshot is O(1): replace the cache pointer, notify only the collections that changed between the current and target snapshot.

**Time travel is in-memory.** It rolls back the cache; it does not send compensating writes to the server. For persistent undo after sync:

```ts
const last = store.history.log().at(-1)
if (last?.action === 'SetStatus') {
  await setStatus({ id: last.writes[0].id, status: 'active' })
}
```

---

## 8. Mutations

Every mutate is a named, serialisable write descriptor — not a function called inside a component. Every write is synchronous against the cache (optimistic) and async against the backing store. On failure the cache rolls back automatically.

**Simple write:**

```ts
const setStatus = createMutate(store, {
  write: ({ id, status }: { id: string; status: string }) => ({
    path: 'tasks',
    id,
    fields: { status },
  }),
})

setStatus({ id: 'tasks/task-1', status: 'archived' })
await setStatus({ id: 'tasks/task-1', status: 'archived' })  // await remote confirmation
```

**Batch write** — multiple writes in one call, applied in sequence:

```ts
const archiveSprint = createMutate(store, {
  write: ({ sprintId, taskIds }: { sprintId: string; taskIds: string[] }) => [
    { path: 'sprints', id: sprintId,  fields: { archived: true } },
    ...taskIds.map(id => ({
      path:   'tasks',
      id,
      fields: { archived: true },
    })),
  ],
})
```

**ACID transaction** — array passed to the adapter as one indivisible unit. All succeed or none do:

```ts
const transfer = createMutate(store, {
  write: ({ from, to, amount }: { from: string; to: string; amount: number }) => [
    { path: 'accounts', id: from, fields: { balance: { __op: '::increment', n: -amount } } },
    { path: 'accounts', id: to,   fields: { balance: { __op: '::increment', n:  amount } } },
  ],
})
// A network failure rolls back both writes — neither balance changes
```

**Atomic operations — numeric increment:**

```ts
write: ({ id }) => ({
  path: 'posts', id, fields: { views: { __op: '::increment', n: 1 } },
})
```

**Atomic operations — array union (add without duplicates):**

```ts
write: ({ id, tag }) => ({
  path: 'tasks', id, fields: { tags: { __op: '::arrayUnion', values: [tag] } },
})
```

**Atomic operations — array remove:**

```ts
write: ({ id, tag }) => ({
  path: 'tasks', id, fields: { tags: { __op: '::arrayRemove', values: [tag] } },
})
```

**Atomic operations — delete a field:**

```ts
write: ({ id }) => ({
  path: 'tasks', id, fields: { draftTitle: { __op: '::delete' } },
})
```

**Atomic operations — server timestamp (assigned at commit time):**

```ts
write: ({ id }) => ({
  path: 'tasks', id, fields: { updatedAt: { __op: '::serverTimestamp' } },
})
```

---

## 9. wireView

`wireView` creates a container that owns the data. The view inside never imports from the library.

```ts
wireView(
  'TaskItem',
  ({ taskId }) => ({
    task:   { path: 'tasks',   id: taskId },
    sprint: { path: 'sprints', id: 'sprints/current', fields: ['name', 'totalItems'] },
  }),
  ['setStatus'],
  TaskItem,
)
```

**Under the covers — `wireView` is `useRead` + props injection:**

```tsx
function WiredTaskItem({ taskId }) {
  const task      = useRead({ path: 'tasks',   id: taskId })
  const sprint    = useRead({ path: 'sprints', id: 'sprints/current', fields: ['name', 'totalItems'] })
  const setStatus = store.mutates.setStatus
  return <TaskItem task={task} sprint={sprint} setStatus={setStatus} />
}
```

`useRead` subscribes to the store, fires on every write to that path, and returns the current doc. Use it directly for queries too dynamic for a static spec — but always in a container file, never inside the view.

**Guard against loading and not-found at the component boundary:**

```tsx
const TaskItem = ({ task }: { task: Task | undefined | null }) => {
  if (task === undefined) return <li>Loading…</li>
  if (task === null)      return <li>Not found.</li>
  return <li>{task.title}</li>
}
```

**JSON schema validation** — declared on the model, enforced at the read/write boundary. A write that fails validation is rejected before it reaches the adapter. The store writes an error document to `errors/` instead. No try/catch at the call site.

**Field narrowing** — subscribe only to the fields the component uses. Re-renders only fire when those specific fields change.

```ts
wireView(
  'TaskItem',
  ({ taskId }) => ({
    task: {
      path:   'tasks',
      id:     taskId,
      fields: ['title', 'status'],  // re-renders only when title or status changes
    },
  }),
  ['setStatus'],
  TaskItem,
)
```

Start without narrowing. Add `fields` only when profiling shows the re-render is measurably expensive. The component does not change — only the query.

---

## 10. Queries

Query shape depends on the backing store. The store resolves each query to an adapter-native call.

**Firestore:**

```ts
// Single document by full-path id
{ path: 'tasks', id: 'tasks/task-1' }

// All documents in a collection
{ path: 'tasks' }

// Filtered
{ path: 'tasks', where: { status: 'active' } }

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
// Settings stored as a single document
{ path: 'settings', id: 'settings/app' }

// Write a setting
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
    path: 'ui', id: 'ui/modal/active', fields: { id },
  }),
})
const closeModal = createMutate(store, {
  write: () => ({ path: 'ui', id: 'ui/modal/active', delete: true }),
})
```

```tsx
// Any component deep in the tree — openModal injected, no Context required
wireView(
  'TaskRow',
  ({ taskId }) => ({
    task: { path: 'tasks', id: taskId },
  }),
  ['openModal'],
  TaskRow,
)

// Shell at the root — reads the stored id
wireView(
  'ModalShell',
  { active: { path: 'ui', id: 'ui/modal/active' } },
  ['closeModal'],
  ModalShell,
)

// Detail uses the stored id as its own query
wireView(
  'ModalDetail',
  ({ activeId }) => ({
    item: { path: activeId.split('/')[0], id: activeId },
  }),
  ['closeModal'],
  ModalDetail,
)
```

No `ReactDOM.createPortal`. No `React.createContext`. No type registry.

### No `useContext`, `useCallback`, or `useMemo`

```tsx
// useContext — replaced by wireView action injection
// BEFORE: const { setTheme } = useContext(ThemeContext)
// AFTER:  setTheme arrives as a prop via wireView — no Provider, no consumer

// useCallback — wireView action references are stable; no wrapper needed
// BEFORE: const handleArchive = useCallback(() => archiveTask({ id }), [id, archiveTask])
// AFTER:  <button onClick={() => setStatus({ id, status: 'archived' })}>Archive</button>

// useMemo — filter in the query, not the component
// BEFORE: const active = useMemo(() => tasks.filter(t => t.status === 'active'), [tasks])
// AFTER:
wireView(
  'TaskList',
  { taskIds: { path: 'tasks', where: { status: 'active' } } },
  [],
  TaskList,
)
```

### Error boundaries and error alerts

Write failures land in `errors/` automatically. Subscribe from any component — no try/catch at the call site.

```ts
const dismissError = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    path: 'errors', id, fields: { resolved: true },
  }),
})
```

```tsx
const ErrorBanner = ({ errors, dismissError }) => (
  <ul>
    {errors.map(err => (
      <li key={err.id}>
        {err.message}
        <button onClick={() => dismissError({ id: err.id })}>Dismiss</button>
      </li>
    ))}
  </ul>
)

wireView(
  'ErrorBanner',
  { errors: { path: 'errors', where: { resolved: false } } },
  ['dismissError'],
  ErrorBanner,
)
```

### Just-in-time schema migration

Old documents are migrated transparently at read time — nothing written back to storage. The store applies `versioning` steps in order when the document leaves the cache.

```ts
// Pulling in a v2 document into a v3 app
versioning: [
  // v1 → v2: added 'priority'
  {
    partialSchema: {
      priority: { type: 'string', enum: ['high', 'medium', 'low'] },
    },
    rollforward: (doc) => ({ ...doc, priority: doc.priority ?? 'medium' }),
    rollback:    (doc) => { const { priority, ...rest } = doc; return rest },
  },
  // v2 → v3: renamed dueDate → due_at
  {
    rollforward: (doc) => doc.dueDate ? { ...doc, due_at: doc.dueDate } : doc,
    rollback:    (doc) => doc.due_at  ? { ...doc, dueDate: doc.due_at } : doc,
  },
],
```

A doc stored as v2 is delivered to the component as v3. Rolling deployments: both field names coexist — neither client gets `undefined`.

### Infinite scroll with lookahead

Store the cursor in `ui/`. Append results to the collection on load. No component logic required.

```ts
const loadNextPage = createMutate(store, {
  read: () => ({ cursor: { path: 'ui', id: 'ui/taskList/cursor' } }),
  write: async ({ cursor }) => {
    const page = await fetchTasks({ after: cursor?.lastId, limit: 20 })
    return [
      ...page.items.map(task => ({
        path: 'tasks', id: task.id, fields: task,
      })),
      {
        path:   'ui',
        id:     'ui/taskList/cursor',
        fields: { lastId: page.items.at(-1)?.id, hasMore: page.hasMore },
      },
    ]
  },
})

wireView(
  'TaskList',
  {
    taskIds: { path: 'tasks', where: { status: 'active' }, orderBy: { createdAt: 'asc' } },
    cursor:  { path: 'ui', id: 'ui/taskList/cursor' },
  },
  ['loadNextPage'],
  TaskList,
)

const TaskList = ({ taskIds, cursor, loadNextPage, TaskItem: Item }) => (
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

No test harness. No Provider. No mock store. Components are plain functions — test them with plain props.

**Component test:**

```tsx
import { render, screen } from '@testing-library/react'
import { TaskItem } from './TaskItem'

test('renders title', () => {
  render(
    <TaskItem
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
  const writes = await resolveWrites(setStatus, { id: 'tasks/task-1', status: 'archived' })
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

**TDD without a browser:** write the mutate test and component test first. Both pass without a DOM, without a server, without starting the app. Wire up the application only when the logic is green. The view can be added or changed without touching the test cases — no test breakage from view changes, no test changes from logic changes.

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
        "tasks/task-1": ["id": "tasks/task-1", "title": "Deploy", "status": "active"],
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

struct TaskItem: View {
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
let WiredTaskItem = wireView(
  name: "TaskItem",
  queries: { props in
    ["task": ["path": "tasks", "id": props["taskId"] as? String ?? ""]]
  },
  actions: ["setStatus"],
  view: TaskItem.init
)

// Test
// TaskItem(
//   task: ["id": "tasks/task-1", "title": "Deploy", "status": "active"],
//   setStatus: { _ in }
// )
```

### Compute properties

```swift
let TaskModel = TaskModel(
  schema: [ /* ... */ ],
  compute: [
    // Basic getter
    "statusLabel": { doc in
      (doc["status"] as? String) == "active" ? "In Progress" : "Archived"
    },
    // Dependent — pass a sibling document
    "completionPercent": { doc, sprint in
      let done  = doc["completedItems"]    as? Int ?? 0
      let total = sprint["totalItems"] as? Int ?? 1
      return Int((Double(done) / Double(total)) * 100)
    },
  ]
)
```

### Multiple adapters

```swift
let store = Store.createStore {
  BackingStoreConfig(name: "default",  adapter: FirestoreAdapter(app: firebaseApp), models: [TaskModel])
  BackingStoreConfig(name: "settings", adapter: UserDefaultsAdapter(), paths: ["settings/"])
  BackingStoreConfig(name: "ui",       adapter: MemoryAdapter(),       paths: ["ui/"])
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
wireView(
  name: "ErrorBanner",
  queries: ["errors": ["path": "errors", "where": ["resolved": false]]],
  actions: ["dismissError"],
  view: ErrorBanner.init
)
```

### Just-in-time schema migration

```swift
let TaskModel = TaskModel(
  versioning: [
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
| `dispatch(archiveTask(id))` inside component | `setStatus` arrives as prop via `wireView` |
| `createSelector` memoised computation | `compute` getter on model — always fresh |
| Reducer (function, opaque to serialise) | Write descriptor (plain data, serialisable) |
| `state.tasks.items[id].title` tree path | `{ path: 'tasks', id: taskId }` query |
| `try { await dispatch(...).unwrap() }` | Fire-and-forget; failures land in `errors/` |

### From TanStack Query

| TanStack | Antifragile |
|---|---|
| `useQuery({ queryKey, queryFn })` inside component | `wireView` subscription outside component |
| `queryClient.invalidateQueries(key)` after every mutation | Automatic — subscriptions stay open |
| `isLoading` / `isError` / `data` three states | `undefined` (loading) · `null` (not found) · `Doc` |
| `onMutate` + `onError` rollback (hand-rolled) | Automatic rollback on every write failure |

### From Zustand

```ts
// Zustand — before
const useTaskStore = create((set) => ({
  tasks: [],
  archive: (id) => set(state => ({
    tasks: state.tasks.map(t => t.id === id ? { ...t, status: 'archived' } : t),
  })),
}))
const { tasks, archive } = useTaskStore()  // imported inside the component

// Antifragile — after
const setStatus = createMutate(store, {
  write: ({ id, status }) => ({ path: 'tasks', id, fields: { status } }),
})
// Received as a prop via wireView — no store import in the component
```

### From SwiftUI `@EnvironmentObject`

```swift
// @EnvironmentObject — before
// AppStore: ObservableObject re-renders every @Published consumer on any change.
// A change to tasks[task-2].status re-renders a view that only shows tasks[task-1].

// Antifragile — after
// WiredTaskItem for task-1 subscribes to tasks/task-1 only.
// A write to tasks/task-2 does not reach it.
```
