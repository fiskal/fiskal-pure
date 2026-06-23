## Tagline
### Apps that never lose state. Boundaries that can't be broken.
Anti-fragile state management where every action is logged, every failure is debuggable,
and UI is structurally forced to be stateless — no smart components, no logic in views,
no assumptions needed when something breaks.

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
Every other state library treats writes as function calls — not data. You can't serialize
a reducer. You can't replay a `useEffect`. You can't ship "what the app was doing" to your
server when something breaks, because "what the app was doing" is a call stack, not a log.

fiskal-pure makes every write a named data descriptor. The full action log is the full app
history — always serializable, always replayable, always shippable on failure. Debugging
becomes replaying a sequence of descriptors, not guessing from a stack trace.

At the same time, the architecture makes the wrong code structurally impossible. Components
import nothing from the library. All wiring is external. `wireView` is the only connection
point between a component and the store — and it lives outside the component file. Agents
and developers physically cannot mix logic into views because there is no API available to
do so inside a component.

---

## Core use cases

**TypeScript — pure component + external wire**

```ts
// TaskItem.tsx — no store imports, no hooks, no context
export function TaskItem({ task, archiveTask }) {
  return (
    <li>
      <span>{task.title}</span>
      <button onClick={() => archiveTask(task.id)}>Archive</button>
    </li>
  )
}

// wires.ts — all connection logic lives here, outside the component
wireView('TaskItem',
  ({ taskId }) => ({ task: { path: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

// Test — no providers, no setup, just props
render(<TaskItem task={{ id: '1', title: 'Deploy' }} archiveTask={vi.fn()} />)
```

**Swift — pure view + external wire**

```swift
// TaskItem.swift — no store, no @Query, no @EnvironmentObject
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

// Wires.swift — all connection logic lives here, outside the view
wireView("TaskItem",
  queries: { props in (task: ["path": "tasks", "id": props.taskId]) },
  actions: ["archiveTask"],
  view: TaskItem.init
)

// Test — plain struct init, no store, no environment
TaskItem(task: Task(id: "1", title: "Deploy"), archiveTask: { _ in })
```

**Action log on failure**

```ts
// Every write produces a descriptor — the log is always available
store.history.log()
// → [
//     { action: 'AddTask',     write: { path: 'tasks', id: 'task-1', title: 'Deploy' }, at: 1719123456 },
//     { action: 'ArchiveTask', write: { path: 'tasks', id: 'task-1', archived: true },  at: 1719123501 },
//   ]

// On error: ship the log, restore from last known-good snapshot
store.history.back()   // undo last write
store.history.goto(0)  // restore to initial state
```
