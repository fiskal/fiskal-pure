# Migration Guides

How to move to fiskal-antifragile from other state management libraries, and what
to expect. Covers React ecosystem (Redux/RTK, TanStack Query, Zustand, Jotai) and
Swift ecosystem (TCA, SwiftData, @Observable).

---

## From Redux / RTK

### The fundamental shift

Redux is a global state tree with reducers and selectors. RTK adds `createSlice` and
`createSelector` as ergonomic wrappers. fiskal-antifragile removes the global tree
entirely — subscriptions are per-document, so selectors are unnecessary.

### Step-by-step migration

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
export default tasksSlice.reducer

// fiskal-antifragile — after
export const addTask = createMutate(store, {
  action: 'AddTask',
  write: ({ id, title }) => ({
    collection: 'tasks', id,
    fields: { title, status: 'active', createdAt: Date.now() },
    merge: false,
  }),
})

export const archiveTask = createMutate(store, {
  action: 'ArchiveTask',
  write: ({ id }) => ({
    collection: 'tasks', id,
    fields: { status: 'archived' },
    merge: true,
  }),
})
```

**Step 2: Replace `useSelector` + `createSelector` with wireView queries**

```ts
// Redux RTK — before (in the component file)
import { useSelector } from 'react-redux'
import { selectTaskById } from './tasksSlice'

const TaskItem = ({ taskId }) => {
  const task = useSelector(selectTaskById(taskId))
  return <li>{task.title}</li>
}

// fiskal-antifragile — after (wireView is outside the component file)
// In the component file (no imports from store):
const TaskItem = ({ task, archiveTask }) => <li onClick={() => archiveTask({ id: task.id })}>{task.title}</li>

// In wires.ts (outside the component):
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  ['archiveTask'],
  TaskItem,
)
```

**Step 3: Replace `createSelector` memoized computations with model getters**

```ts
// Redux RTK — before
const selectTaskDisplayDate = createSelector(
  selectTaskById,
  task => new Date(task.createdAt).toLocaleDateString()
)

// fiskal-antifragile — after (in model definition, outside component)
const TaskModel = {
  compute: {
    get createdAtDisplay() {
      return new Date(this.createdAt).toLocaleDateString()
    },
  },
}
// Component just uses task.createdAtDisplay — no selector, no import
```

**Step 4: Replace `dispatch` error handling with error subscription**

```ts
// Redux RTK — before
try {
  await dispatch(archiveTask(id)).unwrap()
} catch (err) {
  setLocalError(err.message)
}

// fiskal-antifragile — after
// No try/catch at call site:
archiveTask({ id: task.id })  // fire-and-forget

// In a wired error component (anywhere in the tree):
const WiredErrorBanner = wireView('ErrorBanner',
  { errors: { collection: 'errors', where: { resolved: false } } },
  ['dismissError'],
  ErrorBanner,
)
```

### Selector pain vs antifragile simplicity

RTK `createSelector` exists because Redux's global state tree means any component
subscribed to a slice re-renders when any part of that slice changes. Selectors
memoize derived values to cut re-renders. AI agents over-use selectors because
they're trained on this pattern.

fiskal-antifragile has no selectors because subscriptions are per-document. A component
wired to `{ task: { id: taskId } }` only re-renders when that specific document changes.
There is no global slice to over-subscribe to. The cost of over-subscription has been
removed at the architecture level — not patched with memoization.

---

## From TanStack Query

### The fundamental shift

TanStack Query is designed for HTTP: a `queryKey` maps to a URL, `queryFn` fetches it.
fiskal-antifragile is designed for documents: a collection + id maps to a live
subscription. For REST-only backends with no real-time requirement, TanStack Query is
still the right tool. Migrate when you need real-time, offline queue, or unified
TypeScript/Swift state.

### Key differences

| Concern | TanStack Query | fiskal-antifragile |
|---|---|---|
| Data fetching | `queryFn: () => fetch(url)` | adapter `subscribe(query, cb)` |
| Cache invalidation | `queryClient.invalidateQueries(key)` | automatic on every write |
| Loading state | `isLoading` boolean | `undefined` (loading / no subscription yet) |
| Not-found state | `data === undefined` | `null` |
| Error state | `isError`, `error` | `errors` collection document |
| Mutations | `useMutation({ mutationFn })` | `createMutate(store, { action, write })` |
| Background refetch | `staleTime`, `cacheTime` | real-time subscriptions (no polling needed) |
| Optimistic updates | manual `onMutate` + `onError` rollback | built-in — automatic on every mutate |

### Migration pattern

```ts
// TanStack Query — before
const { data: task, isLoading, isError } = useQuery({
  queryKey: ['tasks', taskId],
  queryFn: () => fetch(`/api/tasks/${taskId}`).then(r => r.json()),
})

if (isLoading) return <Spinner />
if (isError) return <ErrorMessage />
return <TaskItem task={task} />

// fiskal-antifragile — after
// Component (no library imports):
const TaskItem = ({ task }) => {
  if (task === undefined) return <Spinner />     // loading
  if (task === null) return <NotFound />         // not found
  return <TaskTitle title={task.title} />
}

// wireView (outside component):
const WiredTaskItem = wireView('TaskItem',
  ({ taskId }) => ({ task: { id: taskId } }),
  [],
  TaskItem,
)
```

---

## From Zustand

Zustand stores are objects with `get` / `set` / `subscribe`. Migration is simple —
replace stores with collections and replace setters with mutates.

```ts
// Zustand — before
const useTaskStore = create((set) => ({
  tasks: [],
  addTask: (task) => set(state => ({ tasks: [...state.tasks, task] })),
  removeTask: (id) => set(state => ({ tasks: state.tasks.filter(t => t.id !== id) })),
}))

// fiskal-antifragile — after
export const addTask = createMutate(store, {
  action: 'AddTask',
  write: (task) => ({ collection: 'tasks', id: task.id, fields: task, merge: false }),
})

export const removeTask = createMutate(store, {
  action: 'RemoveTask',
  write: ({ id }) => ({ collection: 'tasks', id, delete: true }),
})
```

---

## From Jotai

Jotai atoms are fine-grained pieces of state. fiskal-antifragile's nearest equivalent
is a `ui/` path for local ephemeral state and a collection document for persistent state.

```ts
// Jotai — before
const tabAtom = atom('daily')
const filterAtom = atom('')

// fiskal-antifragile — after (ui/ prefix for ephemeral state)
export const setActiveTab = createMutate(store, {
  action: 'SetActiveTab',
  write: ({ tab }) => ({ collection: 'ui/tabs', id: 'main', fields: { active: tab }, merge: true }),
})

// wireView reads it:
wireView('TabBar', { tabs: { id: 'ui/tabs/main' } }, ['setActiveTab'], TabBar)
```

---

## From Swift TCA

TCA (The Composable Architecture) and fiskal-antifragile share the same FP philosophy:
reducers as pure functions, effects at the edge. Migration differences:

| Concern | TCA | fiskal-antifragile |
|---|---|---|
| State shape | Struct with explicit fields | `Doc = [String: Any]` (untyped) |
| Actions | Enum cases with associated values | String action name + `[String: Any]` payload |
| Effects | `Effect<Action>` | adapter's `write` + `subscribe` |
| Scope/composition | `Scope` reducer | separate backing store config per domain |
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

// fiskal-antifragile — after
let archiveTask = createMutate(action: "ArchiveTask") { payload in
    guard let id = payload["id"] as? String else { return [] }
    return [Write(path: "tasks", id: id, fields: ["status": "archived"])]
}
```

---

## From SwiftData

SwiftData is right for pure Apple-platform apps with CloudKit sync and no TypeScript
parity requirement. Migrate when you need: write log, offline queue, or shared
TypeScript models.

Key difference: SwiftData uses `@Model` and `@Query` macros that generate typed persistent
storage. fiskal-antifragile uses `Doc = [String: Any]` with adapter-based persistence.

```swift
// SwiftData — before
@Model class Task {
    var title: String
    var status: String
    init(title: String) { self.title = title; self.status = "active" }
}
@Query var tasks: [Task]
$tasks.filter(#Predicate { $0.status == "active" })

// fiskal-antifragile — after
store.get(query: Query(path: "tasks",
    where: [WhereClause(field: "status", op: .equalTo, value: "active")]))
```
