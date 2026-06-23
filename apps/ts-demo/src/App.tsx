// ---------------------------------------------------------------------------
// App.tsx — task management demo
// ---------------------------------------------------------------------------
//
// Architecture:
//   - Pure components receive only props; they import nothing from the store.
//   - Wired versions (WiredTaskItem, WiredTaskList, AddTask) connect to the
//     store via useRead and the mutate functions from store.ts.
//   - This separation means pure components are testable with plain props.

import { useState } from 'react'
import { useRead } from '@fiskal/pure-ts'
import type { Doc } from '@fiskal/pure-ts'
import { store, addTask, archiveTask } from './store.js'

// ---------------------------------------------------------------------------
// Pure components — no store imports
// ---------------------------------------------------------------------------

interface TaskItemProps {
  task: { id: string; title: string; status: string }
  onArchive: (id: string) => void
}

export function TaskItem({ task, onArchive }: TaskItemProps) {
  return (
    <li>
      <span>{task.title}</span>
      <button type="button" onClick={() => onArchive(task.id)}>
        Archive
      </button>
    </li>
  )
}

interface TaskListProps {
  tasks: Array<{ id: string; title: string; status: string }>
  onArchive: (id: string) => void
}

export function TaskList({ tasks, onArchive }: TaskListProps) {
  if (tasks.length === 0) {
    return <p className="empty">No active tasks. Add one below.</p>
  }
  return (
    <ul>
      {tasks.map(task => (
        <TaskItem key={task.id} task={task} onArchive={onArchive} />
      ))}
    </ul>
  )
}

interface AddTaskProps {
  onAdd: (title: string) => void
}

export function AddTask({ onAdd }: AddTaskProps) {
  const [title, setTitle] = useState('')

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const trimmed = title.trim()
    if (!trimmed) return
    onAdd(trimmed)
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
// Wired versions — connect pure components to the store
// ---------------------------------------------------------------------------
//
// Wiring lives here, outside the pure component definitions, so the components
// themselves stay import-free from the library.

function WiredTaskList() {
  const result = useRead(store, { collection: 'tasks', where: { status: 'active' } })
  const tasks = Array.isArray(result) ? (result as Doc[]) : []

  function handleArchive(id: string) {
    void archiveTask({ id })
  }

  return (
    <TaskList
      tasks={tasks as Array<{ id: string; title: string; status: string }>}
      onArchive={handleArchive}
    />
  )
}

function WiredAddTask() {
  function handleAdd(title: string) {
    void addTask({
      id: `task-${Date.now()}`,
      title,
    })
  }

  return <AddTask onAdd={handleAdd} />
}

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

export default function App() {
  return (
    <>
      <h1>fiskal-pure — Task List Demo</h1>
      <WiredTaskList />
      <WiredAddTask />
    </>
  )
}
