import { Profiler, useState, type ProfilerOnRenderCallback } from 'react'
import { wireView } from './store.js'
import { traceRender, traceSubscription, traceMutate, printTraceReport } from './trace.js'

// ---------------------------------------------------------------------------
// Pure components — zero library imports, tested with plain props
// ---------------------------------------------------------------------------

interface Task {
  id: string
  title: string
  status: string
  createdAtDisplay?: string
  statusLabel?: string
}

const TaskItemView = ({
  task,
  archiveTask,
}: {
  task: Task
  archiveTask: (payload: { id: string }) => Promise<unknown>
}) => {
  traceRender('TaskItem')
  return (
    <li className="task-item">
      <span className="task-title">{task.title}</span>
      {task.createdAtDisplay && (
        <span className="task-date">{task.createdAtDisplay}</span>
      )}
      {task.statusLabel && (
        <span className="task-status">{task.statusLabel}</span>
      )}
      <button type="button" onClick={() => archiveTask({ id: task.id })}>
        Archive
      </button>
    </li>
  )
}

// TaskItem is injected by wireView at runtime — the registry matches the prop name.
// The component type is intentionally broad: wireView erases the inner prop type at the
// boundary (see GAPS.md 5e). Runtime is fully safe; cast is at the wires layer only.
const TaskListView = ({
  taskIds,
  TaskItem: Item,
}: {
  taskIds: Array<{ id: string }>
  TaskItem: React.ComponentType<Record<string, unknown>>
}) => {
  traceRender('TaskList')
  return !taskIds || taskIds.length === 0 ? (
    <p className="empty">No active tasks. Add one below.</p>
  ) : (
    <ul>
      {taskIds.map(({ id }) => (
        <Item key={id} taskId={id} />
      ))}
    </ul>
  )
}

const AddTaskView = ({
  addTask,
}: {
  addTask: (payload: { id: string; title: string }) => Promise<unknown>
}) => {
  traceRender('AddTask')
  const [title, setTitle] = useState('')
  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    const t = title.trim()
    if (!t) return
    const payload = { id: `task-${Date.now()}`, title: t }
    traceMutate('addTask', payload)
    void addTask(payload)
    setTitle('')
  }
  return (
    <form onSubmit={handleSubmit}>
      <input
        type="text"
        value={title}
        onChange={e => setTitle(e.target.value)}
        placeholder="New task title"
        aria-label="New task title"
      />
      <button type="submit">Add</button>
    </form>
  )
}

// ---------------------------------------------------------------------------
// wireView — wiring layer. Pure views above have zero library imports.
// ---------------------------------------------------------------------------

// wireView generics tie the component type to the external (own) props shape,
// not the internal props. Known typing gap (see GAPS.md 5e) — cast through any.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyComponent = React.ComponentType<any>

// TaskItem: fetches one task by id, exposes archiveTask action.
const TaskItem = wireView(
  'TaskItem',
  ({ taskId }: { taskId: string }) => ({
    task: {
      path:   'tasks',
      id:     taskId,
      fields: ['title', 'status', 'createdAt'],
    },
  }),
  ['archiveTask'],
  TaskItemView as AnyComponent,
)

// TaskList: fetches all active task ids.
// TaskItem is injected automatically — prop name matches the registered name above.
const TaskList = wireView(
  'TaskList',
  { taskIds: { path: 'tasks', where: { status: 'active' } } },
  [],
  TaskListView as AnyComponent,
)

// AddTask: exposes addTask action.
const AddTask = wireView('AddTask', {}, ['addTask'], AddTaskView as AnyComponent)

// ---------------------------------------------------------------------------
// Profiler callback — fires on every React commit (dev + prod builds with
// react-dom/profiling). Logs phase (mount/update) and actual render duration.
// ---------------------------------------------------------------------------

const onRender: ProfilerOnRenderCallback = (
  id,
  phase,
  actualDuration,
  baseDuration,
) => {
  if (actualDuration > 1) {
    console.debug(
      `[profiler] ${id} ${phase} — actual: ${actualDuration.toFixed(2)}ms  base: ${baseDuration.toFixed(2)}ms`,
    )
  }

  // Log subscription timing from within the Profiler so we can correlate
  // render duration with incoming subscription callbacks.
  traceSubscription(id, 0, actualDuration)
}

// ---------------------------------------------------------------------------
// App root — wrapped in React.Profiler for timing data
// ---------------------------------------------------------------------------

export default function App() {
  return (
    <Profiler id="App" onRender={onRender}>
      <h1>antifragile — Task Demo</h1>
      <TaskList />
      <AddTask />
      {import.meta.env.DEV && (
        <button
          type="button"
          style={{ marginTop: '2rem', fontSize: '0.75rem', opacity: 0.5 }}
          onClick={printTraceReport}
        >
          print trace report
        </button>
      )}
    </Profiler>
  )
}
