# Antifragile — `@fiskal/antifragile`

State management for React (TypeScript) and SwiftUI (Swift) where the view layer and data layer are completely separate — by construction, not by convention.

---

## Table of Contents

1. [What is Antifragile](#1-what-is-antifragile)
2. [The Mental Model Shift](#2-the-mental-model-shift)
3. [Getting Started](#3-getting-started)
4. [API Reference](#4-api-reference)
5. [Patterns](#5-patterns)
6. [Anti-Patterns](#6-anti-patterns)
7. [TypeScript API](#7-typescript-api)
8. [Swift API](#8-swift-api)
9. [Migration Guides](#9-migration-guides)
10. [Architecture](#10-architecture)
11. [Known Limits](#11-known-limits)

---

## 1. What is Antifragile

Antifragile enforces a single hard rule:

> **The view layer renders and dispatches. Everything else — reads, writes, computed properties, validation, business logic — lives in the store.**

The connection between a component and the store is `wireView`. It is always declared outside the component file. A pure component has zero imports from `@fiskal/antifragile`. This is not a convention you agree to follow — it is a structural constraint. If someone adds a `useRead` or `useStore` call inside a component, the zero-import rule visibly breaks the pattern.

### The two problems it solves

**Problem 1: Testing.**
React's hooks API (`useState`, `useEffect`, `useSelector`) puts data logic inside components. Testing that logic requires mounting the component or mocking hooks. With Antifragile, all logic lives in the store. Components are plain functions of their props. You test them by passing props directly — no Provider, no store, no mounts.

**Problem 2: AI agents.**
AI coding agents corrupt application state by adding `useState`, `useEffect`, and `useContext` inside components. They model state near its consumers — because that is what they are trained on. Antifragile removes the API surface. There is no `useRead` to call inside a component. There is no `useStore`. The only entry point is `wireView`, and it lives outside the component file. An agent cannot accidentally blur the boundary because the boundary has no door on the component side.

### Why "antifragile"

Standard observability tells you what broke. Antifragile means each failure makes the system stronger:

1. Failure occurs — the action log and snapshot ship to the server automatically.
2. Engineer replays the exact write sequence — root cause found without guessing.
3. Fix deployed.
4. Same failure detected at runtime — `store.history.back()` restores from the pre-failure snapshot.
5. The failure never reaches a user again.

Every write is a named, serialisable data descriptor. The complete log is always there. When something breaks you have the exact sequence that caused it — not a stack trace and a guess.

---

## 2. The Mental Model Shift

This section exists because Antifragile directly conflicts with patterns that are deeply familiar. The conflict is intentional. If these replacements feel wrong at first, that is the friction of unlearning.

### `useState` → store subscription

You no longer hold server data in component state.

```tsx
// What you used to write
const [task, setTask] = useState(null)
useEffect(() => { fetch(`/tasks/${id}`).then(setTask) }, [id])

// What Antifragile gives you — the component receives task as a plain prop
// wireView handles the subscription lifecycle outside the component
const TaskItem = ({ task }) => <span>{task.title}</span>
```

### `useEffect(() => fetch(), [])` → wireView subscription

You no longer write fetch-on-mount effects. wireView handles subscribe, receive, and cleanup.

### `useContext(StoreContext)` → injected action

You no longer thread context through the tree. Any wired component can declare an action by name and receive it as a prop. No Provider. No consumer.

### `useMemo` → not needed

Filtering happens in the query. The component receives the already-filtered list. There is nothing to memoize.

### `useCallback` → not needed

Actions from `createWireView` are stable references across all renders. Pass them directly to components. No inline arrow wrappers.

### `React.memo` → not needed

Each `wireView` subscribes to exactly one document. A sibling's update fires only the sibling's subscriber. There are no cascading re-renders to block.

### Redux mental model

Redux removes reducers from components but still requires `useSelector` and `useDispatch` inside them. Antifragile removes those imports entirely. The component never knows the store exists.

| Redux | Antifragile |
|---|---|
| `useSelector(selectTaskById(id))` | `task` arrives as a prop via `wireView` |
| `dispatch(archiveTask(id))` | `archiveTask({ id })` arrives as a prop via `wireView` |
| `createSelector` memoized computation | model `compute` getter — always fresh |
| reducer (function, opaque) | write descriptor (data, serialisable) |

### TanStack Query mental model

TanStack is right for pure REST/HTTP with no real-time requirement. Migrate to Antifragile when you need real-time, offline queue, or unified TypeScript/Swift state.

| TanStack Query | Antifragile |
|---|---|
| `useQuery({ queryKey, queryFn })` inside component | `wireView` subscription outside component |
| `queryClient.invalidateQueries(key)` after every mutation | automatic — subscriptions stay open |
| `onMutate` + `onError` rollback (hand-rolled) | automatic on every `createMutate` |
| `isLoading`, `isError`, `data` three states | `undefined` (loading), `null` (not found), `Doc` (data) |

### SwiftUI @EnvironmentObject mental model

`AppStore: ObservableObject` triggers re-renders for all consumers when any `@Published` property changes. A change to `task-2.status` re-renders every view that holds a reference to `AppStore` — including views that only display `task-1`.

Antifragile subscribes per document. `WiredTaskItem` for `task-1` only re-renders when `task-1` changes.

---

## 3. Getting Started

### Install

**TypeScript / React**

```sh
npm install @fiskal/antifragile
```

**Swift / SwiftUI — Swift Package Manager**

In `Package.swift`:

```swift
.package(url: "https://github.com/fiskal/fiskal-antifragile", from: "0.1.0")
```

Then add `"Antifragile"` to your target's dependencies.

### Your first wireView in 5 minutes

**Step 1: Create the store (`store.ts`)**

```ts
import { createStore, createMutate, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

// 1. Model — JSON schema + computed properties
const TaskModel = {
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
  compute: {
    get createdAtDisplay(this: { createdAt: number }) {
      return new Date(this.createdAt).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      })
    },
    get statusLabel(this: { status: string }) {
      return this.status === 'active' ? 'In Progress' : 'Archived'
    },
  },
}

// 2. Store — one per app
// Document ids are always full paths: 'collection/localId'
export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'tasks/task-1', title: 'Deploy to production', status: 'active', createdAt: Date.now() - 86_400_000 },
      { id: 'tasks/task-2', title: 'Write release notes',  status: 'active', createdAt: Date.now() - 3_600_000 },
    ],
  }),
  { models: { tasks: TaskModel } },
)

// 3. Mutates — named writes as plain data
export const addTask = createMutate(store, {
  write: ({ id, title }) => ({
    id,  // full path: 'tasks/task-3'
    fields: { title, status: 'active', createdAt: Date.now() },
    merge: false,
  }),
})

export const archiveTask = createMutate(store, {
  write: ({ id }) => ({ id, fields: { status: 'archived' }, merge: true }),
})

// 4. wireView factory — bound to this store and its mutates
export const wireView = createWireView(store, { addTask, archiveTask })
```

**Step 2: Write a pure component (`TaskItem.tsx`)**

This file has zero imports from `@fiskal/antifragile`. It is a plain function.

```tsx
// TaskItem.tsx — zero library imports
type Task = {
  id: string
  title: string
  createdAtDisplay: string  // compute getter applied by the store
  statusLabel: string
}

type Props = {
  task: Task
  archiveTask: (payload: { id: string }) => void
}

export const TaskItem = ({ task, archiveTask }: Props) => (
  <li>
    <span>{task.title}</span>
    <span>{task.createdAtDisplay}</span>
    <span>{task.statusLabel}</span>
    <button onClick={() => archiveTask({ id: task.id })}>Archive</button>
  </li>
)
```

**Step 3: Wire it (`wires.ts`)**

```ts
// wires.ts — the ONLY file that connects components to the store
import { wireView } from './store'
import { TaskItem } from './TaskItem'
import { TaskList } from './TaskList'

// Single-document subscription — id is the full path
export const WiredTaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),   // taskId = 'tasks/task-1'
  ['archiveTask'],
  TaskItem,
)

// Collection subscription — 'collection' required for where queries
export const WiredTaskList = wireView(
  'TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },
  ['addTask'],
  TaskList,
  // WiredTaskItem is automatically injected into TaskList's TaskItem prop
)
```

**Step 4: Use it**

```tsx
// App.tsx
import { WiredTaskList } from './wires'

export const App = () => <WiredTaskList />
```

That is it. `TaskItem.tsx` and `TaskList.tsx` have zero library imports. All subscription management lives in `wires.ts`. All state logic lives in `store.ts`.

---

## 4. API Reference

### Document IDs — the full-path convention

Every document's `id` is the full path: `'{collection}/{localId}'`.

```
'tasks/task-1'       → collection: tasks,    local id: task-1
'sprints/sprint-A'   → collection: sprints,  local id: sprint-A
'ui/modal/active'    → collection: ui/modal, local id: active
```

For single-document queries, pass `id` alone — the store parses the collection from the prefix. `collection` is only needed for collection-level queries (where, orderBy):

```ts
{ id: 'tasks/task-1' }                               // single doc — no collection needed
{ collection: 'tasks', where: { status: 'active' } } // collection query — collection required
```

Seed data and writes always use full-path ids:

```ts
// WRONG — the store cannot resolve 'task-1' to a collection
MemoryAdapter({ tasks: [{ id: 'task-1', title: '...' }] })

// CORRECT
MemoryAdapter({ tasks: [{ id: 'tasks/task-1', title: '...' }] })
```

---

### `Model`

A `Model` defines the schema, computed properties, and migration history for a collection of documents. Register it with `createStore`.

```ts
const TaskModel = {
  // JSON Schema — validated at every read/write boundary
  schema: {
    type: 'object',
    properties: {
      id:        { type: 'string' },
      title:     { type: 'string', minLength: 1 },
      status:    { type: 'string', enum: ['active', 'archived'] },
      createdAt: { type: 'number' },
      dueDate:   { type: 'number', nullable: true },
    },
    required: ['id', 'title', 'status', 'createdAt'],
  },

  // Computed properties — applied by the store before delivering docs to wireView
  compute: {
    // Getter — derives from own fields; read as a plain value in the component
    get createdAtDisplay(this: { createdAt: number }) {
      return new Date(this.createdAt).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      })
    },
    get statusLabel(this: { status: string }) {
      return this.status === 'active' ? 'In Progress' : 'Archived'
    },
    get isOverdue(this: { dueDate: number | null }) {
      return !!this.dueDate && this.dueDate < Date.now()
    },

    // Computer — takes a sibling document; called as a METHOD on the doc, never destructured
    // task.completionPercent(sprint)  ← correct
    // const { completionPercent } = task; completionPercent(sprint)  ← WRONG, 'this' is lost
    completionPercent(this: { completedItems: number }, sprint: { totalItems: number }) {
      return Math.round((this.completedItems / sprint.totalItems) * 100)
    },
  },

  // Schema versioning — roll documents forward at read time, backward on rollback
  versioning: [
    {
      partialSchema: { priority: { type: 'string', enum: ['high', 'medium', 'low'] } },
      rollforward: (doc: any) => ({ ...doc, priority: doc.priority ?? 'medium' }),
      rollback:    (doc: any) => { const { priority, ...rest } = doc; return rest },
    },
  ],
}
```

**Compute rules:**
- Getters derive from `this` (the document's own fields). Applied as live `Object.defineProperty` descriptors after enrichment — they run at read time, not write time.
- Computers (methods) take a sibling document as argument. Call them as methods: `task.completionPercent(sprint)`. Never destructure them — `this` is lost.
- Compute names must not collide with schema field names.

---

### `createStore`

Creates the single store for the application. One store per app.

```ts
import { createStore } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'
import { FirestoreAdapter } from '@fiskal/antifragile/adapters/firestore'
import { NSUserDefaultsAdapter } from '@fiskal/antifragile/adapters/nsuserdefaults'

// Simple — one adapter
export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'tasks/task-1', title: 'Deploy', status: 'active', createdAt: Date.now() },
    ],
  }),
  { models: { tasks: TaskModel } },
)

// Multiple backing stores — path prefix routes writes to the correct adapter
export const store = createStore({
  default: {
    adapter: FirestoreAdapter(firebaseApp),
    models:  { tasks: TaskModel, sprints: SprintModel },
  },
  ui: {
    adapter: MemoryAdapter(),     // local-only — never synced to remote
    paths:   ['ui/'],
  },
  defaults: {
    adapter: NSUserDefaultsAdapter(),
    models:  { settings: SettingsModel },
  },
})
```

`store.addStore` registers an additional backing store after construction:

```ts
store.addStore('mongo', {
  adapter: MongoAdapter(mongoClient),
  models:  { users: UserModel },
})
```

**History API:**

```ts
store.history.back()         // roll back last write
store.history.forward()      // replay rolled-back write
store.history.goto(3)        // jump to any snapshot by index
store.history.currentIndex() // current snapshot index — use to snapshot before a wizard
store.history.log()
// → [
//   { action: 'AddTask',     writes: [{ id: 'tasks/t1', fields: { title: 'Deploy' }, merge: false }], at: 1750000000 },
//   { action: 'ArchiveTask', writes: [{ id: 'tasks/t1', fields: { status: 'archived' }, merge: true }], at: 1750000060 },
// ]
```

---

### `MemoryAdapter`

The default adapter. Fully functional — not a test fake. Runs in-process. Synchronous reads. No server required.

```ts
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

const adapter = MemoryAdapter({
  tasks: [
    { id: 'tasks/task-1', title: 'Deploy',       status: 'active', createdAt: Date.now() - 86_400_000 },
    { id: 'tasks/task-2', title: 'Write release', status: 'active', createdAt: Date.now() - 3_600_000 },
  ],
  sprints: [
    { id: 'sprints/sprint-1', name: 'Sprint 1', totalItems: 10 },
  ],
})
```

Swap `MemoryAdapter` for any other adapter by changing one line in `createStore`. Components, queries, mutates, and tests are unchanged.

**Available adapters:**

| Adapter | Import path | Notes |
|---|---|---|
| `MemoryAdapter` | `@fiskal/antifragile/adapters/memory` | Default. In-process. Full atomic op support. |
| `FirestoreAdapter` | `@fiskal/antifragile/adapters/firestore` | Real-time via `onSnapshot`. |
| `GunAdapter` | `@fiskal/antifragile/adapters/gun` | P2P decentralised. Offline-first. No server required. |
| `LocalStorageAdapter` | `@fiskal/antifragile/adapters/localStorage` | Browser `localStorage`. Cross-tab sync via `storage` event. |
| `CloudKitAdapter` | `@fiskal/antifragile/adapters/cloudkit` | iCloud/CloudKit. CKRecord subscriptions. (Swift only) |
| `NSUserDefaultsAdapter` | `@fiskal/antifragile/adapters/nsuserdefaults` | User preferences. Local persistence. No sync. (Swift only) |

---

### `createMutate`

Declares a named write as a plain data descriptor. Every write is synchronous against the in-memory cache (optimistic) and async against the backing store.

```ts
// Simple write
export const archiveTask = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    id,
    fields: { status: 'archived' },
    merge: true,
  }),
})

// Batch write — array of descriptors, executed as a transaction
export const archiveSprint = createMutate(store, {
  write: ({ sprintId, taskIds }: { sprintId: string; taskIds: string[] }) => [
    { id: sprintId, fields: { archived: true }, merge: true },
    ...taskIds.map(id => ({ id, fields: { archived: true }, merge: true })),
  ],
})

// Read-then-write — reads from the cache before writing
export const completeTask = createMutate(store, {
  read: ({ taskId, sprintId }: { taskId: string; sprintId: string }) => ({
    task:   { id: taskId },
    sprint: { id: sprintId },
  }),
  write: ({ task, sprint }: { task: any; sprint: any }) => ({
    id: task.id,
    fields: { status: 'done', sprintScore: sprint.pointsPerTask },
    merge: true,
  }),
})
```

**Calling a mutate:**

```ts
archiveTask({ id: 'tasks/task-1' })               // fire-and-forget
await archiveTask({ id: 'tasks/task-1' })          // await remote confirmation
archiveTask({ id: 'tasks/task-1' }).catch(onError) // handle failure explicitly
```

**Atomic field operations (`merge: true` only):**

| Operation | Syntax | Behaviour |
|---|---|---|
| Delete field | `{ fieldName: { __op: '::delete' } }` | Removes the field |
| Increment | `{ balance: { __op: '::increment', n: 50 } }` | Atomic numeric increment |
| Array union | `{ tags: { __op: '::arrayUnion', value: 'done' } }` | Add if not present |
| Array remove | `{ tags: { __op: '::arrayRemove', value: 'done' } }` | Remove from array |
| Server timestamp | `{ updatedAt: { __op: '::serverTimestamp' } }` | Server-assigned time at commit |

```ts
// Transfer funds — atomic transaction, both succeed or neither does
const transfer = createMutate(store, {
  write: ({ from, to, amount }: { from: string; to: string; amount: number }) => [
    { id: from, fields: { balance: { __op: '::increment', n: -amount } }, merge: true },
    { id: to,   fields: { balance: { __op: '::increment', n:  amount } }, merge: true },
  ],
})
```

**`merge: true` vs `merge: false`:**
- `merge: true` — partial update. Only the fields listed are changed. Fields not mentioned survive. Use for all updates.
- `merge: false` — full replacement. Drops all fields not in the write. Use only when creating a brand-new document.

---

### `createWireView` / `wireView`

`createWireView` returns a `wireView` factory bound to the store and its mutates. Call it once in `store.ts`. Use the returned `wireView` in all wiring files.

```ts
// store.ts
export const wireView = createWireView(store, { addTask, archiveTask })
```

**Signature:**

```ts
wireView(
  name: string,
  queries: QueryMap | ((ownProps: Props) => QueryMap),
  actionNames: string[],
  Component: React.ComponentType<Props>,
): React.ComponentType<OwnProps>
```

**Parameters:**

- `name` — registered name. Any other wired component with a prop of this name automatically receives the wired version injected.
- `queries` — static object or function of `ownProps → QueryMap`. Each key becomes a prop on the component. The value is a `Query`.
- `actionNames` — names of mutates to inject. Must match keys passed to `createWireView`.
- `Component` — the pure component to wire.

**Queries:**

```ts
// Single document by full-path id
{ task: { id: 'tasks/task-1' } }

// Single document — dynamic from ownProps
({ taskId }) => ({ task: { id: taskId } })

// Collection — all documents
{ tasks: { collection: 'tasks' } }

// Collection — filtered
{ taskIds: { collection: 'tasks', where: { status: 'active' } } }

// Collection — filtered + sorted
{ taskIds: { collection: 'tasks', where: { status: 'active' }, orderBy: { createdAt: 'desc' } } }

// Field narrowing — subscribe only to listed fields (reduces re-renders)
{ task: { id: 'tasks/task-1', fields: ['title', 'status'] } }

// Multiple queries in one wireView
({ taskId, sprintId }) => ({
  task:   { id: taskId },
  sprint: { id: sprintId, fields: ['totalItems', 'name'] },
})
```

**Query result contract:**
- `undefined` — loading (adapter has not yet responded)
- `null` — not found (adapter responded with empty)
- `Doc` — single document
- `Doc[]` — collection result

**Component injection:**

When `wireView('TaskItem', ...)` is registered, `WiredTaskItem` becomes available as `'TaskItem'` in the registry. Any component wired after this point that has a prop named `TaskItem` automatically receives `WiredTaskItem` injected. No explicit passing required.

```ts
// TaskList has a 'TaskItem' prop
const TaskList = ({ taskIds, TaskItem: Item }) => (
  <ul>{taskIds.map(({ id }) => <Item key={id} taskId={id} />)}</ul>
)

// WiredTaskList — TaskItem injected automatically from the registry
const WiredTaskList = wireView('TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },
  [],
  TaskList,
)
```

---

### `useRead` (internal; available directly for dynamic queries)

Used internally by `wireView`. Available directly when you need a dynamic query that cannot be expressed as a static `wireView` declaration. Avoid using inside component files — keep it in a wiring or effect layer.

```ts
import { useRead } from '@fiskal/antifragile'

// Single doc
const task = useRead({ id: 'tasks/task-1' })

// Narrowed fields
const titleOnly = useRead({ id: 'tasks/task-1', fields: ['title'] })

// Collection
const allTaskIds = useRead({ collection: 'tasks' })

// Filtered
const activeTasks = useRead({ collection: 'tasks', where: { status: 'active' } })

// Filtered + sorted + projected
const activeTaskTitles = useRead(
  { collection: 'tasks', where: { status: 'active' }, orderBy: { createdAt: 'desc' } },
  ['title', 'status'],
)
```

---

## 5. Patterns

### Modal / overlay without Context or portals

Portals exist to escape stacking contexts. Context exists to avoid prop drilling. Antifragile replaces both with the query system.

The key insight: a document id is a full path (`'tasks/task-1'`). Storing an id in `ui/modal/active` lets `WiredModalDetail` use it directly as a query — no type registry, no switch statement.

```ts
// store.ts
export const setModal = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    id: 'ui/modal/active',
    fields: { id },  // stores 'tasks/task-1' or 'sprints/sprint-A' — the full path
    merge: false,
  }),
})

export const closeModal = createMutate(store, {
  write: () => ({ id: 'ui/modal/active', delete: true }),
})
```

```tsx
// Any component deep in the tree — no context, no prop drilling
const TaskRow = ({ task, setModal }) => (
  <li onClick={() => setModal({ id: task.id })}>{task.title}</li>
)
const WiredTaskRow = wireView('TaskRow',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['setModal'],
  TaskRow,
)

// At the app root — ModalShell reads the stored id
const ModalShell = ({ active, closeModal }) =>
  active ? <WiredModalDetail activeId={active.id} closeModal={closeModal} /> : null

const WiredModalShell = wireView('ModalShell',
  { active: { id: 'ui/modal/active' } },
  ['closeModal'],
  ModalShell,
)

// ModalDetail uses the stored id as its own query — tasks and sprints work the same way
const ModalDetail = ({ item, closeModal }) => (
  <div>
    <button onClick={closeModal}>Close</button>
    <h2>{item.title ?? item.name}</h2>
  </div>
)

const WiredModalDetail = wireView('ModalDetail',
  ({ activeId }) => ({ item: { id: activeId } }),
  ['closeModal'],
  ModalDetail,
)
```

What this replaces: `ReactDOM.createPortal`, `React.createContext`, `useContext(ModalContext)`, type registries, switch statements on entity type.

---

### Errors as subscribable data

Never wrap mutate calls in try/catch. Write errors land in the `errors` collection. Subscribe to them from any component.

```ts
// store.ts
export const dismissError = createMutate(store, {
  write: ({ id }: { id: string }) => ({ id, fields: { resolved: true }, merge: true }),
})
```

```tsx
// ErrorBanner.tsx — zero library imports
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

// wires.ts
const WiredErrorBanner = wireView('ErrorBanner',
  { errors: { collection: 'errors', where: { resolved: false } } },
  ['dismissError'],
  ErrorBanner,
)
```

When a write fails, the store inserts `{ action, kind, message, payload, writes, at }` into `errors`. The banner re-renders automatically. No try/catch at the call site. No `isError` state in the component.

---

### Time travel

Every write is stored in an append-only log. Any past state is recoverable without re-running code.

```ts
store.history.back()         // roll back last write
store.history.forward()      // replay rolled-back write
store.history.goto(3)        // jump to any snapshot by index
store.history.log()

// Inspect what happened
// → [
//   { action: 'AddTask',     writes: [{ id: 'tasks/t1', fields: {...}, merge: false }], at: 1750000000 },
//   { action: 'ArchiveTask', writes: [{ id: 'tasks/t1', fields: { status: 'archived' }, merge: true }], at: 1750000060 },
// ]

// Detect and auto-recover from a known bad write
if (store.history.log().at(-1)?.action === 'KnownBadAction') {
  store.history.back()
}
```

**Time travel is in-memory only.** It rolls back the cache; it does not send compensating writes to the server. When the adapter syncs, the server's authoritative state overwrites the rolled-back cache. For persistent undo after sync, use a compensating write:

```ts
const lastEntry = store.history.log().at(-1)
if (lastEntry?.action === 'ArchiveTask') {
  await unarchiveTask({ id: lastEntry.writes[0].id })
}
```

---

### `ui/` prefix for ephemeral state

Any write to a path starting with `ui/` is routed to a local-only MemoryAdapter. It never reaches the remote adapter. A page refresh resets it.

```ts
// Form draft — write to ui/, not to the domain collection
const setDraft   = createMutate(store, {
  write: (fields: Record<string, unknown>) => ({
    id: 'ui/taskForm/draft', fields, merge: true,
  }),
})
const clearDraft = createMutate(store, {
  write: () => ({ id: 'ui/taskForm/draft', delete: true }),
})
const submitTask = createMutate(store, {
  write: (fields: Record<string, unknown>) => ({
    id: `tasks/${crypto.randomUUID()}`, fields, merge: false,
  }),
})

// On cancel: clearDraft() — no domain write, no AddTask in the history log
// On submit: submitTask(draft) then clearDraft()

// Tab / mode state
const setActiveTab = createMutate(store, {
  write: ({ tab }: { tab: string }) => ({
    id: 'ui/tabs/main', fields: { active: tab }, merge: true,
  }),
})
const WiredTabBar = wireView('TabBar',
  { tabs: { id: 'ui/tabs/main' } },
  ['setActiveTab'],
  TabBar,
)

// Clear all UI state on logout
store.clear('ui/')
```

---

### Field narrowing (reduce re-renders)

By default, subscribing to a document re-renders the component whenever any field on that document changes. Narrow the subscription to only the fields the component actually uses.

```ts
// Default — re-renders on any change to the task document
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

// Narrowed — re-renders only when title or status changes
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId, fields: ['title', 'status', 'createdAtDisplay'] } }),
  ['archiveTask'],
  TaskItem,
)
```

Start without narrowing (accurate, simple). Add `fields` narrowing only when profiling shows the re-render is measurably expensive. The component does not change — only the wireView query.

---

### Batch writes

Multiple writes in a single `createMutate` are executed as an atomic transaction against the backing store. If any write fails, none are applied.

```ts
const archiveSprint = createMutate(store, {
  write: ({ sprintId, taskIds }: { sprintId: string; taskIds: string[] }) => [
    { id: sprintId, fields: { archived: true, archivedAt: { __op: '::serverTimestamp' } }, merge: true },
    ...taskIds.map(taskId => ({ id: taskId, fields: { archived: true }, merge: true })),
  ],
})
```

---

### Offline write queue

The offline queue is built in. Writes issued while offline are queued in `store.history` and drained serially on reconnect — each write awaits confirmation before the next is sent.

```ts
// Works the same whether online or offline — the adapter manages the queue
archiveTask({ id: 'tasks/task-1' })
addTask({ id: `tasks/${crypto.randomUUID()}`, title: 'New task' })
```

Before going to background, persist the queue:

```ts
// iOS — call store.persist() in applicationDidEnterBackground
store.persist()

// On relaunch — re-hydrate and drain
store.rehydrate()
```

---

### Wizard cancel (multi-step rollback)

Snapshot the history index before the wizard starts. On cancel, `goto` restores the full cache synchronously.

```ts
// Before the wizard opens
const wizardStart = store.history.currentIndex()

// User fills 3 steps, each writing to ui/wizard/* or to the domain
// On cancel — restore cache to before the wizard; notifies all affected collections
store.history.goto(wizardStart)
```

---

### Schema migrations

Define `versioning` on the model. The store applies `rollforward` at read time — old documents are migrated transparently without touching storage.

```ts
const TaskModel = {
  schema: { /* ... */ },
  compute: { /* ... */ },
  versioning: [
    // Version 1 → 2: added required 'priority' field
    {
      partialSchema: { priority: { type: 'string', enum: ['high', 'medium', 'low'] } },
      rollforward: (doc: any) => ({ ...doc, priority: doc.priority ?? 'medium' }),
      rollback:    (doc: any) => { const { priority, ...rest } = doc; return rest },
    },
    // Version 2 → 3: renamed dueDate → due_at (rolling deployment)
    {
      rollforward: (doc: any) => doc.dueDate ? { ...doc, due_at: doc.dueDate } : doc,
      rollback:    (doc: any) => doc.due_at  ? { ...doc, dueDate: doc.due_at } : doc,
    },
  ],
}
```

Old data is never modified in storage by migration — only transformed at read time. During a rolling deployment, both field names coexist. Neither client gets `undefined`.

---

### Infinite scroll with a stable anchor

Store the scroll anchor (the id of the topmost visible item) in `ui/`. When new items insert at the top, the anchor is unchanged and the component renders from the same position — no visual jump.

```ts
const setAnchor = createMutate(store, {
  write: ({ anchorId }: { anchorId: string }) => ({
    id: 'ui/scrollList/view', fields: { anchorId }, merge: true,
  }),
})

const WiredTaskList = wireView('TaskList',
  {
    taskIds:  { collection: 'tasks', where: { status: 'active' }, orderBy: { createdAt: 'desc' } },
    listView: { id: 'ui/scrollList/view' },
  },
  ['setAnchor'],
  TaskList,
)

// Component — pure function of its props
const TaskList = ({ taskIds, listView, setAnchor }) => {
  const anchorIndex = taskIds.findIndex(({ id }) => id === listView?.anchorId)
  const startIndex  = anchorIndex >= 0 ? anchorIndex : 0
  // render from startIndex...
}
```

---

## 6. Anti-Patterns

### Do not import the library inside a component

```tsx
// WRONG — this breaks the zero-import rule
import { useRead, wireView } from '@fiskal/antifragile'

const TaskItem = ({ taskId }) => {
  const task = useRead({ id: taskId })   // ← data logic inside the component
  return <span>{task?.title}</span>
}

// CORRECT — the component has zero library imports
const TaskItem = ({ task }) => <span>{task.title}</span>

// wireView is outside, in wires.ts
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  [],
  TaskItem,
)
```

---

### Do not add `useState` for server data

```tsx
// WRONG
const TaskItem = ({ taskId }) => {
  const [task, setTask] = useState(null)
  useEffect(() => { fetchTask(taskId).then(setTask) }, [taskId])
  return <span>{task?.title}</span>
}

// CORRECT — task arrives as a prop; wireView owns the subscription lifecycle
const TaskItem = ({ task }) => <span>{task?.title}</span>
```

---

### Do not add `useEffect` for data concerns inside a component

```tsx
// WRONG — data concern inside a component
const TaskItem = ({ task, taskId }) => {
  useEffect(() => {
    store.subscribe({ id: taskId }, (updated) => { /* ... */ })
  }, [taskId])
  // ...
}

// CORRECT — wireView handles subscribe and cleanup
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  [],
  TaskItem,
)
```

The only `useEffect` that belongs in a component is for truly local, non-data concerns: animation timers, focus management, scroll position restoration.

---

### Do not destructure computers from documents

```tsx
// WRONG — 'this' is undefined in strict mode
const TaskItem = ({ task, sprint }) => {
  const { completionPercent } = task  // ← destructuring loses 'this' binding
  return <span>{completionPercent(sprint)}%</span>
}

// CORRECT — call as a method on the document
const TaskItem = ({ task, sprint }) => (
  <span>{task.completionPercent(sprint)}%</span>
)
```

---

### Do not create a second store for a new feature

```ts
// WRONG — two stores cannot cross-query; history is siloed
// notifications/store.ts
export const notificationsStore = createStore(MemoryAdapter())
export const wireView = createWireView(notificationsStore, { ... })

// CORRECT — add to the existing store
// store.ts
export const store = createStore(
  MemoryAdapter({ tasks: [...], notifications: [...] }),
  { models: { tasks: TaskModel, notifications: NotificationModel } },
)
```

---

### Do not use `merge: false` for updates

```ts
// WRONG — drops server-added fields (completedAt, assignee, updatedBy)
write: ({ id, title }) => ({ id, fields: { title }, merge: false })

// CORRECT
write: ({ id, title }) => ({ id, fields: { title }, merge: true })

// merge: false is only correct when creating a brand-new document
write: ({ id, title }) => ({ id, fields: { title, status: 'active', createdAt: Date.now() }, merge: false })
```

---

### Do not use local IDs in seed data or writes

```ts
// WRONG — query { id: 'tasks/task-1' } will return null
MemoryAdapter({ tasks: [{ id: 'task-1', title: '...' }] })

// CORRECT
MemoryAdapter({ tasks: [{ id: 'tasks/task-1', title: '...' }] })
```

---

### Do not use `useContext` or `React.createContext` for shared state

```tsx
// WRONG — Context re-renders all consumers when the value changes
const ModalContext = createContext(null)
const TaskRow = () => {
  const { setModal } = useContext(ModalContext)
  // ...
}

// CORRECT — inject setModal as an action via wireView
const WiredTaskRow = wireView('TaskRow',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['setModal'],  // injected as a prop — no Context, no Provider
  TaskRow,
)
```

---

### Do not use `useMemo` or `useCallback` for store data

```tsx
// WRONG — the filter belongs in the query, not the component
const TaskList = ({ tasks }) => {
  const activeTasks = useMemo(() => tasks.filter(t => t.status === 'active'), [tasks])
  // ...
}

// CORRECT — filter in the query; the component receives the already-filtered list
const WiredTaskList = wireView('TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },
  [],
  TaskList,
)
const TaskList = ({ taskIds }) => /* render taskIds directly */
```

---

## 7. TypeScript API

### Complete store setup

```ts
// store.ts
import { createStore, createMutate, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

const TaskModel = {
  schema: {
    type: 'object' as const,
    properties: {
      id:        { type: 'string' as const },
      title:     { type: 'string' as const, minLength: 1 },
      status:    { type: 'string' as const, enum: ['active', 'archived'] },
      createdAt: { type: 'number' as const },
    },
    required: ['id', 'title', 'status', 'createdAt'],
  },
  compute: {
    get createdAtDisplay(this: { createdAt: number }) {
      return new Date(this.createdAt).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      })
    },
    get statusLabel(this: { status: string }) {
      return this.status === 'active' ? 'In Progress' : 'Archived'
    },
    isAssignedTo(this: { assigneeId: string }, user: { id: string }) {
      return this.assigneeId === user.id
    },
  },
}

export const store = createStore(
  MemoryAdapter({
    tasks: [
      { id: 'tasks/task-1', title: 'Deploy to production', status: 'active', createdAt: Date.now() - 86_400_000 },
    ],
  }),
  { models: { tasks: TaskModel } },
)

export const addTask = createMutate(store, {
  write: ({ id, title }: { id: string; title: string }) => ({
    id,
    fields: { title, status: 'active', createdAt: Date.now() },
    merge: false,
  }),
})

export const archiveTask = createMutate(store, {
  write: ({ id }: { id: string }) => ({
    id,
    fields: { status: 'archived' },
    merge: true,
  }),
})

export const wireView = createWireView(store, { addTask, archiveTask })
```

### Pure component

```tsx
// TaskItem.tsx — zero library imports
export type Task = {
  id: string
  title: string
  status: 'active' | 'archived'
  createdAt: number
  createdAtDisplay: string  // added by model compute
  statusLabel: string       // added by model compute
}

type Props = {
  task: Task | undefined | null
  archiveTask: (payload: { id: string }) => void
}

export const TaskItem = ({ task, archiveTask }: Props) => {
  if (task === undefined) return <li>Loading...</li>
  if (task === null) return <li>Not found.</li>
  return (
    <li>
      <span>{task.title}</span>
      <span>{task.createdAtDisplay}</span>
      <span>{task.statusLabel}</span>
      <button onClick={() => archiveTask({ id: task.id })}>Archive</button>
    </li>
  )
}
```

### Wires

```ts
// wires.ts
import { wireView } from './store'
import { TaskItem } from './TaskItem'
import { TaskList } from './TaskList'

export const WiredTaskItem = wireView(
  'TaskItem',
  ({ taskId }: { taskId: string }) => ({ task: { id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

export const WiredTaskList = wireView(
  'TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },
  ['addTask'],
  TaskList,
  // WiredTaskItem injected into TaskList's TaskItem prop automatically
)
```

### Testing

```ts
import { createTestStore, seed, reset, resolveWrites } from '@fiskal/antifragile/test'
import { render, screen } from '@testing-library/react'
import { TaskItem } from './TaskItem'
import { addTask, archiveTask } from './store'

// Component tests — no store, no Provider, plain props
test('renders task title', () => {
  render(
    <TaskItem
      task={{ id: 'tasks/t1', title: 'Deploy', status: 'active', createdAt: 0, createdAtDisplay: 'Jan 1, 2026', statusLabel: 'In Progress' }}
      archiveTask={vi.fn()}
    />
  )
  expect(screen.getByText('Deploy')).toBeInTheDocument()
})

// Mutate tests — assert on plain data, no component mounting
test('addTask writes correct descriptor', async () => {
  const writes = await resolveWrites(addTask, { id: 'tasks/task-3', title: 'New task' })
  expect(writes).toEqual([{
    id: 'tasks/task-3',
    fields: { title: 'New task', status: 'active', createdAt: expect.any(Number) },
    merge: false,
  }])
})

test('archiveTask merges status', async () => {
  const writes = await resolveWrites(archiveTask, { id: 'tasks/task-1' })
  expect(writes).toEqual([{
    id: 'tasks/task-1',
    fields: { status: 'archived' },
    merge: true,
  }])
})

// Store integration tests
const testStore = createTestStore()

beforeEach(() => seed(testStore, {
  tasks: [{ id: 'tasks/task-1', title: 'Deploy', status: 'active', createdAt: 0 }],
}))
afterEach(() => reset(testStore))

test('store subscription delivers updated document', async () => {
  let result: any = undefined
  testStore.subscribe({ id: 'tasks/task-1' }, (docs) => { result = docs[0] })
  await archiveTask({ id: 'tasks/task-1' })
  expect(result?.status).toBe('archived')
})
```

---

## 8. Swift API

### Store setup (`Store.swift`)

```swift
import Antifragile

// Mutates — defined as functions that return Write descriptors
let addTask = createMutate(action: "AddTask") { (payload: [String: Any]) -> [Write] in
  guard
    let id    = payload["id"]    as? String,
    let title = payload["title"] as? String
  else { return [] }
  return [Write(
    id: id,           // full path: 'tasks/task-1'
    fields: ["title": title, "status": "active", "createdAt": Date().timeIntervalSince1970],
    merge: false
  )]
}

let archiveTask = createMutate(action: "ArchiveTask") { (payload: [String: Any]) -> [Write] in
  guard let id = payload["id"] as? String else { return [] }
  return [Write(id: id, fields: ["status": "archived"], merge: true)]
}

// Store — one per app
let store = Store.createStore {
  BackingStoreConfig(
    name: "default",
    adapter: MemoryAdapter(initial: [
      "tasks": [
        "tasks/task-1": ["id": "tasks/task-1", "title": "Deploy to production", "status": "active",
                         "createdAt": Date().timeIntervalSince1970 - 86_400],
        "tasks/task-2": ["id": "tasks/task-2", "title": "Write release notes", "status": "active",
                         "createdAt": Date().timeIntervalSince1970 - 3_600],
      ],
    ]),
    mutates: [addTask, archiveTask]
  )
}
```

### Pure view (`TaskItem.swift`)

Zero Antifragile imports. A plain Swift struct.

```swift
import SwiftUI

// Doc is [String: Any] — all documents are plain dictionaries
struct Task {
  let id: String
  let title: String
  let status: String
  let createdAt: TimeInterval

  var createdAtDisplay: String {
    Date(timeIntervalSince1970: createdAt)
      .formatted(.dateTime.month(.abbreviated).day().year())
  }
  var statusLabel: String { status == "active" ? "In Progress" : "Archived" }
  var isOverdue: Bool { false }  // placeholder — depends on dueDate if present

  static func from(_ doc: [String: Any]) -> Task? {
    guard
      let id        = doc["id"]        as? String,
      let title     = doc["title"]     as? String,
      let status    = doc["status"]    as? String,
      let createdAt = doc["createdAt"] as? TimeInterval
    else { return nil }
    return Task(id: id, title: title, status: status, createdAt: createdAt)
  }
}

struct TaskItem: View {
  let task: Task
  let archiveTask: ([String: Any]) -> Void

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(task.title)
        Text(task.createdAtDisplay).font(.caption).foregroundStyle(.secondary)
        Text(task.statusLabel).font(.caption2)
      }
      Spacer()
      Button("Archive") {
        archiveTask(["id": task.id])
      }
    }
  }
}
```

### Wired view (`WiredTaskItem.swift`)

```swift
import SwiftUI
import Antifragile

struct WiredTaskItem: View {
  let taskId: String

  var body: some View {
    wireView(
      name: "TaskItem",
      queries: ["task": ["id": taskId]],  // taskId = "tasks/task-1"
      actions: ["archiveTask"]
    ) { props in
      guard
        let taskData = props.data["task"] as? [String: Any],
        let task     = Task.from(taskData)
      else { return AnyView(ProgressView()) }

      return AnyView(TaskItem(
        task: task,
        archiveTask: { payload in
          Task { try? await props.actions["archiveTask"]?(payload) }
        }
      ))
    }
  }
}

struct WiredTaskList: View {
  var body: some View {
    wireView(
      name: "TaskList",
      queries: ["taskIds": ["collection": "tasks", "where": [["field": "status", "op": "==", "value": "active"]]]],
      actions: []
    ) { props in
      let ids = (props.data["taskIds"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
      return AnyView(
        List(ids, id: \.self) { id in WiredTaskItem(taskId: id) }
      )
    }
  }
}
```

### App entry point

```swift
import SwiftUI
import Antifragile

@main
struct MyApp: App {
  var body: some Scene {
    WindowGroup {
      WiredTaskList()
        .environment(store)
    }
  }
}
```

### Testing (Swift)

```swift
import XCTest
import Antifragile
@testable import MyApp

class TaskTests: XCTestCase {
  override func setUp() {
    store.seed([
      "tasks": ["tasks/task-1": ["id": "tasks/task-1", "title": "Deploy", "status": "active", "createdAt": 0.0]],
    ])
  }
  override func tearDown() { store.reset() }

  // Component test — plain struct init, no environment required
  func testTaskItemRendersTitle() {
    let task = Task(id: "tasks/task-1", title: "Deploy", status: "active", createdAt: 0)
    let view = TaskItem(task: task, archiveTask: { _ in })
    // Use ViewInspector or snapshot testing to assert on 'view'
    XCTAssertEqual(task.statusLabel, "In Progress")
    XCTAssertFalse(task.isOverdue)
  }

  // Mutate test — assert on Write descriptors, no UI required
  func testArchiveTaskWritesDescriptor() async throws {
    let writes = try await resolveWrites(archiveTask, ["id": "tasks/task-1"])
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes[0].id, "tasks/task-1")
    XCTAssertEqual(writes[0].fields["status"] as? String, "archived")
    XCTAssertEqual(writes[0].merge, true)
  }
}
```

---

## 9. Migration Guides

### From Redux / RTK

**The fundamental shift:** Redux is a global state tree with reducers and selectors. RTK adds ergonomic wrappers but the core model is unchanged. Antifragile removes the global tree — subscriptions are per-document, so selectors are unnecessary.

**Step 1: Replace `createSlice` with `createMutate` pairs**

```ts
// Redux RTK — before
const tasksSlice = createSlice({
  name: 'tasks',
  initialState: [] as Task[],
  reducers: {
    taskAdded:    (state, action) => { state.push(action.payload) },
    taskArchived: (state, action) => {
      const t = state.find(t => t.id === action.payload.id)
      if (t) t.status = 'archived'
    },
  },
})
export const { taskAdded, taskArchived } = tasksSlice.actions

// Antifragile — after
export const addTask = createMutate(store, {
  write: ({ id, title }) => ({
    id, fields: { title, status: 'active', createdAt: Date.now() }, merge: false,
  }),
})
export const archiveTask = createMutate(store, {
  write: ({ id }) => ({ id, fields: { status: 'archived' }, merge: true }),
})
```

**Step 2: Replace `useSelector` + `createSelector` with wireView queries**

```ts
// Redux RTK — before (inside the component file)
import { useSelector } from 'react-redux'
const TaskItem = ({ taskId }) => {
  const task = useSelector(selectTaskById(taskId))
  return <li>{task.title}</li>
}

// Antifragile — after (wireView is outside the component file)
// TaskItem.tsx — no library imports:
const TaskItem = ({ task, archiveTask }) => <li onClick={() => archiveTask({ id: task.id })}>{task.title}</li>

// wires.ts:
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['archiveTask'],
  TaskItem,
)
```

**Step 3: Replace `createSelector` with model compute getters**

```ts
// Redux RTK — before
const selectTaskDisplayDate = createSelector(
  selectTaskById,
  task => new Date(task.createdAt).toLocaleDateString()
)

// Antifragile — after (in model definition)
const TaskModel = {
  compute: {
    get createdAtDisplay() {
      return new Date(this.createdAt).toLocaleDateString()
    },
  },
}
// Component uses task.createdAtDisplay — no selector, no import
```

**Step 4: Replace dispatch error handling with the `errors` collection**

```ts
// Redux RTK — before
try {
  await dispatch(archiveTask(id)).unwrap()
} catch (err) {
  setLocalError(err.message)
}

// Antifragile — after (no try/catch at the call site)
archiveTask({ id: task.id })  // fire-and-forget

const WiredErrorBanner = wireView('ErrorBanner',
  { errors: { collection: 'errors', where: { resolved: false } } },
  ['dismissError'],
  ErrorBanner,
)
```

**Why RTK selectors carry so much weight:** A Redux selector must know the entire state tree shape to navigate to the value: `state => state.tasks.items[id].title`. When the state shape changes, selectors break. Antifragile's query is a data descriptor: `{ id: taskId, fields: ['title'] }`. The store resolves it. The component never knows or cares how the store is structured.

---

### From TanStack Query

TanStack is designed for HTTP: `queryKey` maps to a URL, `queryFn` fetches it. Migrate when you need real-time, offline queue, or shared TypeScript/Swift state. For pure REST APIs with no real-time requirement, TanStack remains the right tool.

```ts
// TanStack Query — before (inside the component)
const { data: task, isLoading } = useQuery({
  queryKey: ['tasks', taskId],
  queryFn: () => fetch(`/api/tasks/${taskId}`).then(r => r.json()),
})

const { mutate: archive } = useMutation({
  mutationFn: (id) => fetch(`/api/tasks/${id}/archive`, { method: 'POST' }),
  onSuccess: () => queryClient.invalidateQueries(['tasks']),
})

if (isLoading) return <Spinner />
return <TaskItem task={task} onArchive={archive} />

// Antifragile — after
// Component file (zero imports):
const TaskItem = ({ task, archiveTask }) => {
  if (task === undefined) return <Spinner />
  if (task === null) return <NotFound />
  return (
    <li>
      <span>{task.title}</span>
      <button onClick={() => archiveTask({ id: task.id })}>Archive</button>
    </li>
  )
}

// wires.ts:
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['archiveTask'],
  TaskItem,
)
```

**Manual invalidation vs automatic subscriptions:** Every TanStack mutation requires `queryClient.invalidateQueries(key)`. Miss one, and the cache shows stale data indefinitely. Antifragile's real-time subscriptions never need manual invalidation — they stay open and fire automatically when the underlying data changes.

---

### From Zustand

Zustand stores are objects with `get`/`set`/`subscribe`. Replace stores with collections, and replace setters with mutates.

```ts
// Zustand — before
const useTaskStore = create<TaskStore>((set) => ({
  tasks: [] as Task[],
  addTask:    (task)  => set(state => ({ tasks: [...state.tasks, task] })),
  removeTask: (id)    => set(state => ({ tasks: state.tasks.filter(t => t.id !== id) })),
  archiveTask:(id)    => set(state => ({
    tasks: state.tasks.map(t => t.id === id ? { ...t, status: 'archived' } : t)
  })),
}))

// In component — Zustand requires import inside the component
const { tasks, addTask } = useTaskStore()

// Antifragile — after
export const addTask = createMutate(store, {
  write: (task: Task) => ({ id: task.id, fields: task, merge: false }),
})
export const removeTask = createMutate(store, {
  write: ({ id }: { id: string }) => ({ id, delete: true }),
})
export const archiveTask = createMutate(store, {
  write: ({ id }: { id: string }) => ({ id, fields: { status: 'archived' }, merge: true }),
})

// Component receives tasks and addTask as plain props via wireView — no store import
```

---

### From Jotai

Jotai atoms are fine-grained pieces of state. The nearest Antifragile equivalents: `ui/` path documents for ephemeral state, collection documents for persistent state.

```ts
// Jotai — before
const tabAtom   = atom('daily')
const filterAtom= atom('')
const tasksAtom = atom(async (get) => {
  const filter = get(filterAtom)
  return fetchTasks({ filter })
})

// Antifragile — after (ui/ for ephemeral, collection for persistent)
export const setActiveTab = createMutate(store, {
  write: ({ tab }: { tab: string }) => ({
    id: 'ui/tabs/main', fields: { active: tab }, merge: true,
  }),
})
export const setFilter = createMutate(store, {
  write: ({ filter }: { filter: string }) => ({
    id: 'ui/filter/tasks', fields: { value: filter }, merge: true,
  }),
})

// wireView reads both tab state and tasks in one declaration
const WiredTaskList = wireView('TaskList',
  {
    taskIds: { collection: 'tasks', where: { status: 'active' } },
    tabView: { id: 'ui/tabs/main' },
    filter:  { id: 'ui/filter/tasks' },
  },
  ['setActiveTab', 'setFilter'],
  TaskList,
)
```

---

### From Swift TCA (The Composable Architecture)

TCA and Antifragile share the same FP philosophy: reducers as pure functions, effects at the edge. TCA is more rigidly structured and type-safe. Antifragile trades some of that rigidity for cross-platform parity and adapter swap.

| Concern | TCA | Antifragile |
|---|---|---|
| State shape | Strongly typed struct | `Doc = [String: Any]` (untyped) |
| Actions | Enum cases with associated values | String name + `[String: Any]` payload |
| Effects | `Effect<Action>` — explicit type | adapter `write` + `subscribe` — implicit |
| Scoping | `Scope` reducer | separate backing store config per domain |
| Dev tools | Point-Free Viewer (excellent) | `store.history.log()` (basic) |
| Cross-platform | Swift only | Swift + TypeScript (shared model) |

```swift
// TCA — before
struct TaskFeature: Reducer {
  struct State: Equatable { var tasks: IdentifiedArrayOf<Task> = [] }
  enum Action { case archiveTask(id: Task.ID) }
  func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .archiveTask(let id):
      state.tasks[id: id]?.status = .archived
      return .none
    }
  }
}

// Antifragile — after
let archiveTask = createMutate(action: "ArchiveTask") { payload in
  guard let id = payload["id"] as? String else { return [] }
  return [Write(id: id, fields: ["status": "archived"], merge: true)]
}
```

---

### From SwiftData

SwiftData is correct for pure Apple-platform apps with CloudKit sync and no TypeScript parity requirement. Migrate when you need a write log, offline queue, or shared TypeScript models.

```swift
// SwiftData — before
@Model class Task {
  var title: String
  var status: String
  init(title: String) { self.title = title; self.status = "active" }
}
@Query(filter: #Predicate<Task> { $0.status == "active" }) var tasks: [Task]

// Antifragile — after
// Queries work the same whether the adapter is MemoryAdapter, CloudKitAdapter, or anything else
let WiredTaskList = wireView(
  name: "TaskList",
  queries: ["taskIds": ["collection": "tasks", "where": [["field": "status", "op": "==", "value": "active"]]]],
  actions: [],
  view: TaskList.init
)
```

---

## 10. Architecture

### The cache

The in-memory cache is a flat, normalised entity table using immutable data with structural sharing. When a document changes, only that document's node is replaced — every other node keeps its exact reference.

```
write tasks/task-1.status → cache
                             ├── tasks
                             │   ├── tasks/task-1  ← new reference (changed)
                             │   └── tasks/task-2  ← same reference (unchanged)
                             └── sprints
                                 └── ...           ← same reference (unchanged)
```

Components subscribed to `tasks/task-2` and all sprint documents never re-render.

### Write flow

1. `createMutate` resolves the write descriptor (synchronous).
2. The optimistic update applies to the cache immediately.
3. All subscribers for affected collections are notified synchronously.
4. Components re-render.
5. The write descriptor is queued for the adapter.
6. The adapter flushes the write asynchronously.
7. If the server returns enriched data, the adapter's `subscribe` stream fires again with the authoritative record — a second targeted re-render reconciles any differences.
8. If the write fails, the cache is restored to the pre-write snapshot and affected subscribers are notified.

### Subscriptions

Each `wireView` registers a subscription per query in the adapter. Subscriptions fire when:
- The adapter delivers a changed document (real-time push from the server)
- A local write touches a document in the subscribed collection

The cleanup function is returned from the adapter's `subscribe` call. `wireView`'s internal `useEffect` (TypeScript) or `onDisappear` (Swift) calls it on unmount. After 10 navigate-away/back cycles: exactly one active subscriber per query.

### Enrichment

When a document leaves the cache on its way to a subscriber, the store applies the model's `compute` descriptors via `Object.defineProperties` (TypeScript) or protocol extensions (Swift). Getters run at read time — not at write time. The raw document in the cache is never mutated. The enriched copy is ephemeral — created per read.

### Adapter protocol

An adapter connects a backing store to the in-memory cache. It implements two methods:

```ts
interface Adapter {
  subscribe(query: Query, onChange: (docs: Doc[]) => void): () => void
  write(operation: Write | Write[]): Promise<void>
}

// Example custom adapter
export function MyAdapter(client: MyClient): Adapter {
  return {
    subscribe(query, onChange) {
      const cancel = client.watch(toNativeQuery(query), docs => onChange(docs))
      return cancel
    },
    async write(operation) {
      await client.commit(toNativeWrite(operation))
    },
  }
}
```

The adapter never touches the in-memory cache. It delivers documents via `onChange` and confirms writes. The store owns the cache, the optimistic update, and the rollback.

```swift
protocol Adapter {
  func subscribe(query: Query, onChange: @escaping ([Doc]) -> Void) -> () -> Void
  func write(operation: WriteOperation) async throws
}
```

### Path-based routing

When `createStore` is configured with multiple backing stores, write dispatch inspects the `id` prefix:

```
write { id: 'tasks/task-1', ... }     → routes to 'default' adapter (Firestore)
write { id: 'ui/modal/active', ... }  → routes to 'ui' adapter (MemoryAdapter)
write { id: 'prefs/theme', ... }      → routes to 'defaults' adapter (NSUserDefaults)
```

The routing is structural. No flag on the write, no check in the component. A `ui/` write cannot reach the Firestore adapter — the path prefix is the enforcement mechanism.

### History and snapshots

Every write produces a snapshot — a cheap pointer to the immutable cache tree at that moment. Snapshots form the write log that powers time travel. Because they use structural sharing, the entire log costs only the memory of what actually changed, not a full copy per write.

Restoring a snapshot is O(1): replace the current cache pointer, then notify the collections that changed between the current and target snapshot.

---

## 11. Known Limits

These are honest limitations — not to be worked around with clever patterns until the ADR for each one ships.

### No SSR dehydrate/hydrate

Next.js server rendering starts with an empty MemoryAdapter. First renders always show loading state on the server. `window.localStorage` is undefined in the Node environment. There is no `dehydrate`/`hydrate` equivalent yet. For SSR-critical apps, this is a blocking gap.

### No `limit` / cursor in queries

The current `QuerySpec` has no `limit`, `cursor`, `startAfter`, or `endBefore`. A collection query returns all documents. For collections larger than a few thousand items, this is not viable. Workaround: partition into separate ranges by date or category. Proper cursor support is a planned ADR.

### No real-time collaborative text editing

The conflict model is last-write-wins. Two clients editing the same text field simultaneously lose one write — silently. There is no CRDT primitive. This is acceptable for task titles, amounts, and most user-facing fields. It is not acceptable for shared document editing (Google Docs-style). The GunAdapter provides CRDT semantics at the Gun/SEA layer, but the library itself has no CRDT support.

### Time travel is in-memory only

`store.history.back()` and `store.history.goto(n)` restore the in-memory cache. They do not send compensating writes to the server. When the adapter syncs, the server's current state overwrites the rolled-back cache. Time travel is for debugging and wizard-cancel patterns. It is not a general-purpose undo system for synced data. Use a compensating write for persistent undo.

### No DevTools browser extension

There is no Redux DevTools equivalent. Use `store.history.log()` to inspect the write sequence. The log is serialisable — ship it to a server on error and replay it locally.

### `wireView` query results are untyped

The TypeScript bridge between `wireView`'s query map and the component's prop types is not compiler-enforced. `wireView` delivers `Doc | Doc[] | null`. The component receives props typed by its own type signature. A mismatch (querying `tasks`, receiving result as a `Sprint` in the component type) is not a compile error. Assert types explicitly when the distinction matters.

### Schema validation is declared but not yet enforced at write time

`Model.schema` (JSON Schema) is registered but no validation runs at `createMutate` write time in the current implementation. An incorrect write (e.g., `{ title: 42 }` when `title` is `string`) is accepted silently. Enforcement is a planned ADR. Do not rely on runtime validation catching type errors before this ships.

### No PII redaction in the history log

`store.history.log()` contains the full `fields` payload of every write. If a write contains a password, API key, or sensitive field, it is in the log. Before shipping the log to an error-reporting server, strip sensitive fields manually. Built-in redaction configuration is a planned ADR.

### Single store — no multi-tenant or per-tab isolation

One store per app. If a tab-based UI needs fully independent state per tab, or a multi-tenant app needs isolated data per tenant, there is no built-in mechanism. Multiple store instances work but `wireView` factories cannot cross-inject across stores.

### No middleware ecosystem

There is no equivalent of redux-saga, redux-observable, or redux-thunk. Reactions to writes ("when a task is archived, notify the sprint") must happen in the mutate's write array, on the server, or in a separate mutate called explicitly. This is intentional — side effects at the adapter boundary only. Some patterns natural in Redux require being made explicit here.

### LocalStorageAdapter: cross-tab sync requires the `storage` event listener

If you use `LocalStorageAdapter`, verify the adapter version includes a `window.storage` event listener. Without it, two open browser tabs have separate caches and diverge silently on writes from either tab.

---

*Antifragile is in active development. The API is stable at the described surface; internals are subject to change.*
