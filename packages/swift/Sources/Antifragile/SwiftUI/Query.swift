// Antifragile — @Query property wrapper
// Wires a pure SwiftUI component to a live cache subscription.
// Usage:
//
//     @Query(["path": "todos", "where": [["field": "done", "op": "==", "value": false]])
//     var todos: [Doc]?
//
// wrappedValue is nil during the first frame (loading); populates on first emission.
// projectedValue ($todos) is a Binding for two-way bridging (rare but supported).

import SwiftUI
import Observation

@propertyWrapper
public struct QueryWrapper<T>: DynamicProperty {

    // MARK: - Injected store
    @Environment(\.store) private var store: Store?

    // MARK: - Internal state
    @State private var value: T?
    @State private var task: Task<Void, Never>?
    @State private var lastQuery: Query?

    // MARK: - Descriptor
    private let descriptor: [String: Any]

    // MARK: - Init
    public init(_ descriptor: [String: Any]) {
        self.descriptor = descriptor
    }

    // MARK: - DynamicProperty
    public var wrappedValue: T? {
        get { value }
        nonmutating set { value = newValue }
    }

    public var projectedValue: Binding<T?> {
        Binding(
            get: { value },
            set: { value = $0 }
        )
    }

    public func update() {
        guard let store else { return }
        let query = buildQuery(from: descriptor)
        // Stable-key guard: re-subscribe only when the query actually changes
        // (or no task exists yet). Mirrors useRead.ts's where/fields deps so a
        // single subscription survives unrelated parent re-renders.
        if query == lastQuery, task != nil { return }
        // Cancel any previous subscription task.
        task?.cancel()
        lastQuery = query
        task = Task { @MainActor in
            for await docs in store.cache.subscribe(query: query) {
                guard !Task.isCancelled else { break }
                if T.self == [Doc].self {
                    value = docs as? T
                } else if T.self == Doc.self {
                    value = docs.first as? T
                }
            }
        }
    }

    // MARK: - Descriptor → Query
    private func buildQuery(from dict: [String: Any]) -> Query {
        let path = dict["path"] as? String ?? ""
        let id   = dict["id"]   as? String
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
}

// MARK: - Public typealiases for ergonomic naming

/// Live query that emits a list of documents.
public typealias QueryList = QueryWrapper<[Doc]>

/// Live query that emits a single document.
public typealias QueryDoc = QueryWrapper<Doc>
