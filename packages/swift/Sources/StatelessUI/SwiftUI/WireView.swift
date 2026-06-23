// StatelessUI — wireView
// Wires a pure SwiftUI component to live store queries + bound action closures.
//
// Usage:
//
//     let TodoListView = wireView(
//         name: "TodoList",
//         queries: [
//             "todos": ["path": "todos"]
//         ],
//         actions: ["addTodo", "removeTodo"]
//     ) { (props: WireProps) -> AnyView in
//         AnyView(TodoListComponent(todos: props.data["todos"] as? [Doc] ?? [],
//                                   addTodo: props.actions["addTodo"]!))
//     }

import SwiftUI

// MARK: - WireProps

/// The bag of live data + bound action closures delivered to a wired component.
public struct WireProps {
    /// Resolved query results keyed by the name given in the queries dict.
    public let data: [String: Any]
    /// Action closures keyed by action name. Call with an optional payload.
    public let actions: [String: (_ payload: [String: Any]) async throws -> Void]
}

// MARK: - wireView

/// Returns an opaque SwiftUI View that:
///   1. Subscribes to each named query via @QueryWrapper.
///   2. Resolves each named action against the store's registered mutates.
///   3. Calls `view` with the resolved WireProps on every cache change.
///
/// - Parameters:
///   - name: Identifier for the wired view (used in debug descriptions).
///   - queries: Map of logical name → query descriptor dict.
///   - actions: List of action names to expose as callable closures.
///   - view: Pure component factory — receives WireProps, returns AnyView.
public func wireView(
    name: String,
    queries: [String: [String: Any]],
    actions actionNames: [String],
    view component: @escaping (WireProps) -> AnyView
) -> some View {
    WiredView(
        name: name,
        queries: queries,
        actionNames: actionNames,
        component: component
    )
}

// MARK: - WiredView (internal)

private struct WiredView: View {
    let name: String
    let queries: [String: [String: Any]]
    let actionNames: [String]
    let component: (WireProps) -> AnyView

    @Environment(\.store) private var store: Store?
    @State private var data: [String: Any] = [:]
    @State private var subscriptionTask: Task<Void, Never>?

    var body: some View {
        let resolvedActions = buildActions()
        let props = WireProps(data: data, actions: resolvedActions)
        return component(props)
            .task {
                await subscribeToQueries()
            }
    }

    // MARK: - Live query subscriptions

    @MainActor
    private func subscribeToQueries() async {
        guard let store else { return }
        subscriptionTask?.cancel()
        subscriptionTask = Task {
            // Fan out one AsyncStream per query and merge results.
            // Simplified: subscribe to each query and update the data dict.
            await withTaskGroup(of: Void.self) { group in
                for (queryName, descriptor) in queries {
                    group.addTask { @MainActor in
                        let query = buildQuery(from: descriptor)
                        for await docs in store.cache.subscribe(query: query) {
                            guard !Task.isCancelled else { break }
                            data[queryName] = docs
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action resolution

    private func buildActions() -> [String: (_ payload: [String: Any]) async throws -> Void] {
        guard let store else { return [:] }
        var result: [String: (_ payload: [String: Any]) async throws -> Void] = [:]
        for actionName in actionNames {
            // Locate the matching mutate across all configs.
            // Store exposes configs via the mutate dispatch path.
            result[actionName] = { @MainActor payload in
                // Dispatch via the store's action-name based resolution.
                try await store.dispatch(action: actionName, payload: payload)
            }
        }
        return result
    }
}

// MARK: - Query descriptor → Query (shared helper)

internal func buildQuery(from dict: [String: Any]) -> Query {
    let path   = dict["path"]   as? String ?? ""
    let id     = dict["id"]     as? String
    let fields = dict["fields"] as? [String]

    let whereClauses: [WhereClause] = (dict["where"] as? [[String: Any]] ?? []).compactMap { w in
        guard
            let field = w["field"] as? String,
            let opStr = w["op"]    as? String,
            let op    = WhereClause.Operator(rawValue: opStr),
            let value = w["value"] as? AnyHashable
        else { return nil }
        return WhereClause(field: field, op: op, value: value)
    }

    let orderByClauses: [OrderByClause] = (dict["orderBy"] as? [[String: Any]] ?? []).compactMap { o in
        guard let field = o["field"] as? String else { return nil }
        let dir: OrderByClause.Direction =
            (o["direction"] as? String) == "descending" ? .descending : .ascending
        return OrderByClause(field: field, direction: dir)
    }

    return Query(
        path: path,
        id: id,
        where: whereClauses,
        orderBy: orderByClauses,
        fields: fields
    )
}

// MARK: - Store.dispatch (action-name routing)

extension Store {
    /// Dispatches by action name — looks up the matching Mutate across all configs.
    @MainActor
    public func dispatch(
        action: String,
        payload: [String: Any] = [:]
    ) async throws {
        for config in configs.values {
            if let mutate = config.mutates.first(where: { $0.action == action }) {
                try await self.mutate(action: action, payload: payload, using: mutate)
                return
            }
        }
        // If no registered mutate found, no-op (or throw for strict mode).
        // Strict would be: throw StatelessUIError.unknownAction(action)
    }
}
