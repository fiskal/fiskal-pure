// ---------------------------------------------------------------------------
// Store.swift — task management store with MemoryAdapter
// ---------------------------------------------------------------------------
//
// TaskDoc schema:  { id, title, status, createdAt }
// status values:   "active" | "archived"
//
// DemoStore is an ObservableObject. It owns the FiskalPure store instance and
// exposes mutates as plain methods. Views receive data and closures as
// arguments — they import nothing from FiskalPure.

import Foundation
import Combine
import FiskalPure

// ---------------------------------------------------------------------------
// TaskDoc — concrete type matching the TS demo schema
// ---------------------------------------------------------------------------

struct TaskDoc: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String   // "active" | "archived"
    let createdAt: String
}

// ---------------------------------------------------------------------------
// DemoStore — observable wrapper around the FiskalPure StoreInstance
// ---------------------------------------------------------------------------

final class DemoStore: ObservableObject {
    // Published list of active tasks — views observe this directly.
    @Published private(set) var activeTasks: [TaskDoc] = []

    private let store: StoreInstance
    private var cancellable: Unsubscribe?

    init() {
        store = PureStore(adapter: MemoryAdapter())
        startObserving()
    }

    // ---------------------------------------------------------------------------
    // Internal — subscribe to cache changes
    // ---------------------------------------------------------------------------

    private func startObserving() {
        cancellable = store.subscribe(collection: "tasks") { [weak self] in
            self?.refreshTasks()
        }
        refreshTasks()
    }

    private func refreshTasks() {
        let allDocs = store.readAll(collection: "tasks")
        activeTasks = allDocs
            .compactMap { doc -> TaskDoc? in
                guard
                    let title = doc["title"] as? String,
                    let status = doc["status"] as? String,
                    status == "active",
                    let createdAt = doc["createdAt"] as? String
                else { return nil }
                return TaskDoc(id: doc.id, title: title, status: status, createdAt: createdAt)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // ---------------------------------------------------------------------------
    // Mutates — pure data descriptors executed via the store
    // ---------------------------------------------------------------------------

    /// Create a new active task.
    func addTask(title: String) {
        let id = "task-\(UUID().uuidString)"
        let write = WriteDescriptor(
            collection: "tasks",
            id: id,
            fields: [
                "title": title,
                "status": "active",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ],
            merge: false
        )
        Task { try? await store.write(write) }
    }

    /// Archive an existing task.
    func archiveTask(id: String) {
        let write = WriteDescriptor(
            collection: "tasks",
            id: id,
            fields: ["status": "archived"],
            merge: true
        )
        Task { try? await store.write(write) }
    }
}
