# fiskal-pure

## Tagline
Anti-fragile apps. No assumptions when something breaks.

---

## What It Does
fiskal-pure gives React and SwiftUI apps an anti-fragile state layer: every write is a named, serializable descriptor so the complete action log is always available — shippable to a server on failure, replayable without a repro case. All wiring is declared outside components, making it structurally impossible to mix logic into UI.

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
Every other state library treats writes as function calls — opaque, un-serializable, gone the moment they run. fiskal-pure makes every write a data descriptor. The log is always there. When something breaks you have the exact sequence that caused it, not a stack trace and a guess. At the same time, components never import the library — all wiring lives outside — so agents and developers cannot mix business logic into views even if they try.

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
