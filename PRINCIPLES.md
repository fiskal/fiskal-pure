# Antifragile
### Hooks break apps.

Antifragile is an offline-first state library without logic in views. Views become simple displays — no hooks, no state, nothing that can fail. Every write is logged as a named, serializable record. When something breaks, the full trace is already there: every mutation in order, all the data needed to fix the bug. Each failure is a one-look fix. The app gets stronger with every break.

- **No logic in views** — hooks are where app bugs live; remove them and views become inert displays
- **Offline-first** — writes go local first; sync is a separate, optional concern
- **Every write logged** — serializable change records, replayable from any point
- **Full trace on failure** — all the data to fix the bug is already in the log
- **Stronger with each break** — failures are self-documenting; fixes get faster over time
- **Universal backing store** — Firestore, MongoDB, CloudKit, SQLite, GunJS, Keychain, NSUserDefaults

---

## The minimum — React

```tsx
// TaskItem.tsx — no library imports, no hooks
const TaskItem = ({ task, archiveTask }) => (
  <li>
    <span>{task.title}</span>
    <button onClick={() => archiveTask(task.id)}>Archive</button>
  </li>
)

// wires.ts — the only file that touches the store
import { wireView } from './store'
wireView('TaskItem',
  ({ taskId }) => ({ task: { collection: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

// Test — pass props directly
render(<TaskItem task={{ id: '1', title: 'Deploy' }} archiveTask={vi.fn()} />)
```

## The minimum — Swift

```swift
// TaskItem.swift — no store, no @EnvironmentObject
struct TaskItem: View {
  let task: Task
  let archiveTask: (String) -> Void
  var body: some View {
    HStack {
      Text(task.title)
      Button("Archive") { archiveTask(task.id) }
    }
  }
}

// Wires.swift — outside the view file
wireView("TaskItem",
  queries: { props in (task: ["collection": "tasks", "id": props.taskId]) },
  actions: ["archiveTask"],
  view: TaskItem.init
)

// Test — plain struct, no environment
TaskItem(task: Task(id: "1", title: "Deploy"), archiveTask: { _ in })
```

---

# API

## Model

A plain object registered with a backing store. Defines the schema, virtual computed fields, and migration history for an entity. The library parses the JSON Schema and generates `Codable`, `Identifiable`, `Equatable`, and any protocols required by the backing store — no hand-written types needed in either language.

**TypeScript**

```ts
export const TaskModel = {

  schema: {
    type: 'object',
    properties: {
      id:        { type: 'string' },
      title:     { type: 'string', minLength: 1 },
      status:    { type: 'string', enum: ['active', 'done'] },
      createdAt: { type: 'number' },
      dueDate:   { type: 'number', nullable: true },
    },
    required: ['id', 'title', 'status', 'createdAt'],
  },

  // getters, setters, and methods — names must not exist in schema
  compute: {
    get createdAtDisplay()  { return new Date(this.createdAt).toLocaleDateString(); },
    set createdAtDisplay(v) { this.createdAt = new Date(v).getTime(); },
    get statusLabel()       { return { active: 'In Progress', done: 'Complete' }[this.status]; },
    get isOverdue()         { return !!this.dueDate && this.dueDate < Date.now(); },
    isAssignedTo(user)      { return this.assigneeId === user.id; },
  },

  versioning: [
    {
      partialSchema: { dueDate: { type: 'number', nullable: true } },
      rollforward:   (v) => ({ ...v, dueDate: null }),
      rollback:      (v) => { const { dueDate, ...rest } = v; return rest; },
    },
  ],

};
```

**Swift** — same JSON Schema, library generates `Codable`, `Identifiable`, `Equatable` and persistence protocols.

```swift
let TaskModel = Model(

  schema: [
    "type": "object",
    "properties": [
      "id":        ["type": "string"],
      "title":     ["type": "string", "minLength": 1],
      "status":    ["type": "string", "enum": ["active", "done"]],
      "createdAt": ["type": "number"],
      "dueDate":   ["type": "number", "nullable": true],
    ],
    "required": ["id", "title", "status", "createdAt"],
  ],

  // getters, setters, and methods — names must not exist in schema
  compute: ModelCompute()
    .get("createdAtDisplay")  { Date(timeIntervalSince1970: $0.createdAt).formatted() }
    .set("createdAtDisplay")  { doc, v in var d = doc; d.createdAt = (v as! Date).timeIntervalSince1970; return d }
    .get("statusLabel")       { $0.status == "active" ? "In Progress" : "Complete" }
    .get("isOverdue")         { $0.dueDate.map { $0 < Date().timeIntervalSince1970 } ?? false }
    .method("isAssignedTo")   { doc, user in doc.assigneeId == user.id },

  versioning: [
    Migration(
      partialSchema: ["dueDate": ["type": "number", "nullable": true]],
      rollforward: { var v = $0; v["dueDate"] = nil; return v },
      rollback:    { var v = $0; v.removeValue(forKey: "dueDate"); return v }
    ),
  ]

)
```

---

## `createMutate`

Declares a named write as a plain data descriptor. Writes update the in-memory cache synchronously then sync to the backing store async. Returns a Promise / async function resolving on remote confirmation.

The write is synchronous and optimistic — the UI re-renders immediately. The mutation then runs a second time against the database with fully resolved data. If the result differs from the optimistic write, `useRead` triggers a second re-render to reconcile.

**TypeScript**

```ts
// write
export const archiveTask = createMutate({
  action: 'ArchiveTask',
  write:  (id: string) => ({ path: 'tasks', id, archived: true }),
});

// read then write
export const completeTask = createMutate({
  action: 'CompleteTask',

  read: ({ taskId, sprintId }: CompletePayload) => ({
    task:   { path: 'tasks',   id: taskId   },
    sprint: { path: 'sprints', id: sprintId },
  }),

  write: ({ task, sprint }) => ({
    path: 'tasks', id: task.id, status: 'done', sprintScore: sprint.pointsPerTask,
  }),
});

// transaction — array of write functions, ACID on remote
export const moveTask = createMutate({
  action: 'MoveTask',

  read: ({ taskId, toSprintId }: MovePayload) => ({
    task:     { path: 'tasks',   id: taskId    },
    toSprint: { path: 'sprints', id: toSprintId },
  }),

  write: [
    ({ task, toSprint }) => ({ path: 'tasks',   id: task.id,       sprintId: toSprint.id }),
    ({ task, toSprint }) => ({ path: 'sprints', id: toSprint.id,   orderedTaskIds: [.arrayUnion,  task.id] }),
    ({ task })           => ({ path: 'sprints', id: task.sprintId, orderedTaskIds: [.arrayRemove, task.id] }),
  ],
});
```

```ts
archiveTask('task-1');
await moveTask({ taskId, toSprintId });
archiveTask('task-1').catch(err => showToast(err.message));
```

**Swift**

```swift
let archiveTask = createMutate(
  action: "ArchiveTask",
  write: { id in Write(path: "tasks", id: id, fields: ["archived": true]) }
)

let completeTask = createMutate(
  action: "CompleteTask",

  read: { payload in [
    "task":   Read(path: "tasks",   id: payload.taskId),
    "sprint": Read(path: "sprints", id: payload.sprintId),
  ]},

  write: { reads in
    Write(path: "tasks", id: reads.task.id,
          fields: ["status": "done", "sprintScore": reads.sprint.pointsPerTask])
  }
)

let moveTask = createMutate(
  action: "MoveTask",

  read: { payload in [
    "task":     Read(path: "tasks",   id: payload.taskId),
    "toSprint": Read(path: "sprints", id: payload.toSprintId),
  ]},

  write: [
    { reads in Write(path: "tasks",   id: reads.task.id,      fields: ["sprintId": reads.toSprint.id]) },
    { reads in Write(path: "sprints", id: reads.toSprint.id,  fields: ["orderedTaskIds": [.arrayUnion,  reads.task.id]]) },
    { reads in Write(path: "sprints", id: reads.task.sprintId, fields: ["orderedTaskIds": [.arrayRemove, reads.task.id]]) },
  ]
)
```

```swift
archiveTask("task-1")
await moveTask(MovePayload(taskId: taskId, toSprintId: toSprintId))
```

---

## `createStore`

One store per app. Each backing store gets its own adapter, models, and mutates.

**TypeScript** — exported directly, no provider needed.

```ts
export const store = createStore({
  default: {
    adapter: FirestoreAdapter(firebaseApp),
    models:  { tasks: TaskModel, sprints: SprintModel },
    mutates: { archiveTask, moveTask, completeTask },
  },
  keychain: {
    adapter: KeychainAdapter(),
    models:  { auth: AuthModel },
    mutates: { storeToken, clearToken },
  },
  defaults: {
    adapter: NSUserDefaultsAdapter(),
    models:  { settings: SettingsModel },
    mutates: { setTheme, setLocale },
  },
});

export const { useRead, archiveTask, moveTask, storeToken, setTheme } = store;
```

**Swift** — injected via `.environment`, accessed with `@Environment`.

```swift
let store = createStore {
  BackingStore("default") {
    adapter:  FirestoreAdapter(firebaseApp)
    models:   [TaskModel.self, SprintModel.self]
    mutates:  [archiveTask, moveTask, completeTask]
  }
  BackingStore("keychain") {
    adapter:  KeychainAdapter()
    models:   [AuthModel.self]
    mutates:  [storeToken, clearToken]
  }
  BackingStore("defaults") {
    adapter:  NSUserDefaultsAdapter()
    models:   [SettingsModel.self]
    mutates:  [setTheme, setLocale]
  }
}

@main struct MyApp: App {
  var body: some Scene {
    WindowGroup { ContentView() }
      .environment(store)
  }
}
```

`addStore` registers an additional backing store after construction:

```ts
store.addStore('mongo', { adapter: MongoAdapter(mongoClient), models: { users: UserModel }, mutates: { updateUser } });
```

```swift
store.addStore("mongo", BackingStore { adapter: MongoAdapter(client); models: [UserModel.self]; mutates: [updateUser] })
```

---

## `wireView`

Wires a pure component to the store — queries, actions, and any registered views matching a prop name are injected automatically. Under the covers it is vanilla React hooks and native SwiftUI patterns.

**TypeScript** — `wireView` generates this:

```tsx
function TaskItemWired({ taskId }) {
  const task        = useRead({ path: 'tasks', id: taskId });
  const archiveTask = useAction('archiveTask');
  if (!task) return null;
  return <TaskItem task={task} archiveTask={archiveTask} />;
}

function TaskListWired() {
  const taskIds = useRead({ path: 'tasks', where: ['status', '==', 'active'] });
  if (!taskIds) return null;
  return <TaskList taskIds={taskIds} TaskItem={TaskItemWired} />;
}
```

**Swift** — `wireView` generates this:

```swift
struct TaskItemWired: View {
  let taskId: String
  @Query(["path": "tasks", "id": taskId]) var task: Task?
  var body: some View {
    if let task { TaskItem(task: task, archiveTask: store.archiveTask) }
  }
}

struct TaskListWired: View {
  @Query(["path": "tasks", "where": ["status", "==", "active"]]) var taskIds: [TaskId]
  var body: some View {
    TaskList(taskIds: taskIds, TaskItem: TaskItemWired.init)
  }
}
```

No new runtime, no framework magic — just the hooks and property wrappers you already know, generated from the wire declaration.

---

## Adapters

**Normalized** — any non-`ui/` path is stored in a flat entity table. One copy per entity, shared across all queries and components.

```
database.tasks['task-1']     ← single source of truth
database.sprints['sprint-a']
```

**Nested** — `ui/` paths mirror the component tree. Never normalized, never synced to remote.

```
ui.sidebar.global    ← { isOpen: true }
ui.taskList.view     ← { selectedId: 'task-1' }
ui.taskForm.draft    ← { title: '', assignee: null }
```

**Adapters**

```ts
import { FirestoreAdapter }      from '@fiskal/antifragile/adapters/firestore';
import { MongoAdapter }          from '@fiskal/antifragile/adapters/mongo';
import { GunAdapter }            from '@fiskal/antifragile/adapters/gun';
import { DatomicAdapter }        from '@fiskal/antifragile/adapters/datomic';
import { CloudKitAdapter }       from '@fiskal/antifragile/adapters/cloudkit';
import { NSUserDefaultsAdapter } from '@fiskal/antifragile/adapters/nsuserdefaults';
import { KeychainAdapter }       from '@fiskal/antifragile/adapters/keychain';
```

**Atomic Write Operations** — `::delete` is universal, all others adapter-defined.

| Tuple | Behavior |
|---|---|
| `['::delete']` | Remove the field |
| `['::serverTimestamp']` | Server time on write; local time optimistically |
| `['::increment', n]` | Atomic numeric increment |
| `['::arrayUnion', value]` | Add to array if not present |
| `['::arrayRemove', value]` | Remove from array |

---

## Time Travel

Every write is a plain data descriptor stored in the write log. Because the in-memory cache uses structural sharing of immutable snapshots, any past state is recoverable without re-running code.

```ts
store.history.back();           // roll back last write
store.history.forward();        // replay rolled-back write
store.history.goto(index);      // jump to any snapshot
store.history.log();
// → [{ action: 'ArchiveTask', writes: [...], at: 1712345678 }, ...]
```

```swift
store.history.back()
store.history.forward()
store.history.goto(index: 3)
store.history.log()  // → [HistoryEntry]
```

Time travel works across all backing stores simultaneously. The write log is append-only and serializable — it can be persisted, replayed from scratch, or diffed between sessions.

---

# Patterns

## Testing

**TypeScript**

```ts
import { store }         from './store';
import { resolveWrites } from '@fiskal/antifragile/test';
import { shouldPass, shouldFail } from '@fiskal/antifragile/test';

beforeEach(() => store.seed({ tasks: [{ id: 'task-1', path: 'tasks', title: 'Deploy', status: 'active' }] }));
afterEach(() => store.reset());

const writes = await resolveWrites(archiveTask, 'task-1');
// → [{ path: 'tasks', id: 'task-1', archived: true }]

it.each([{
  payload:  'task-1',
  expected: [{ path: 'tasks', id: 'task-1', archived: true }],
}])('archives task', shouldPass(archiveTask));

it.each([{ payload: '' }])('rejects empty id', shouldFail(archiveTask));
```

**Swift**

```swift
override func setUp() {
  store.seed(["tasks": [Task(id: "task-1", title: "Deploy", status: .active)]])
}
override func tearDown() { store.reset() }

func testArchiveTask() async throws {
  let writes = try await resolveWrites(archiveTask, "task-1")
  XCTAssertEqual(writes, [Write(path: "tasks", id: "task-1", fields: ["archived": true])])
}
```

---

## Extended Queries

### In-Memory / Firestore / MongoDB — core DSL

```ts
useRead({ path: 'tasks', where: ['status', '==', 'active'], orderBy: ['createdAt', 'desc'] });
```

### GunJS — path traversal, client-side filter

```ts
useRead({ path: 'gun/users/user-1/tasks', where: ['status', '==', 'active'] });
```

### Datomic / DataScript — datalog

```ts
useRead({
  path:  'datomic/tasks',
  query: { find: ['?t'], where: [['?t', ':task/status', ':active']] },
});
```

### CloudKit — predicate

```ts
useRead({
  path:  'cloudkit/tasks',
  query: {
    filterBy: [{ fieldName: 'status', comparator: 'EQUALS', fieldValue: { value: 'active' } }],
    sortBy:   [{ fieldName: 'createdAt', ascending: false }],
  },
});
```

### NSUserDefaults / Keychain — key-value only

```ts
useRead({ path: 'defaults/settings', id: 'theme' });
useRead({ path: 'keychain/auth',     id: 'apiToken' });
```

---

## `createMutate` — Batch and UI State

**Batch** — array of descriptors, atomic on remote.

```ts
export const archiveSprint = createMutate({
  action: 'ArchiveSprint',
  read:   ({ sprintId }) => ({ tasks: { path: 'tasks', where: ['sprintId', '==', sprintId] } }),
  write:  ({ tasks, sprint }) => [
    { path: 'sprints', id: sprint.id, archived: true },
    ...tasks.map(task => ({ path: 'tasks', id: task.id, archived: true })),
  ],
});
```

**UI state** — `ui/` prefix, local only.

```ts
export const selectTask    = createMutate({ action: 'ui/SelectTask',    write: (id) => ({ path: 'ui/taskList', id: 'view', selectedId: id }) });
export const toggleSidebar = createMutate({ action: 'ui/ToggleSidebar', read: () => ({ sidebar: { path: 'ui/sidebar', id: 'global' } }), write: ({ sidebar }) => ({ path: 'ui/sidebar', id: 'global', isOpen: !sidebar.isOpen }) });
```

---

# Deep Dive

## How the Store Works

The in-memory cache is a flat normalized entity table using **immutable data with structural sharing**. When a document changes, only that document's node is replaced — every other node in the tree keeps its exact reference. Components subscribed to unchanged documents never re-render.

```
write task-1.title →  database
                      ├── tasks
                      │   ├── task-1  ← new reference (changed)
                      │   └── task-2  ← same reference (unchanged)
                      └── sprints
                          └── ...     ← same reference (unchanged)
```

All writes are **synchronous** against the cache. The backing store is eventually consistent with the cache — not the other way around. The cache is the source of truth for the UI. The backing store is a durable replica.

Every write produces a **snapshot** — a cheap pointer to the immutable tree at that moment. Snapshots form the write log that powers time travel. Because snapshots are structural shares of the same immutable tree, the entire log costs only the memory of what actually changed, not a full copy per write.

The sync model is **CRDT-adjacent**: writes are plain data transforms that can be ordered, replayed, or merged. Conflicts are resolved by the adapter (last-write-wins, or adapter-specific conflict resolution).

---

## Building an Adapter

An adapter connects a backing store to the in-memory cache. It implements three methods.

**TypeScript**

```ts
interface Adapter {
  subscribe(query: Query, onChange: (docs: Doc[]) => void): () => void;
  write(operation: Write | Write[] | Transaction): Promise<void>;
  query?(q: AdapterQuery): Promise<Doc[]>; // optional
}
```

```ts
export function MyAdapter(client: MyClient): Adapter {
  return {
    subscribe(query, onChange) {
      const unsub = client.watch(toNativeQuery(query), docs => onChange(docs));
      return unsub;
    },
    async write(operation) {
      await client.commit(toNativeWrite(operation));
    },
  };
}
```

**Swift**

```swift
protocol Adapter {
  func subscribe(query: Query, onChange: @escaping ([Doc]) -> Void) -> () -> Void
  func write(operation: WriteOperation) async throws
  func query(_ q: AdapterQuery) async throws -> [Doc]
}

struct MyAdapter: Adapter {
  let client: MyClient
  func subscribe(query: Query, onChange: @escaping ([Doc]) -> Void) -> () -> Void {
    let handle = client.watch(toNativeQuery(query)) { docs in onChange(docs) }
    return { handle.cancel() }
  }
  func write(operation: WriteOperation) async throws {
    try await client.commit(toNativeWrite(operation))
  }
}
```

The adapter never touches the in-memory cache. It delivers documents via `onChange` and confirms writes. The store owns the cache, the optimistic update, and the rollback.

---

## `useRead` / `@Query`

Used internally by `wireView`. Available directly for dynamic queries.

**TypeScript**

```ts
const task = useRead({ path: 'tasks', id: taskId });
// → { id: 'task-1', title: 'Deploy', status: 'active' }

const title = useRead({ path: 'tasks', id: taskId }, ['title']);
// → { title: 'Deploy' }

const partial = useRead({ path: 'tasks', id: taskId }, ['title', 'status']);
// → { title: 'Deploy', status: 'active' }

const taskIds = useRead({ path: 'tasks' });
// → [{ id: 'task-1' }, { id: 'task-2' }]

const partials = useRead({ path: 'tasks' }, ['title', 'status']);
// → [{ title: 'Deploy', status: 'active' }, { title: 'Review', status: 'done' }]

const active = useRead({ path: 'tasks', where: ['status', '==', 'active'] });
// → [{ id: 'task-1' }]

const activePartials = useRead(
  { path: 'tasks', where: ['status', '==', 'active'] },
  ['title', 'status'],
);
// → [{ title: 'Deploy', status: 'active' }]
```

**Swift**

```swift
@Query(["path": "tasks", "id": taskId])
var task: Task?

@Query(["path": "tasks", "id": taskId, "fields": ["title"]])
var title: TaskTitle?

@Query(["path": "tasks", "id": taskId, "fields": ["title", "status"]])
var partial: TaskPartial?

@Query(["path": "tasks"])
var taskIds: [TaskId]

@Query(["path": "tasks", "fields": ["title", "status"]])
var partials: [TaskPartial]

@Query(["path": "tasks", "where": ["status", "==", "active"]])
var active: [TaskId]

@Query(["path": "tasks", "where": ["status", "==", "active"], "fields": ["title", "status"]])
var activePartials: [TaskPartial]
```

`undefined` / `nil` = loading. `null` / `Optional.none` = not found. Returns are always objects — never primitives.

---

# Comparison

## Redux

| | Redux | Advantage | |
|---|---|---|---|
| Selectors | Memoized functions — hidden state causes stale results at runtime with no compiler warning | → | Plain query object against structural-shared immutable data — nothing to go stale |
| Writes | Reducer functions — can't serialize, diff, or assert on a state change without running code | → | Plain data descriptors — assertable, loggable, replayable without executing anything |
| Async lifecycle | Every team rebuilds loading, error, optimistic, and rollback differently | → | One `createMutate` declaration handles the full lifecycle consistently |
| Optimistic updates | Hand-rolled per action — rollback is manual and error-prone | → | Automatic on every write, automatic rollback on failure |
| Derived/formatted data | Selectors or component logic — duplicated, can desync | → | `compute` getters on the model, always derived fresh from the same source |
| Testing | Must mock dispatch, the store, and the SDK | → | Assert on write descriptor — seed store with data, no mocks |
| Time travel | DevTools only, replayed through functions | → | Serializable write log, replayable in production |
| Schema + migrations | None — bad data enters silently, old data breaks on deploy | → | JSON Schema validates at every boundary, `versioning` migrates forward on read |
| DevTools ecosystem | Mature, battle-tested, widely adopted | ← | Early stage |

---

## Zustand

| | Zustand | Advantage | |
|---|---|---|---|
| Derived/formatted data | Functions in the store — stale closures return wrong values when data shape changes | → | `compute` getters scoped to `this` — always derived from live data |
| Shared entity state | Same entity duplicated across slices — manual sync, easy to desync | → | Normalized — one copy, all subscribers see the same update automatically |
| Schema validation | None — invalid data enters the store silently | → | JSON Schema validates at every network and storage boundary |
| Async lifecycle | No opinion — every team implements it differently | → | `createMutate` — consistent across the entire app |
| Optimistic updates | None | → | Automatic on every write, automatic rollback |
| Migrations | None — old persisted data breaks silently on schema change | → | `versioning` migrates documents forward on read |
| Time to productive | More concepts upfront — model, store config, adapter | ← | 5 minutes to a working store |

---

## Jotai

| | Jotai | Advantage | |
|---|---|---|---|
| Shared entity state | Same entity across multiple atoms — updating one doesn't update the others | → | Normalized — one copy, changes propagate everywhere automatically |
| Derived/formatted data | Derived atoms go stale when upstream atom shapes change | → | `compute` getters on the model — always correct |
| Schema validation | None | → | JSON Schema per model |
| Optimistic updates | None | → | Automatic on every write, automatic rollback |
| Async reads | Async atoms + Suspense — complex error boundary wiring | → | `undefined` / `null` / data — simple three-state contract |
| Re-render granularity | Per-atom — extremely precise control over what re-renders | ← | Collection reads return ids by default — same effect, less manual control |

---

## MobX

| | MobX | Advantage | |
|---|---|---|---|
| Accidental mutations | Any property set outside `@action` produces inconsistent renders silently | → | All writes go through `createMutate` — no path to accidental mutation |
| Serialization | Class instances can't be cleanly serialized, diffed, or replayed | → | Plain data descriptors — JSON-serializable everywhere |
| Testing | Must instantiate the class graph to test anything | → | Assert on write descriptor — no class setup, no mocks |
| Optimistic updates | None | → | Automatic on every write, automatic rollback |
| Schema + migrations | None | → | JSON Schema + `versioning` per model |
| Deep derived state chains | `@computed` chains handle deeply interdependent derived state elegantly | ← | Complex chains require composing `compute` getters and multiple `useRead` calls |

---

## GraphQL (Apollo / URQL)

| | GraphQL | Advantage | |
|---|---|---|---|
| Cache invalidation | Manual after every mutation — missed invalidations cause stale UI with no warning | → | Automatic — normalized store updates every subscriber on every write |
| Optimistic updates | `optimisticResponse` duplicates the full response shape — easy to get wrong, hard to test | → | Just the write descriptor — tested as plain data, no Apollo client needed |
| Rollback | None | → | Automatic on failure |
| Local / UI state | Separate mechanism — reactive vars, `useState` — different patterns for same-screen state | → | Same `ui/` path, same `useRead`, same `createMutate` as domain state |
| Formatters + computed | None client-side — formatting lives in components or resolvers | → | `compute` formatters co-located with the schema, shared across TypeScript and Swift |
| Backend coupling | Requires a GraphQL server | → | Any adapter — Firestore, REST, SQLite, or no remote at all |
| Tooling ecosystem | Schema introspection, codegen, Apollo Studio, federation at scale | ← | No equivalent yet |

---

## SwiftUI Combine

| | Combine + `@Published` | Advantage | |
|---|---|---|---|
| Re-render granularity | Entire `ObservableObject` subtree re-renders when any `@Published` property changes | → | `@Query` re-renders only the view whose exact data changed |
| Shared entity state | Same entity across multiple `ObservableObject` instances — easy to desync | → | Normalized — one copy, every `@Query` subscriber sees the update |
| Schema + migrations | None — old persisted data silently breaks on model change | → | JSON Schema → `Codable` generated by macro, `versioning` migrates forward |
| Optimistic updates | None | → | Automatic on every write, automatic rollback |
| Async | Combine publishers and operator chains — steep learning curve | → | `createMutate` — plain data, `async/await` |
| Cross-platform | iOS/macOS only | → | TypeScript and Swift — same model, same queries, same mutations |
| Native framework integration | URLSession, NotificationCenter, SwiftUI animations integrate directly | ← | Replacing Combine loses those native integrations |
