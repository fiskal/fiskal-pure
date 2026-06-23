// ---------------------------------------------------------------------------
// ContentView.swift — pure views + wired views for the task demo
// ---------------------------------------------------------------------------
//
// Pure views: TaskItem, TaskList, AddTask
//   - Receive only value-type arguments (structs + closures).
//   - Zero imports from FiskalPure.
//   - Testable with plain struct init; no environment, no store.
//
// Wired views: WiredTaskItem, WiredTaskList, WiredContentView
//   - Read from DemoStore via @EnvironmentObject.
//   - Pass data and closures into the pure views.
//   - All store coupling lives here, not in the pure views.

import SwiftUI

// ---------------------------------------------------------------------------
// Pure views
// ---------------------------------------------------------------------------

/// A single task row. No store knowledge. Testable with plain init.
struct TaskItem: View {
    let task: TaskDoc
    let onArchive: (String) -> Void

    var body: some View {
        HStack {
            Text(task.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Archive") {
                onArchive(task.id)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// A list of tasks. Pure function of its arguments.
struct TaskList: View {
    let tasks: [TaskDoc]
    let onArchive: (String) -> Void

    var body: some View {
        if tasks.isEmpty {
            Text("No active tasks. Add one below.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(tasks) { task in
                TaskItem(task: task, onArchive: onArchive)
            }
            .listStyle(.plain)
        }
    }
}

/// Add-task form. Stateful for the text field only; all writes go through the callback.
struct AddTask: View {
    let onAdd: (String) -> Void

    @State private var title = ""

    var body: some View {
        HStack {
            TextField("New task title", text: $title)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let trimmed = title.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                onAdd(trimmed)
                title = ""
            }
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 8)
    }
}

// ---------------------------------------------------------------------------
// Wired views — connect pure views to DemoStore
// ---------------------------------------------------------------------------
//
// All @EnvironmentObject reads happen here. The pure views above never see
// the store. This is the wireView pattern in vanilla SwiftUI.

/// Wired version of TaskItem — reads from DemoStore for a specific task id.
/// (Included for symmetry with the TS wireView pattern; in practice WiredTaskList
/// renders all active tasks without needing per-item wiring.)
struct WiredTaskItem: View {
    let taskId: String
    @EnvironmentObject private var demoStore: DemoStore

    var body: some View {
        if let task = demoStore.activeTasks.first(where: { $0.id == taskId }) {
            TaskItem(task: task) { id in
                demoStore.archiveTask(id: id)
            }
        }
    }
}

/// Wired version of TaskList — reads all active tasks from DemoStore.
struct WiredTaskList: View {
    @EnvironmentObject private var demoStore: DemoStore

    var body: some View {
        TaskList(tasks: demoStore.activeTasks) { id in
            demoStore.archiveTask(id: id)
        }
    }
}

/// Root content view — assembles the wired task list and add-task form.
struct WiredContentView: View {
    @EnvironmentObject private var demoStore: DemoStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("fiskal-pure — Task List Demo")
                .font(.headline)
            WiredTaskList()
            AddTask { title in
                demoStore.addTask(title: title)
            }
        }
        .padding()
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .top)
    }
}

// ---------------------------------------------------------------------------
// Previews
// ---------------------------------------------------------------------------

#Preview("TaskItem") {
    TaskItem(
        task: TaskDoc(id: "1", title: "Write tests", status: "active", createdAt: "2026-06-23T10:00:00Z"),
        onArchive: { _ in }
    )
    .padding()
}

#Preview("TaskList — populated") {
    TaskList(
        tasks: [
            TaskDoc(id: "1", title: "Write tests", status: "active", createdAt: "2026-06-23T10:00:00Z"),
            TaskDoc(id: "2", title: "Ship it", status: "active", createdAt: "2026-06-23T10:01:00Z"),
        ],
        onArchive: { _ in }
    )
    .padding()
}

#Preview("TaskList — empty") {
    TaskList(tasks: [], onArchive: { _ in })
        .padding()
}

#Preview("AddTask") {
    AddTask(onAdd: { _ in })
        .padding()
}

#Preview("WiredContentView") {
    WiredContentView()
        .environmentObject(DemoStore())
}
