// Antifragile — Store
// The single application store. Created once; injected via SwiftUI environment.

import Foundation
import Observation
import SwiftUI

// MARK: - BackingStoreConfig

/// One named backing store slice: adapter + models + registered mutates.
public struct BackingStoreConfig: Sendable {
    public let name: String
    public let adapter: any Adapter
    public let models: [String]        // collection paths owned by this slice
    public let mutates: [Mutate]

    public init(
        name: String,
        adapter: any Adapter,
        models: [String] = [],
        mutates: [Mutate] = []
    ) {
        self.name = name
        self.adapter = adapter
        self.models = models
        self.mutates = mutates
    }
}

// MARK: - StoreBuilder

/// DSL result builder for composing multiple BackingStoreConfig blocks.
@resultBuilder
public enum StoreBuilder {
    public static func buildBlock(_ configs: BackingStoreConfig...) -> [BackingStoreConfig] {
        configs
    }
    public static func buildBlock(_ configs: [BackingStoreConfig]) -> [BackingStoreConfig] {
        configs
    }
    public static func buildExpression(_ config: BackingStoreConfig) -> [BackingStoreConfig] {
        [config]
    }
    public static func buildArray(_ components: [[BackingStoreConfig]]) -> [BackingStoreConfig] {
        components.flatMap { $0 }
    }
    public static func buildOptional(_ component: [BackingStoreConfig]?) -> [BackingStoreConfig] {
        component ?? []
    }
    public static func buildEither(first: [BackingStoreConfig]) -> [BackingStoreConfig] { first }
    public static func buildEither(second: [BackingStoreConfig]) -> [BackingStoreConfig] { second }
}

// MARK: - Store

@Observable
@MainActor
public final class Store {

    // MARK: - Public state
    public let cache: Cache
    public let history: HistoryLog

    // MARK: - Internals
    var configs: [String: BackingStoreConfig] = [:]
    private var adapterSubscriptions: [() -> Void] = []

    // MARK: - Init (private — use createStore)
    private init(configs: [BackingStoreConfig]) {
        self.cache = Cache()
        self.history = HistoryLog()

        for config in configs {
            self.configs[config.name] = config
        }
    }

    // MARK: - Factory

    /// Primary entry point. One store per app.
    ///
    ///     let store = createStore {
    ///         BackingStoreConfig(
    ///             name: "main",
    ///             adapter: MemoryAdapter(),
    ///             models: ["todos"],
    ///             mutates: [addTodo, removeTodo]
    ///         )
    ///     }
    public static func createStore(
        @StoreBuilder _ builder: () -> [BackingStoreConfig]
    ) -> Store {
        let store = Store(configs: builder())
        return store
    }

    // MARK: - Read

    /// Type-erased synchronous read. Returns nil when no match.
    public func get<T>(query: Query) -> T? {
        let docs = cache.get(query: query)
        if T.self == [Doc].self { return docs as? T }
        if T.self == Doc.self   { return docs.first as? T }
        return nil
    }

    // MARK: - Mutate

    /// Dispatch a named action with a payload.
    ///
    /// - Optimistic: writes hit the cache synchronously.
    /// - Async remote write follows.
    /// - On failure: cache rolls back to the pre-write snapshot.
    public func mutate(
        action: String,
        payload: [String: Any] = [:],
        using mutateDescriptor: Mutate
    ) async throws {
        let writes = try await mutateDescriptor.resolve(payload: payload, store: self)
        let snapshot = cache.snapshot()

        // Optimistic: apply to cache immediately.
        for write in writes {
            cache.applyWrite(write)
        }

        // Append to history.
        history.append(HistoryEntry(action: action, writes: writes))

        // Persist to all adapters. On failure, roll back.
        do {
            for config in configs.values {
                let relevant = writes.filter { w in config.models.contains(w.path) }
                if relevant.isEmpty { continue }
                let op: WriteOperation = relevant.count == 1
                    ? .single(relevant[0])
                    : .batch(relevant)
                try await config.adapter.write(op)
            }
        } catch {
            // Rollback optimistic update.
            cache.restore(snapshot)

            // Write error doc to errors/ collection (in-memory only, never remote).
            let errorId = "\(action)-\(Int(Date().timeIntervalSince1970 * 1000))"
            let errorWrite = Write(
                path: "errors",
                id: errorId,
                fields: [
                    "action":   action,
                    "kind":     classifyError(error),
                    "message":  error.localizedDescription,
                    "at":       Date().timeIntervalSince1970,
                    "resolved": false,
                ]
            )
            cache.applyWrite(errorWrite)

            throw error
        }
    }

    // MARK: - Error classification

    private func classifyError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("permission") || msg.contains("forbidden") || msg.contains("unauthorized") { return "permission" }
        if msg.contains("network") || msg.contains("timeout") || msg.contains("offline") || msg.contains("connection") { return "network" }
        if msg.contains("conflict") { return "conflict" }
        if msg.contains("validation") || msg.contains("invalid") || msg.contains("schema") { return "validation" }
        return "unknown"
    }

    // MARK: - Seed / reset

    /// Seed the in-memory cache with initial data (useful for tests and previews).
    public func seed(_ data: [String: [String: Doc]]) {
        cache.seed(data)
    }

    public func reset() {
        cache.reset()
        history.clear()
    }
}

// MARK: - SwiftUI environment key

private struct StoreKey: EnvironmentKey {
    static let defaultValue: Store? = nil
}

extension EnvironmentValues {
    public var store: Store? {
        get { self[StoreKey.self] }
        set { self[StoreKey.self] = newValue }
    }
}

extension View {
    /// Injects the store into the SwiftUI environment.
    public func environment(_ store: Store) -> some View {
        self.environment(\.store, store)
    }
}
