import Foundation
import Antifragile

// ---------------------------------------------------------------------------
// Task — plain struct, no store dependency. Tested with plain init.
// ---------------------------------------------------------------------------

struct Task: Identifiable, Equatable {
    let id: String
    let title: String
    let status: String   // "active" | "archived"
    let createdAt: TimeInterval

    var createdAtDisplay: String {
        Date(timeIntervalSince1970: createdAt)
            .formatted(.dateTime.month(.abbreviated).day().year())
    }

    var statusLabel: String {
        status == "active" ? "In Progress" : "Archived"
    }

    static func from(_ doc: [String: Any]) -> Task? {
        guard
            let id        = doc["id"]        as? String,
            let title     = doc["title"]     as? String,
            let status    = doc["status"]    as? String,
            let createdAt = doc["createdAt"] as? TimeInterval
        else { return nil }
        return Task(id: id, title: title, status: status, createdAt: createdAt)
    }
}

typealias TaskId = String

// ---------------------------------------------------------------------------
// Mutates — named write descriptors, standalone
// ---------------------------------------------------------------------------

let addTask = createMutate(action: "AddTask") { payload in
    guard let id    = payload["id"]    as? String,
          let title = payload["title"] as? String else { return [] }
    return [Write(path: "tasks", id: id, fields: [
        "title":     title,
        "status":    "active",
        "createdAt": Date().timeIntervalSince1970,
    ])]
}

let archiveTask = createMutate(action: "ArchiveTask") { payload in
    guard let id = payload["id"] as? String else { return [] }
    return [Write(path: "tasks", id: id, fields: ["status": "archived"])]
}

// ---------------------------------------------------------------------------
// Store — seed data + mutates at the bottom
// ---------------------------------------------------------------------------

let store = Store.createStore {
    BackingStoreConfig(
        name: "default",
        adapter: MemoryAdapter(initial: [
            "tasks": [
                "task-1": [
                    "id": "task-1",
                    "title": "Deploy to production",
                    "status": "active",
                    "createdAt": Date().timeIntervalSince1970 - 86_400,
                ],
                "task-2": [
                    "id": "task-2",
                    "title": "Write release notes",
                    "status": "active",
                    "createdAt": Date().timeIntervalSince1970 - 3_600,
                ],
                "task-3": [
                    "id": "task-3",
                    "title": "Update dependencies",
                    "status": "active",
                    "createdAt": Date().timeIntervalSince1970,
                ],
            ],
        ]),
        mutates: [addTask, archiveTask]
    )
}
