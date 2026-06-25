import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
import { Profiler, useState } from 'react';
import { wireView } from './store.js';
import { traceRender, traceSubscription, traceMutate, printTraceReport } from './trace.js';
const TaskItemView = ({ task, archiveTask, }) => {
    traceRender('TaskItem');
    return (_jsxs("li", { className: "task-item", children: [_jsx("span", { className: "task-title", children: task.title }), task.createdAtDisplay && (_jsx("span", { className: "task-date", children: task.createdAtDisplay })), task.statusLabel && (_jsx("span", { className: "task-status", children: task.statusLabel })), _jsx("button", { type: "button", onClick: () => archiveTask({ id: task.id }), children: "Archive" })] }));
};
// TaskItem is injected by wireView at runtime — the registry matches the prop name.
// The component type is intentionally broad: wireView erases the inner prop type at the
// boundary (see GAPS.md 5e). Runtime is fully safe; cast is at the wires layer only.
const TaskListView = ({ taskIds, TaskItem: Item, }) => {
    traceRender('TaskList');
    return !taskIds || taskIds.length === 0 ? (_jsx("p", { className: "empty", children: "No active tasks. Add one below." })) : (_jsx("ul", { children: taskIds.map(({ id }) => (_jsx(Item, { taskId: id }, id))) }));
};
const AddTaskView = ({ addTask, }) => {
    traceRender('AddTask');
    const [title, setTitle] = useState('');
    const handleSubmit = (e) => {
        e.preventDefault();
        const t = title.trim();
        if (!t)
            return;
        const payload = { id: `task-${Date.now()}`, title: t };
        traceMutate('addTask', payload);
        void addTask(payload);
        setTitle('');
    };
    return (_jsxs("form", { onSubmit: handleSubmit, children: [_jsx("input", { type: "text", value: title, onChange: e => setTitle(e.target.value), placeholder: "New task title", "aria-label": "New task title" }), _jsx("button", { type: "submit", children: "Add" })] }));
};
// TaskItem: fetches one task by id, exposes archiveTask action.
const TaskItem = wireView('TaskItem', ({ taskId }) => ({
    task: {
        path: 'tasks',
        id: taskId,
        fields: ['title', 'status', 'createdAt'],
    },
}), ['archiveTask'], TaskItemView);
// TaskList: fetches all active task ids.
// TaskItem is injected automatically — prop name matches the registered name above.
const TaskList = wireView('TaskList', { taskIds: { path: 'tasks', where: { status: 'active' } } }, [], TaskListView);
// AddTask: exposes addTask action.
const AddTask = wireView('AddTask', {}, ['addTask'], AddTaskView);
// ---------------------------------------------------------------------------
// Profiler callback — fires on every React commit (dev + prod builds with
// react-dom/profiling). Logs phase (mount/update) and actual render duration.
// ---------------------------------------------------------------------------
const onRender = (id, phase, actualDuration, baseDuration) => {
    if (actualDuration > 1) {
        console.debug(`[profiler] ${id} ${phase} — actual: ${actualDuration.toFixed(2)}ms  base: ${baseDuration.toFixed(2)}ms`);
    }
    // Log subscription timing from within the Profiler so we can correlate
    // render duration with incoming subscription callbacks.
    traceSubscription(id, 0, actualDuration);
};
// ---------------------------------------------------------------------------
// App root — wrapped in React.Profiler for timing data
// ---------------------------------------------------------------------------
export default function App() {
    return (_jsxs(Profiler, { id: "App", onRender: onRender, children: [_jsx("h1", { children: "antifragile \u2014 Task Demo" }), _jsx(TaskList, {}), _jsx(AddTask, {}), import.meta.env.DEV && (_jsx("button", { type: "button", style: { marginTop: '2rem', fontSize: '0.75rem', opacity: 0.5 }, onClick: printTraceReport, children: "print trace report" }))] }));
}
