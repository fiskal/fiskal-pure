## Tagline
### Views without data. Data tracks everything.
Views display. They cannot break because they have nothing to break — no hooks, no state,
no logic. Data tracks every change as a named record. When something breaks, the full log
is there: every mutation, in order, ready for an AI to replay and fix.

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
Hooks are where view bugs live. `useState`, `useEffect`, `useContext` — each one puts logic
inside a view. Logic in a view can break. When it does there is no log, no changeset, no
reproduction case. You get a stack trace and a guess.

Antifragile removes hooks from views entirely. A view receives data and returns markup.
It cannot have a bug because it has no behaviour. If something looks wrong, the problem is
in the data layer — which is fully logged, serializable, and replayable by an AI. Every
write is a named descriptor. The complete changeset ships with the failure automatically.

Mutations are injected into components as props, not imported. Testing means passing a
function. No provider, no mock store, no setup.

---

## Core use cases

**The minimum: a view with no data, wired to the store**

```tsx
// TaskItem.tsx — no library imports, no hooks, just props
const TaskItem = ({ task, archiveTask }) => (
  <li>
    <span>{task.title}</span>
    <button onClick={() => archiveTask(task.id)}>Archive</button>
  </li>
)

// wires.ts — the only place the store is touched
wireView('TaskItem',
  ({ taskId }) => ({ task: { collection: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

// Test — pass props directly, nothing else needed
render(<TaskItem task={{ id: '1', title: 'Deploy' }} archiveTask={vi.fn()} />)
```

**The same view in Swift**

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

**When something breaks — the log is always there**

```ts
store.history.log()
// → [
//     { action: 'AddTask',     write: { collection: 'tasks', id: 'task-1', title: 'Deploy' } },
//     { action: 'ArchiveTask', write: { collection: 'tasks', id: 'task-1', status: 'archived' } },
//   ]

store.history.back()   // undo last write
```
