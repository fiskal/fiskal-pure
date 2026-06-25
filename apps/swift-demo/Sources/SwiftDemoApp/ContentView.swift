import SwiftUI
import Antifragile

// ---------------------------------------------------------------------------
// Pure views — no store, no @EnvironmentObject. Tested with plain init.
// ---------------------------------------------------------------------------

struct TaskItem: View {
    let task: Task
    let archiveTask: ([String: Any]) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(task.createdAtDisplay)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Archive") {
                archiveTask(["id": task.id])
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// TaskItem injected as a prop — wireView provides the wired version at runtime.
struct TaskList<Item: View>: View {
    let taskIds: [TaskId]
    var TaskItem: (String) -> Item

    var body: some View {
        if taskIds.isEmpty {
            Text("No active tasks. Add one below.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            List(taskIds, id: \.self) { id in
                TaskItem(id)
            }
            .listStyle(.plain)
        }
    }
}

struct AddTask: View {
    let addTask: ([String: Any]) -> Void
    @State private var title = ""

    var body: some View {
        HStack {
            TextField("New task title", text: $title)
                .textFieldStyle(.roundedBorder)
            Button("Add") {
                let t = title.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                addTask(["id": UUID().uuidString, "title": t])
                title = ""
            }
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 8)
    }
}

// ---------------------------------------------------------------------------
// wireView — all connection logic lives here, outside the pure view definitions.
// Pure views above have zero imports from Antifragile.
// ---------------------------------------------------------------------------

// Wires TaskItem: fetches one task by id from the store, exposes archiveTask action.
struct WiredTaskItem: View {
    let taskId: String

    var body: some View {
        wireView(
            name: "TaskItem",
            queries: ["task": ["path": "tasks", "id": taskId]],
            actions: ["archiveTask"]
        ) { (props: WireProps) -> AnyView in
            guard let doc = (props.data["task"] as? [[String: Any]])?.first,
                  let task = Task.from(doc)
            else { return AnyView(EmptyView()) }
            return AnyView(
                SwiftDemoApp.TaskItem(
                    task: task,
                    archiveTask: { payload in
                        Task { try? await props.actions["archiveTask"]?(payload) }
                    }
                )
            )
        }
    }
}

// Wires TaskList: fetches all active task ids.
// WiredTaskItem is injected as the TaskItem prop.
struct WiredTaskList: View {
    var body: some View {
        wireView(
            name: "TaskList",
            queries: ["taskIds": ["path": "tasks", "where": [["field": "status", "op": "==", "value": "active"]]]],
            actions: []
        ) { (props: WireProps) -> AnyView in
            let ids = (props.data["taskIds"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            return AnyView(
                SwiftDemoApp.TaskList(taskIds: ids) { id in
                    WiredTaskItem(taskId: id)
                }
            )
        }
    }
}

// Wires AddTask: exposes addTask action.
struct WiredAddTask: View {
    var body: some View {
        wireView(
            name: "AddTask",
            queries: [:],
            actions: ["addTask"]
        ) { (props: WireProps) -> AnyView in
            AnyView(
                AddTask { payload in
                    Task { try? await props.actions["addTask"]?(payload) }
                }
            )
        }
    }
}

// ---------------------------------------------------------------------------
// App root
// ---------------------------------------------------------------------------

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("fiskal-antifragile — Task Demo")
                .font(.headline)
            WiredTaskList()
            WiredAddTask()
        }
        .padding()
        .frame(maxWidth: 480, maxHeight: .infinity, alignment: .top)
    }
}

// ---------------------------------------------------------------------------
// Previews — pure views with plain props, no store required
// ---------------------------------------------------------------------------

#Preview("TaskItem") {
    TaskItem(
        task: Task(id: "1", title: "Write tests", status: "active",
                   createdAt: Date().timeIntervalSince1970 - 86_400),
        archiveTask: { _ in }
    )
    .padding()
}

#Preview("TaskList — populated") {
    TaskList(
        taskIds: ["1", "2"],
        TaskItem: { id in
            Text("Task \(id)").padding(.vertical, 4)
        }
    )
    .padding()
}

#Preview("TaskList — empty") {
    TaskList(taskIds: [], TaskItem: { id in Text(id) })
        .padding()
}

#Preview("AddTask") {
    AddTask(addTask: { _ in })
        .padding()
}
