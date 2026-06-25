// Antifragile — wireView
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
//     ) { (props: WireProps) in
//         TodoListComponent(todos: props.data["todos"] as? [Doc] ?? [],
//                           addTodo: props.actions["addTodo"]!)
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
///   - view: Pure component factory — receives WireProps, returns a concrete View.
///
/// The factory's concrete return type is preserved (no AnyView erasure), so
/// SwiftUI keeps structural identity and can diff the wired component. For the
/// rare heterogeneous case where a caller must return different view types per
/// branch, wrap explicitly in `AnyView` and call `wireView<AnyView>(...)`.
public func wireView<Content: View>(
    name: String,
    queries: [String: [String: Any]],
    actions actionNames: [String],
    view component: @escaping (WireProps) -> Content
) -> some View {
    WiredView(
        name: name,
        queries: queries,
        actionNames: actionNames,
        component: component
    )
}

// MARK: - WiredView (internal)

private struct WiredView<Content: View>: View {
    let name: String
    let queries: [String: [String: Any]]
    let actionNames: [String]
    let component: (WireProps) -> Content

    @Environment(\.store) private var store: Store?
    @State private var data: [String: Any] = [:]

    /// Stable key over the query set — re-subscribe only when it changes.
    private var queriesKey: String {
        queries.keys.sorted().joined(separator: ",")
    }

    var body: some View {
        let resolvedActions = buildActions()
        let props = WireProps(data: data, actions: resolvedActions)
        return component(props)
            .task(id: queriesKey) {
                await subscribeToQueries()
            }
    }

    // MARK: - Live query subscriptions

    @MainActor
    private func subscribeToQueries() async {
        guard let store else { return }
        // Run the fan-out as a structured child of the `.task` modifier so
        // SwiftUI cancels it (and the per-query AsyncStream loops, via the
        // `guard !Task.isCancelled` below) automatically on disappear.
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

/// Raised when a wired action name resolves to no registered mutate.
/// Surfacing this (rather than silently no-opping) preserves the replay premise:
/// every dispatched action must produce a logged, replayable write.
public enum DispatchError: Error, Sendable {
    /// No registered mutate matched the given action name. Carries the name.
    case unknownAction(String)
}

extension Store {
    /// Dispatches by action name — looks up the matching Mutate across all configs.
    /// First-wins on duplicate action names across configs.
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
        // No registered mutate matched — never silently no-op: a dispatched
        // action with no write would break the replay log.
        throw DispatchError.unknownAction(action)
    }
}
