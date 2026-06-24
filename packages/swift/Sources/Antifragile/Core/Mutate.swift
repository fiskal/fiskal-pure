// Antifragile — Mutate
// Describes a named write. Three creation forms:
//   • write-only     — createMutate(action:write:)
//   • read-then-write — createMutate(action:read:write:)
//   • transaction    — createMutate(action:read:writes:)
//
// Resolution is pure: payload in, [Write] out. Side effects live in Store.mutate.

import Foundation

// MARK: - Mutate

/// A reusable, callable descriptor for a named write.
public struct Mutate: Sendable {
    public let action: String

    // Internal resolver: given a payload and a read handle, produce writes.
    let resolver: @Sendable (
        _ payload: [String: Any],
        _ store: Store
    ) async throws -> [Write]

    // MARK: - Call

    /// Dispatch this mutate with a payload through the store.
    @MainActor
    public func callAsFunction(
        payload: [String: Any] = [:],
        through store: Store
    ) async throws {
        try await store.mutate(action: action, payload: payload, using: self)
    }

    // MARK: Internal resolution (called by Store)
    func resolve(
        payload: [String: Any],
        store: Store
    ) async throws -> [Write] {
        try await resolver(payload, store)
    }
}

// MARK: - Factory: write-only

/// Creates a mutate that produces writes from the payload alone — no reads.
///
///     let addTodo = createMutate(action: "addTodo") { payload in
///         [Write(path: "todos", id: UUID().uuidString, fields: payload)]
///     }
public func createMutate(
    action: String,
    write: @Sendable @escaping (
        _ payload: [String: Any]
    ) throws -> [Write]
) -> Mutate {
    Mutate(action: action) { payload, _ in
        try write(payload)
    }
}

/// Convenience overload returning a single Write.
public func createMutate(
    action: String,
    write: @Sendable @escaping (
        _ payload: [String: Any]
    ) throws -> Write
) -> Mutate {
    Mutate(action: action) { payload, _ in
        [try write(payload)]
    }
}

// MARK: - Factory: read-then-write

/// Creates a mutate that first reads from the current cache, then derives writes.
///
///     let toggleTodo = createMutate(action: "toggleTodo") { payload, read in
///         let id = payload["id"] as! String
///         let current = read(Query(path: "todos", id: id)).first ?? [:]
///         let done = (current["done"] as? Bool) ?? false
///         return [Write(path: "todos", id: id, fields: ["done": !done])]
///     }
@MainActor
public func createMutate(
    action: String,
    read readFn: @Sendable @escaping (
        _ query: Query,
        _ store: Store
    ) -> [Doc],
    write: @Sendable @escaping (
        _ payload: [String: Any],
        _ read: @Sendable (Query) -> [Doc]
    ) async throws -> [Write]
) -> Mutate {
    Mutate(action: action) { payload, store in
        let readHandle: @Sendable (Query) -> [Doc] = { query in
            readFn(query, store)
        }
        return try await write(payload, readHandle)
    }
}

/// Variant where the write closure produces a single Write.
@MainActor
public func createMutate(
    action: String,
    read readFn: @Sendable @escaping (
        _ query: Query,
        _ store: Store
    ) -> [Doc],
    write: @Sendable @escaping (
        _ payload: [String: Any],
        _ read: @Sendable (Query) -> [Doc]
    ) async throws -> Write
) -> Mutate {
    Mutate(action: action) { payload, store in
        let readHandle: @Sendable (Query) -> [Doc] = { query in
            readFn(query, store)
        }
        return [try await write(payload, readHandle)]
    }
}

// MARK: - Factory: transaction (multiple writes from a read pass)

/// Creates a mutate that reads once and produces an ordered slice of writes
/// which the adapter should execute as a transaction.
@MainActor
public func createMutate(
    action: String,
    read readFn: @Sendable @escaping (
        _ query: Query,
        _ store: Store
    ) -> [Doc],
    writes: @Sendable @escaping (
        _ payload: [String: Any],
        _ read: @Sendable (Query) -> [Doc]
    ) async throws -> [Write]
) -> Mutate {
    Mutate(action: action) { payload, store in
        let readHandle: @Sendable (Query) -> [Doc] = { query in
            readFn(query, store)
        }
        return try await writes(payload, readHandle)
    }
}
