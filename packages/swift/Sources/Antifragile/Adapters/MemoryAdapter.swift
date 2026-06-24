// Antifragile — MemoryAdapter
// Pure in-memory backing store. Default for tests, previews, and offline-first seeding.
// Thread-safe via an internal actor.

import Foundation

// MARK: - MemoryAdapter

public struct MemoryAdapter: Adapter {

    // The actor holds all mutable state so MemoryAdapter can remain a Sendable struct.
    private let state: MemoryState

    public init(initial: [String: [String: Doc]] = [:]) {
        self.state = MemoryState(initial: initial)
    }

    // MARK: - Adapter: subscribe

    public func subscribe(
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) -> @Sendable () -> Void {
        let id = UUID().uuidString
        let capturedState = state

        Task {
            // Emit current value immediately.
            let initial = await capturedState.query(query)
            onChange(initial)
            // Register for future changes.
            await capturedState.addSubscriber(id: id, query: query, onChange: onChange)
        }

        return {
            Task {
                await capturedState.removeSubscriber(id: id)
            }
        }
    }

    // MARK: - Adapter: write

    public func write(_ operation: WriteOperation) async throws {
        switch operation {
        case .single(let w):
            await state.applyWrite(w)
        case .batch(let writes), .transaction(let writes):
            for w in writes {
                await state.applyWrite(w)
            }
        }
    }

    // MARK: - Adapter: query

    public func query(_ query: Query) async throws -> [Doc] {
        await state.query(query)
    }
}

// MARK: - MemoryState (internal actor)

private actor MemoryState {

    // path → id → doc
    private var storage: [String: [String: Doc]]

    // Active subscribers: id → (query, onChange)
    private var subscribers: [String: (Query, @Sendable ([Doc]) -> Void)] = [:]

    init(initial: [String: [String: Doc]]) {
        self.storage = initial
    }

    // MARK: - Write

    func applyWrite(_ write: Write) {
        var collection = storage[write.path] ?? [:]
        var doc = collection[write.id] ?? [:]

        for (key, value) in write.fields {
            if let op = value as? AtomicOp {
                applyAtomicOp(op, key: key, into: &doc)
            } else {
                doc[key] = value
            }
        }

        collection[write.id] = doc
        storage[write.path] = collection

        // Fan-out to matching subscribers.
        for (_, (q, onChange)) in subscribers {
            if q.path == write.path || q.path.isEmpty {
                let results = executeQuery(q)
                onChange(results)
            }
        }
    }

    private func applyAtomicOp(
        _ op: AtomicOp,
        key: String,
        into doc: inout Doc
    ) {
        switch op {
        case .delete:
            doc.removeValue(forKey: key)
        case .serverTimestamp:
            doc[key] = Date.now
        case .increment(let delta):
            let current = (doc[key] as? Double) ?? 0.0
            doc[key] = current + delta
        case .arrayUnion(let element):
            var arr = (doc[key] as? [AnyHashable]) ?? []
            if !arr.contains(element) { arr.append(element) }
            doc[key] = arr
        case .arrayRemove(let element):
            var arr = (doc[key] as? [AnyHashable]) ?? []
            arr.removeAll { $0 == element }
            doc[key] = arr
        }
    }

    // MARK: - Query

    func query(_ q: Query) -> [Doc] {
        executeQuery(q)
    }

    private func executeQuery(_ q: Query) -> [Doc] {
        guard let collection = storage[q.path] else { return [] }

        if let id = q.id {
            guard let doc = collection[id] else { return [] }
            return [project(doc, fields: q.fields)]
        }

        var results = Array(collection.values)
        results = applyWhere(q.where, to: results)
        results = applyOrderBy(q.orderBy, to: results)
        if let fields = q.fields {
            results = results.map { project($0, fields: fields) }
        }
        return results
    }

    // MARK: - Subscribers

    func addSubscriber(
        id: String,
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) {
        subscribers[id] = (query, onChange)
    }

    func removeSubscriber(id: String) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Filter helpers

    private func project(_ doc: Doc, fields: [String]?) -> Doc {
        guard let fields else { return doc }
        return doc.filter { fields.contains($0.key) }
    }

    private func applyWhere(_ clauses: [WhereClause], to docs: [Doc]) -> [Doc] {
        guard !clauses.isEmpty else { return docs }
        return docs.filter { doc in
            clauses.allSatisfy { matchesClause($0, doc: doc) }
        }
    }

    private func matchesClause(_ clause: WhereClause, doc: Doc) -> Bool {
        let fieldValue = doc[clause.field] as? AnyHashable
        let target = clause.value

        switch clause.op {
        case .equalTo:             return fieldValue == target
        case .notEqualTo:          return fieldValue != target
        case .lessThan:
            return compare(fieldValue, target) == .orderedAscending
        case .lessThanOrEqualTo:
            let r = compare(fieldValue, target)
            return r == .orderedAscending || r == .orderedSame
        case .greaterThan:
            return compare(fieldValue, target) == .orderedDescending
        case .greaterThanOrEqualTo:
            let r = compare(fieldValue, target)
            return r == .orderedDescending || r == .orderedSame
        case .arrayContains:
            if let arr = doc[clause.field] as? [AnyHashable] { return arr.contains(target) }
            return false
        case .in:
            guard let fv = fieldValue else { return false }
            if let arr = target.base as? [AnyHashable] { return arr.contains(fv) }
            return false
        case .notIn:
            guard let fv = fieldValue else { return true }
            if let arr = target.base as? [AnyHashable] { return !arr.contains(fv) }
            return false
        }
    }

    private func compare(_ lhs: AnyHashable?, _ rhs: AnyHashable) -> ComparisonResult {
        if let l = lhs?.base as? Double, let r = rhs.base as? Double {
            return l < r ? .orderedAscending : l > r ? .orderedDescending : .orderedSame
        }
        if let l = lhs?.base as? String, let r = rhs.base as? String {
            return l.compare(r)
        }
        if let l = lhs?.base as? Date, let r = rhs.base as? Date {
            return l.compare(r)
        }
        return .orderedSame
    }

    private func applyOrderBy(_ clauses: [OrderByClause], to docs: [Doc]) -> [Doc] {
        guard !clauses.isEmpty else { return docs }
        return docs.sorted { a, b in
            for clause in clauses {
                let av = a[clause.field] as? AnyHashable
                let bv = b[clause.field] as? AnyHashable
                let result = compare(av, bv ?? AnyHashable(""))
                if result == .orderedSame { continue }
                return clause.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }
    }
}
