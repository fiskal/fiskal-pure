// StatelessUI — Core Types
// All shared value types. No business logic here.

import Foundation

// MARK: - Primitives

/// An untyped document: field name → value.
public typealias Doc = [String: Any]

// MARK: - Query

/// Describes a live read from the store.
public struct Query: Sendable, Equatable {
    public let path: String
    public let id: String?
    public let `where`: [WhereClause]
    public let orderBy: [OrderByClause]
    public let fields: [String]?

    public init(
        path: String,
        id: String? = nil,
        where clauses: [WhereClause] = [],
        orderBy: [OrderByClause] = [],
        fields: [String]? = nil
    ) {
        self.path = path
        self.id = id
        self.where = clauses
        self.orderBy = orderBy
        self.fields = fields
    }
}

// MARK: - Where / OrderBy

public struct WhereClause: Sendable, Equatable {
    public enum Operator: String, Sendable {
        case equalTo       = "=="
        case notEqualTo    = "!="
        case lessThan      = "<"
        case lessThanOrEqualTo    = "<="
        case greaterThan          = ">"
        case greaterThanOrEqualTo = ">="
        case arrayContains = "array-contains"
        case `in`          = "in"
        case notIn         = "not-in"
    }

    public let field: String
    public let op: Operator
    public let value: AnyHashable

    public init(field: String, op: Operator, value: AnyHashable) {
        self.field = field
        self.op = op
        self.value = value
    }
}

public struct OrderByClause: Sendable, Equatable {
    public enum Direction: String, Sendable { case ascending, descending }
    public let field: String
    public let direction: Direction

    public init(field: String, direction: Direction = .ascending) {
        self.field = field
        self.direction = direction
    }
}

// MARK: - Write

/// A single document write: the field map may contain AtomicOp sentinels.
public struct Write: Sendable {
    public let path: String
    public let id: String
    /// Plain values or AtomicOp boxed values.
    public let fields: [String: Any]

    public init(path: String, id: String, fields: [String: Any]) {
        self.path = path
        self.id = id
        self.fields = fields
    }
}

/// Groups one or more writes for dispatch.
public enum WriteOperation: Sendable {
    case single(Write)
    case batch([Write])
    case transaction([Write])
}

// MARK: - Atomic ops

/// Sentinel values placed inside a Write.fields map.
public enum AtomicOp: Sendable {
    case delete
    case serverTimestamp
    case increment(Double)
    case arrayUnion(AnyHashable)
    case arrayRemove(AnyHashable)
}

// MARK: - History

public struct HistoryEntry: Sendable {
    public let action: String
    public let writes: [Write]
    public let at: Date

    public init(action: String, writes: [Write], at: Date = .now) {
        self.action = action
        self.writes = writes
        self.at = at
    }
}

// MARK: - Cache snapshot (time travel pointer)

/// Lightweight pointer to an immutable entity-tree snapshot.
/// Holds a full copy of the cache storage at a moment in time.
public struct CacheSnapshot: Sendable {
    /// path → id → doc
    let storage: [String: [String: Doc]]

    init(storage: [String: [String: Doc]]) {
        self.storage = storage
    }
}

// MARK: - Adapter protocol

/// Every backing store (Memory, CloudKit, NSUserDefaults …) conforms to this.
public protocol Adapter: Sendable {
    /// Subscribe to changes matching `query`. Returns a cancellation closure.
    func subscribe(
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) -> @Sendable () -> Void

    /// Persist one write operation to the backing store.
    func write(_ operation: WriteOperation) async throws

    /// One-shot fetch (optional — adapters that don't implement it return nil).
    func query(_ query: Query) async throws -> [Doc]
}

/// Default no-op query so most adapters only implement subscribe + write.
extension Adapter {
    public func query(_ query: Query) async throws -> [Doc] { [] }
}
