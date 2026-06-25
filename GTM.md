# fiskal-pure

## Tagline
Views without data. Data tracks everything.

---

## What It Does
Views display. They cannot break because they have no logic — no hooks, no state, nothing
that can fail. Data tracks every change as a named, serializable write descriptor. When
something breaks, the full changeset is already there: every mutation in order, shippable to
a server, replayable by an AI. Mutations are injected into components as props so testing
a component means passing a function — no provider, no mock store.

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
Hooks are where view bugs live. Every `useState`, `useEffect`, and `useContext` is logic
inside a view. Logic in a view can break, and when it does there is no log and no changeset
— just a stack trace. Antifragile removes hooks from views entirely. A view is a function
that receives data and returns markup; it cannot have a bug. Every write goes through a
named data descriptor so the complete mutation log is always available — an AI can replay
the exact sequence that caused the failure and fix it without a repro case.

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
