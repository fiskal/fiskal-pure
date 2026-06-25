# fiskal-pure

## Tagline
Hooks break apps.

---

## What It Does
Antifragile is an offline-first state library without logic in views. Views become simple
displays — no hooks, no state, nothing that can fail. Every write is a named, serializable
log entry. When something breaks, the full trace is already there: every mutation in order,
all the data needed to fix the bug. Each failure is a one-look fix. The app gets stronger
with every break.

---

## Platform
npm (TypeScript / React) · Swift Package Manager (iOS, macOS, watchOS)  
SwiftUI integration uses Combine and standard `@Observable` under the covers — no new runtime.

---

## Audience
**For:** Developers building with AI agents; teams who need observability they didn't have to add after the fact  
**Pain:** Bugs that can't be reproduced. Logic that drifts into views. Tests that need mock stores.  
**Prior art:** Redux, Zustand (TS) · Combine, `@Observable` (Swift) — writes are functions, not data; the action log is never there when you need it  
**Today:** Manual logging added late, code review to enforce boundaries, test suites full of mock setup  

---

## Why
Hooks break apps. `useState`, `useEffect`, `useContext` — each one is logic inside a view,
and logic in a view can fail with nothing left behind. Antifragile removes hooks from views
entirely. Views are offline-first displays: they receive data as props and return markup.
Every write goes to the local log first. When something breaks, the full trace is already
there — all the data to fix the bug is in the state and log. Each fix takes one look.
The app gets stronger with every failure.

---

## Core Use Cases

**TypeScript — pure components, wired outside, TaskItem injected into TaskList**

```tsx
// Pure components — zero library imports, tested with plain props
const TaskItem = ({ task, archiveTask }) => (
  <li>
    <span>{task.title}</span>
    <button onClick={() => archiveTask(task.id)}>Archive</button>
  </li>
)

const TaskList = ({ taskIds, TaskItem }) => (
  <ul>{taskIds.map(({ id }) => <TaskItem key={id} taskId={id} />)}</ul>
)

// Wires — outside the component files. TaskItem is injected into TaskList automatically.
wireView('TaskItem',
  ({ taskId }) => ({ task: { path: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

wireView('TaskList',
  { taskIds: { path: 'tasks', where: ['status', '==', 'active'] } },
  [],
  TaskList,
)

store.history.log()
// → [{ action: 'AddTask', ... }, { action: 'ArchiveTask', ... }]
store.history.back()
```

**Swift — same pattern. wireView uses Combine + @Observable under the covers.**

```swift
// Pure views — no store, no @EnvironmentObject, no Combine
struct TaskItem: View {
  let task: Task
  let archiveTask: (String) -> Void
  var body: some View {
    HStack { Text(task.title); Button("Archive") { archiveTask(task.id) } }
  }
}

struct TaskList<Item: View>: View {
  let taskIds: [TaskId]
  var TaskItem: (String) -> Item      // injected
  var body: some View {
    List(taskIds, id: \.self) { id in TaskItem(id) }
  }
}

// Wires — outside the view files. TaskItem is injected into TaskList automatically.
wireView("TaskItem",
  queries: { props in (task: ["path": "tasks", "id": props.taskId]) },
  actions: ["archiveTask"],
  view: TaskItem.init
)

wireView("TaskList",
  queries: (taskIds: ["path": "tasks", "where": ["status", "==", "active"]]),
  actions: [],
  view: TaskList.init
)

store.history.log()   // → [HistoryEntry]
store.history.back()
```
