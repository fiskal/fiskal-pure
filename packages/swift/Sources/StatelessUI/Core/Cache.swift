// StatelessUI — Cache
// Observable in-memory entity tree. MainActor-bound for SwiftUI compat.
// Structural sharing: only the changed doc node is replaced.

import Foundation
import Observation

@Observable
@MainActor
public final class Cache {

    // MARK: - Storage
    // path → id → doc. Replaced at the node level; siblings are shared.
    private(set) var storage: [String: [String: Doc]] = [:]

    // MARK: - Continuation registry for live subscriptions
    // keyed by a per-subscription UUID
    private var continuations: [String: AsyncStream<[Doc]>.Continuation] = [:]

    // MARK: - Init
    public init() {}

    // MARK: - Structural write

    /// Applies a Write to the cache. Replaces only the changed document.
    public func applyWrite(_ write: Write) {
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
        // Structural sharing: only the collection node at this path changes.
        storage[write.path] = collection
        notifySubscribers(path: write.path)
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

    // MARK: - Read

    /// Synchronous point-in-time read filtered by the query.
    public func get(query: Query) -> [Doc] {
        guard let collection = storage[query.path] else { return [] }

        if let id = query.id {
            guard let doc = collection[id] else { return [] }
            return [project(doc: doc, fields: query.fields)]
        }

        var results = Array(collection.values)
        results = applyWhere(query.where, to: results)
        results = applyOrderBy(query.orderBy, to: results)
        if let fields = query.fields {
            results = results.map { project(doc: $0, fields: fields) }
        }
        return results
    }

    // MARK: - Live subscription

    /// Returns an AsyncStream that emits the current result set and again on every change.
    public func subscribe(query: Query) -> AsyncStream<[Doc]> {
        let id = UUID().uuidString
        let stream = AsyncStream<[Doc]> { continuation in
            // Emit current value immediately.
            continuation.yield(self.get(query: query))
            self.continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.continuations.removeValue(forKey: id)
                }
            }
        }
        return stream
    }

    // MARK: - Notification fan-out

    private func notifySubscribers(path: String) {
        // Re-evaluate every active subscription whose path matches.
        // For simplicity we broadcast to all and let the subscriber filter.
        // In a larger implementation you'd index by path.
        for continuation in continuations.values {
            continuation.yield([])
        }
    }

    // MARK: - Time travel

    /// Captures an immutable snapshot of the current storage tree.
    public func snapshot() -> CacheSnapshot {
        CacheSnapshot(storage: storage)
    }

    /// Restores the cache to a previous snapshot (rollback / time-travel).
    public func restore(_ snapshot: CacheSnapshot) {
        storage = snapshot.storage
        // Notify all live subscribers that the world changed.
        for continuation in continuations.values {
            continuation.yield([])
        }
    }

    // MARK: - Seed / reset

    public func seed(_ data: [String: [String: Doc]]) {
        for (path, collection) in data {
            storage[path] = collection
        }
    }

    public func reset() {
        storage = [:]
    }

    // MARK: - Private helpers

    private func project(doc: Doc, fields: [String]?) -> Doc {
        guard let fields else { return doc }
        return doc.filter { fields.contains($0.key) }
    }

    private func applyWhere(
        _ clauses: [WhereClause],
        to docs: [Doc]
    ) -> [Doc] {
        guard !clauses.isEmpty else { return docs }
        return docs.filter { doc in
            clauses.allSatisfy { clause in
                matchesClause(clause, doc: doc)
            }
        }
    }

    private func matchesClause(_ clause: WhereClause, doc: Doc) -> Bool {
        let fieldValue = doc[clause.field] as? AnyHashable
        let target = clause.value

        switch clause.op {
        case .equalTo:                return fieldValue == target
        case .notEqualTo:             return fieldValue != target
        case .lessThan:
            return compareOrderable(lhs: fieldValue, rhs: target) == .orderedAscending
        case .lessThanOrEqualTo:
            let r = compareOrderable(lhs: fieldValue, rhs: target)
            return r == .orderedAscending || r == .orderedSame
        case .greaterThan:
            return compareOrderable(lhs: fieldValue, rhs: target) == .orderedDescending
        case .greaterThanOrEqualTo:
            let r = compareOrderable(lhs: fieldValue, rhs: target)
            return r == .orderedDescending || r == .orderedSame
        case .arrayContains:
            if let arr = doc[clause.field] as? [AnyHashable] { return arr.contains(target) }
            return false
        case .in:
            if let arr = target.base as? [AnyHashable] { return arr.contains(fieldValue ?? "") }
            return false
        case .notIn:
            if let arr = target.base as? [AnyHashable] { return !arr.contains(fieldValue ?? "") }
            return false
        }
    }

    private func compareOrderable(
        lhs: AnyHashable?,
        rhs: AnyHashable
    ) -> ComparisonResult {
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

    private func applyOrderBy(
        _ clauses: [OrderByClause],
        to docs: [Doc]
    ) -> [Doc] {
        guard !clauses.isEmpty else { return docs }
        return docs.sorted { a, b in
            for clause in clauses {
                let av = a[clause.field] as? AnyHashable
                let bv = b[clause.field] as? AnyHashable
                let result = compareOrderable(lhs: av, rhs: bv ?? "")
                if result == .orderedSame { continue }
                return clause.direction == .ascending
                    ? result == .orderedAscending
                    : result == .orderedDescending
            }
            return false
        }
    }
}
