## Tagline
### Hooks break apps.
Antifragile is an offline-first state library without logic in views. Views become simple
displays. Every write is logged. When something breaks, the full trace is already there —
all the data needed to fix the bug is in the log. Each failure is a one-look fix, and the
app gets stronger with every break.

---

## Audience
**Platform:** React (TypeScript) · SwiftUI (Swift — iOS, macOS, watchOS)
**Category:** Anti-fragile state management library
**Audience:** Developers building with AI agents; teams who need enforced architectural boundaries
and full observability without retrofitting logging
**Prior art:** Redux, Zustand, Jotai (TS) · Combine, @Published, @Observable (Swift)
**Pain point:** Logic leaks into views (especially with agents). Crashes have no context.
Bugs can't be reproduced. Testing requires mock stores and providers.
**Today:** Manual logging, post-hoc instrumentation, code review to catch misplaced logic,
test suites full of mock setup

---

## Why
Hooks break apps. Every `useState`, `useEffect`, and `useContext` is logic inside a view —
and logic in a view can fail silently with no trace. The view looked right in tests, the
hook looked right in isolation, but together under real data they break and leave nothing
behind to debug.

Antifragile removes hooks from views. Views are offline-first: they receive data as props
and return markup, nothing more. No hook, no state, nothing that can fail. Every write goes
to the local log first and syncs after. When something breaks, the full trace is already
there — every mutation in order, all the data needed to understand the bug. Each fix is
one look at the log. The app gets stronger with every failure.

---

## Core use cases

**The minimum: a view with no data, wired to the store**

```tsx
// TaskItem.tsx — no library imports, no hooks
const TaskItem = ({ task, setStatus }) => (
  <li>
    <span>{task.title}</span>
    <span>{task.status}</span>
    <button onClick={() => setStatus({ id: task.id, status: 'done' })}>Done</button>
  </li>
)

// store.ts — model inline, one mutation
const store = createStore(
  MemoryAdapter({ tasks: [{ id: 'task-1', title: 'Deploy', status: 'todo' }] }),
  { models: { tasks: { schema: { type: 'object',
    properties: { id: { type: 'string' }, title: { type: 'string' }, status: { type: 'string' } },
  } } } },
)
const setStatus = createMutate(store, {
  write: ({ id, status }) => ({ collection: 'tasks', id, fields: { status }, merge: true }),
})
export const wireView = createWireView(store, { setStatus })

// wires.ts — the only file that touches the store
wireView('TaskItem',
  ({ taskId }) => ({ task: { collection: 'tasks', id: taskId } }),
  ['setStatus'],
  TaskItem,
)

// Test — pass props directly, nothing else needed
render(<TaskItem task={{ id: '1', title: 'Deploy', status: 'todo' }} setStatus={vi.fn()} />)
```

**The same view in Swift**

```swift
// TaskItem.swift — no store, no @EnvironmentObject
struct TaskItem: View {
  let task: Task
  let setStatus: (String, String) -> Void
  var body: some View {
    HStack {
      Text(task.title)
      Text(task.status)
      Button("Done") { setStatus(task.id, "done") }
    }
  }
}

// Wires.swift — outside the view file
wireView("TaskItem",
  queries: { props in (task: ["collection": "tasks", "id": props.taskId]) },
  actions: ["setStatus"],
  view: TaskItem.init
)

// Test — plain struct, no environment
TaskItem(task: Task(id: "1", title: "Deploy", status: "todo"), setStatus: { _, _ in })
```

**When something breaks — the log is always there**

```ts
store.history.log()
// → [{ write: { collection: 'tasks', id: 'task-1', fields: { status: 'done' } } }]

store.history.back()   // undo last write
```
