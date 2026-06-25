# fiskal-antifragile

**Anti-fragile apps. No assumptions when something breaks.**

State management for React and SwiftUI where every write is a named, serializable descriptor — so the complete action log is always available: shippable to a server on failure, replayable without a repro case. Components have zero imports from the library. All wiring is declared outside components, making it structurally impossible to mix logic into UI.

---

## Quick start

```tsx
import { wireView } from './store.js'

// Pure components — zero library imports, tested with plain props
const TaskItem = ({ task, archiveTask }) => (
  <li>
    <span>{task.title}</span>
    <span>{task.createdAtDisplay}</span>
    <button onClick={() => archiveTask({ id: task.id })}>Archive</button>
  </li>
)

// TaskItem injected as a prop — wireView provides the wired version at runtime
const TaskList = ({ taskIds, TaskItem: Item }) => (
  <ul>{taskIds.map(({ id }) => <Item key={id} taskId={id} />)}</ul>
)

// Wires — outside the component files. All connection logic lives here.
// id is always the full path: 'tasks/task-1'. No collection field needed for single-doc queries.
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),   // taskId = 'tasks/task-1'
  ['archiveTask'],
  TaskItem,
)

const WiredTaskList = wireView('TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },  // collection needed for where queries
  [],
  TaskList,
)

// --- store.ts
import { createStore, createMutate, createWireView } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

// Model — JSON schema + compute formatters
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
    get createdAtDisplay() {
      return new Date(this.createdAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
    },
    get statusLabel() { return this.status === 'active' ? 'In Progress' : 'Archived' },
  },
}

// Seed data: id is always the full path — 'tasks/task-1', not just 'task-1'
export const store = createStore(MemoryAdapter({
  tasks: [
    { id: 'tasks/task-1', title: 'Deploy to production', status: 'active', createdAt: Date.now() - 86_400_000 },
    { id: 'tasks/task-2', title: 'Write release notes',  status: 'active', createdAt: Date.now() - 3_600_000  },
  ],
}))

// id is the full path: 'tasks/task-3'. The store parses the collection from the prefix.
export const addTask = createMutate(store, {
  write: ({ id, title }) => ({ id, fields: { title, status: 'active', createdAt: Date.now() }, merge: false }),
})

export const archiveTask = createMutate(store, {
  write: ({ id }) => ({ id, fields: { status: 'archived' }, merge: true }),
})

export const wireView = createWireView(store, { addTask, archiveTask })

// On failure — the full log is always there.
store.history.log()
// → [{ action: 'AddTask', ... }, { action: 'ArchiveTask', ... }]
store.history.back()
```

```swift
import SwiftUI
import Antifragile

// Pure views — no store, no @EnvironmentObject
struct TaskItem: View {
  let task: Task
  let archiveTask: ([String: Any]) -> Void
  var body: some View {
    VStack(alignment: .leading) {
      Text(task.title)
      Text(task.createdAtDisplay).font(.caption).foregroundStyle(.secondary)
    }
    Button("Archive") { archiveTask(["id": task.id]) }
  }
}

struct TaskList<Item: View>: View {
  let taskIds: [String]
  var TaskItem: (String) -> Item      // injected by wireView
  var body: some View {
    List(taskIds, id: \.self) { id in TaskItem(id) }
  }
}

// Wires — outside the view files. wireView uses Combine + @Observable under the covers.
struct WiredTaskItem: View {
  let taskId: String
  var body: some View {
    wireView(name: "TaskItem",
             queries: ["task": ["path": "tasks", "id": taskId]],
             actions: ["archiveTask"]) { props in
      AnyView(TaskItem(
        task: Task.from(props.data)!,
        archiveTask: { payload in Task { try? await props.actions["archiveTask"]?(payload) } }
      ))
    }
  }
}

struct WiredTaskList: View {
  var body: some View {
    wireView(name: "TaskList",
             queries: ["taskIds": ["path": "tasks", "where": [["field": "status", "op": "==", "value": "active"]]]],
             actions: []) { props in
      let ids = (props.data["taskIds"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
      return AnyView(TaskList(taskIds: ids) { id in WiredTaskItem(taskId: id) })
    }
  }
}

// --- Store.swift
let addTask = createMutate(action: "AddTask") { payload in
  guard let id = payload["id"] as? String, let title = payload["title"] as? String else { return [] }
  return [Write(path: "tasks", id: id, fields: ["title": title, "status": "active", "createdAt": Date().timeIntervalSince1970])]
}

let archiveTask = createMutate(action: "ArchiveTask") { payload in
  guard let id = payload["id"] as? String else { return [] }
  return [Write(path: "tasks", id: id, fields: ["status": "archived"])]
}

let store = Store.createStore {
  BackingStoreConfig(
    name: "default",
    adapter: MemoryAdapter(initial: [
      "tasks": [
        "task-1": ["id": "task-1", "title": "Deploy to production", "status": "active", "createdAt": Date().timeIntervalSince1970 - 86_400],
        "task-2": ["id": "task-2", "title": "Write release notes",  "status": "active", "createdAt": Date().timeIntervalSince1970 - 3_600],
      ],
    ]),
    mutates: [addTask, archiveTask]
  )
}

store.history.log()   // → [HistoryEntry]
store.history.back()
```

---

## Why

### The debugging problem

Apps break in ways that are hard to reproduce. Crash reporters show what broke — not what the user was doing. The full sequence of state changes that led to the failure is gone because writes are function calls: opaque, un-serializable, lost the moment they run.

fiskal-antifragile makes every write a named data descriptor. The log is always there. When something breaks you have the exact sequence that caused it, not a stack trace and a guess. Ship the log to a server on error. Replay the exact sequence on your machine. Fix the bug. The same failure never reaches a user twice.

```ts
store.history.log()
// → [
//   { action: 'AddTask',     writes: [{ collection: 'tasks', id: 't1', fields: { title: 'Deploy' } }], at: 1750000000 },
//   { action: 'ArchiveTask', writes: [{ collection: 'tasks', id: 't1', fields: { status: 'archived' } }],  at: 1750000060 },
// ]
```

### The architecture problem

The most common source of bugs in AI agent-generated code is logic drifting into views. Agents write the first draft fast and architecturally naively — they add `useEffect` chains, reach for context inside components, blur the boundary between data and render. No lint rule reliably fixes this; the boundary needs to be structural.

fiskal-antifragile makes the wrong code impossible: components never import the library, so there is no store API available inside a component file. Agents and developers physically cannot mix concerns.

```ts
// This is the ONLY way to connect a component to the store.
// It lives outside the component file. The component itself has zero library imports.
wireView('TaskItem',
  ({ taskId }) => ({ task: { collection: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)
```

---

## The five primitives

| Primitive | What it does |
|---|---|
| `Model` | JSON Schema + compute getters + migration history for an entity. |
| `createStore` | One store per app. Registers the adapter and mutates. |
| `createMutate` | Declares a named write as a plain data descriptor. |
| `createWireView` | Returns a `wireView` factory bound to the store and its mutates. |
| `Adapter` | Protocol: `subscribe` + `write`. Swap MemoryAdapter → Firestore/CloudKit/GunJS in one line. |

---

## Anti-fragile

Standard observability tells you what broke. Anti-fragile means each failure makes the system stronger:

1. Failure occurs → action log + snapshot ship to server automatically
2. Engineer replays the exact write sequence → root cause found without guessing
3. Fix deployed
4. Same failure detected at runtime → `store.history.back()` restores from pre-failure snapshot
5. The failure never reaches the user again

```ts
if (store.history.current?.action === 'KnownBadAction') {
  store.history.back()
}
```

---

## Model

Defines the schema, virtual computed fields, and formatting for an entity. The most common use: a `createdAt` timestamp stored as a number, formatted as a readable date for the UI.

```ts
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
    // Getter — derives from own fields; read as a plain value in the component
    get createdAtDisplay() {
      return new Date(this.createdAt).toLocaleDateString(undefined, {
        month: 'short', day: 'numeric', year: 'numeric',
      })
    },
    get statusLabel() { return this.status === 'active' ? 'In Progress' : 'Archived' },

    // Computer — takes a sibling document; the view calls it with the sibling it already holds
    completionPercent(sprint) {
      return Math.round((this.completedItems / sprint.totalItems) * 100)
    },
  },
}

// In the component — destructure both getter output and computer function:
// const TaskItem = ({ title, createdAtDisplay, completionPercent, sprint }) => (
//   <li>
//     <span>{title}</span>
//     <span>{createdAtDisplay}</span>          ← plain string, getter already resolved
//     <span>{completionPercent(sprint)}%</span> ← call with the wired sibling
//   </li>
// )
```

```swift
struct Task: Identifiable {
  let id: String; let title: String; let status: String; let createdAt: TimeInterval

  var createdAtDisplay: String {
    Date(timeIntervalSince1970: createdAt)
      .formatted(.dateTime.month(.abbreviated).day().year())
  }

  var statusLabel: String { status == "active" ? "In Progress" : "Archived" }
}
```

---

## createStore

One store per app. Pass the adapter and the initial seed data.

```ts
import { createStore } from '@fiskal/antifragile'
import { MemoryAdapter } from '@fiskal/antifragile/adapters/memory'

const store = createStore(MemoryAdapter({
  tasks: [
    { id: 'task-1', title: 'Deploy', status: 'active', createdAt: Date.now() },
  ],
}))
```

```swift
import Antifragile

let store = Store.createStore {
  BackingStoreConfig(
    name: "default",
    adapter: MemoryAdapter(initial: [
      "tasks": ["task-1": ["id": "task-1", "title": "Deploy", "status": "active", "createdAt": Date().timeIntervalSince1970]],
    ]),
    mutates: [addTask, archiveTask]
  )
}
```

---

## createMutate

Every state change is a named write descriptor — not a function call. The descriptor is serializable, logged, and rollback-safe.

```ts
export const archiveTask = createMutate(store, {
  write: ({ id }) => ({
    collection: 'tasks',
    id,
    fields: { status: 'archived' },
    merge: true,
  }),
})
```

```swift
let archiveTask = createMutate(action: "ArchiveTask") { payload in
  guard let id = payload["id"] as? String else { return [] }
  return [Write(path: "tasks", id: id, fields: ["status": "archived"])]
}
```

---

## wireView

`createWireView` returns a `wireView` factory bound to the store and its mutates. Call `createWireView` once in `store.ts`; use the returned `wireView` everywhere else.

```ts
// store.ts
export const wireView = createWireView(store, { addTask, archiveTask })

// App.tsx — wireView is the ONLY import from store.ts in a component file
import { wireView } from './store.js'

const WiredTaskItem = wireView(
  'TaskItem',
  ({ taskId }) => ({ task: { collection: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

const WiredTaskList = wireView(
  'TaskList',
  { taskIds: { collection: 'tasks', where: { status: 'active' } } },
  [],
  TaskList,   // TaskItem is injected automatically — it was registered above
)
```

---

## Time travel

Every write is stored in an append-only log. Any past state is recoverable without re-running code.

```ts
store.history.back()      // roll back last write
store.history.forward()   // replay rolled-back write
store.history.goto(3)     // jump to any snapshot
store.history.log()
// → [{ action: 'ArchiveTask', writes: [...], at: 1712345678 }, ...]
```

```swift
store.history.back()
store.history.forward()
store.history.goto(index: 3)
store.history.log()   // → [HistoryEntry]
```

---

## Adapters

MemoryAdapter is the default — fully functional, not a test fake. Swap in Firestore, CloudKit, GunJS, or NSUserDefaults by changing one line in `createStore`. Components, queries, and mutates are unchanged.

| Adapter | Language | Notes |
|---|---|---|
| MemoryAdapter | TS + Swift | Default. In-process. Full atomic op support. |
| FirestoreAdapter | TypeScript | Real-time via `onSnapshot`. |
| GunAdapter | TypeScript | P2P CRDT. Offline-first. No server required. |
| CloudKitAdapter | Swift | CKRecord subscriptions. iCloud sync. |
| NSUserDefaultsAdapter | Swift | Local persistence. No sync. |

---

## Testing

Components are plain functions — test them with props, no setup.

```tsx
// No Provider, no store, no mocks
render(<TaskItem task={{ id: '1', title: 'Deploy', createdAtDisplay: 'Jun 23, 2026' }} archiveTask={vi.fn()} />)
```

```swift
// Plain struct init — no environment, no store
TaskItem(task: Task(id: "1", title: "Deploy", status: "active", createdAt: Date().timeIntervalSince1970), archiveTask: { _ in })
```

Write logic is a pure data transform — test without touching the store.

```ts
const writes = await resolveWrites(archiveTask, { id: 'task-1' })
expect(writes).toEqual([{ collection: 'tasks', id: 'task-1', fields: { status: 'archived' }, merge: true }])
```

---

## Install

**TypeScript / React**

```sh
npm install @fiskal/antifragile
```

**Swift / SwiftUI — Swift Package Manager**

```
https://github.com/fiskal/fiskal-antifragile
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/fiskal/fiskal-antifragile", from: "0.1.0")
```

Then add `"Antifragile"` to your target's dependencies.
