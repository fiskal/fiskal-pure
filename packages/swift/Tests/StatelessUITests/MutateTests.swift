// ---------------------------------------------------------------------------
// MutateTests.swift — XCTest suite for createMutate (optimistic + rollback)
// ---------------------------------------------------------------------------
//
// All tests are marked skip at sprint-plan time.
// Unskip one ADR at a time in Step 3 (see CLAUDE.md §3.1).
//
// Coverage:
//   - Write-only mutate updates the cache synchronously (optimistic)
//   - Read-then-write resolves reads from cache before writing
//   - Transaction applies all writes atomically
//   - Optimistic update visible before remote resolves
//   - Rollback on remote failure
//   - resolveWrites returns descriptors without side effects

import XCTest
@testable import StatelessUI

final class MutateTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Write-only mutate
    // -----------------------------------------------------------------------

    func testWriteOnlyMutateUpdatesCacheSync() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // The cache must reflect the write before the remote adapter resolves.
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed([
            "tasks": [["id": "t1", "title": "Original", "done": false]]
        ])

        var cacheStateInsideWrite: Doc? = nil

        let complete = createMutate(store: store) { payload -> WriteOperation in
            // Intercept — capture cache state when the adapter write fires.
            .single(WriteDescriptor(
                collection: "tasks",
                id: payload["id"] as! String,
                fields: ["done": .value(true)],
                merge: true
            ))
        } onBeforeRemote: {
            cacheStateInsideWrite = store.getDoc(collection: "tasks", id: "t1")
        }

        // Act
        try await complete(["id": "t1"])

        // Assert — optimistic update was visible during the remote write
        XCTAssertEqual(cacheStateInsideWrite?["done"] as? Bool, true)
        XCTAssertEqual(
            store.getDoc(collection: "tasks", id: "t1")?["done"] as? Bool,
            true
        )
    }

    // -----------------------------------------------------------------------
    // MARK: Read-then-write
    // -----------------------------------------------------------------------

    func testReadThenWriteResolvesFromCache() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // Read-then-write reads from the cache synchronously, then writes
        // derived descriptors.
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed([
            "tasks": [
                ["id": "r1", "title": "Task A", "done": false],
                ["id": "r2", "title": "Task B", "done": false]
            ]
        ])

        let completeAll = createReadThenWriteMutate(store: store) { _ in
            // Read: all undone tasks
            [Query(collection: "tasks", where: ["done": false])]
        } write: { reads, _ in
            let undone = reads[0]
            return .batch(undone.map { doc in
                WriteDescriptor(
                    collection: "tasks",
                    id: doc["id"] as! String,
                    fields: ["done": .value(true)],
                    merge: true
                )
            })
        }

        // Act
        try await completeAll([:])

        // Assert — both tasks now done
        XCTAssertEqual(store.getDoc(collection: "tasks", id: "r1")?["done"] as? Bool, true)
        XCTAssertEqual(store.getDoc(collection: "tasks", id: "r2")?["done"] as? Bool, true)
    }

    // -----------------------------------------------------------------------
    // MARK: Transaction
    // -----------------------------------------------------------------------

    func testTransactionAppliesAllWritesAtomically() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // A transaction must apply all descriptors or none.
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed(["tasks": [["id": "txn1", "done": false]]])

        let archiveTask = createTransactionMutate(store: store) { payload in [
            WriteDescriptor(
                collection: "tasks",
                id: payload["id"] as! String,
                delete: true
            ),
            WriteDescriptor(
                collection: "logs",
                id: "log-\(payload["id"] as! String)",
                fields: [
                    "action": .value("archived"),
                    "taskId": .value(payload["id"] as! String)
                ]
            )
        ]}

        // Act
        try await archiveTask(["id": "txn1"])

        // Assert — task deleted, log written
        XCTAssertNil(store.getDoc(collection: "tasks", id: "txn1"))
        XCTAssertEqual(
            store.getDoc(collection: "logs", id: "log-txn1")?["action"] as? String,
            "archived"
        )
    }

    // -----------------------------------------------------------------------
    // MARK: Optimistic update
    // -----------------------------------------------------------------------

    func testOptimisticUpdateBeforeRemote() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // The cache update must be visible before the async remote write resolves.
        // Arrange
        let slowAdapter = SlowMemoryAdapter(delay: 0.1)
        let store = TestStore(adapter: slowAdapter)
        store.seed(["tasks": [["id": "opt1", "done": false]]])

        var cacheSnapshot: Doc? = nil

        let complete = createMutate(store: store) { _ in
            WriteOperation.single(WriteDescriptor(
                collection: "tasks",
                id: "opt1",
                fields: ["done": .value(true)],
                merge: true
            ))
        } onBeforeRemote: {
            cacheSnapshot = store.getDoc(collection: "tasks", id: "opt1")
        }

        // Act
        try await complete([:])

        // Assert — optimistic update was visible before the slow adapter finished
        XCTAssertEqual(cacheSnapshot?["done"] as? Bool, true)
    }

    // -----------------------------------------------------------------------
    // MARK: Rollback
    // -----------------------------------------------------------------------

    func testRollbackOnRemoteFailure() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // When the remote write fails, the cache must be restored to its
        // pre-write state.
        // Arrange
        let failingAdapter = FailingAdapter()
        let store = TestStore(adapter: failingAdapter)
        store.seed(["tasks": [["id": "rb1", "done": false]]])

        let complete = createMutate(store: store) { _ in
            WriteOperation.single(WriteDescriptor(
                collection: "tasks",
                id: "rb1",
                fields: ["done": .value(true)],
                merge: true
            ))
        }

        // Act
        do {
            try await complete([:])
            XCTFail("Expected write to throw")
        } catch {
            // Expected
        }

        // Assert — rollback: done is still false
        XCTAssertEqual(
            store.getDoc(collection: "tasks", id: "rb1")?["done"] as? Bool,
            false
        )
    }

    // -----------------------------------------------------------------------
    // MARK: resolveWrites
    // -----------------------------------------------------------------------

    func testResolveWritesReturnDescriptors() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
        // resolveWrites runs the mutate function and returns the descriptors
        // without touching the store or the adapter.
        //
        // Arrange
        let fakeMutate: ([String: Any]) throws -> WriteOperation = { payload in
            .single(WriteDescriptor(
                collection: "tasks",
                id: payload["id"] as! String,
                fields: ["done": .value(true)],
                merge: true
            ))
        }

        // Act
        let descs = try resolveWrites(fakeMutate, payload: ["id": "rw1"])

        // Assert
        XCTAssertEqual(descs.count, 1)
        XCTAssertEqual(descs[0].collection, "tasks")
        XCTAssertEqual(descs[0].id, "rw1")
    }
}

// ---------------------------------------------------------------------------
// MARK: Test helpers (defined here to avoid polluting production source)
// ---------------------------------------------------------------------------

/// A MemoryAdapter that introduces a configurable delay on write.
final class SlowMemoryAdapter: Adapter {
    private let inner = MemoryAdapter()
    private let delay: TimeInterval

    init(delay: TimeInterval) { self.delay = delay }

    func subscribe(query: Query) -> AsyncStream<[Doc]> { inner.subscribe(query: query) }

    func write(_ operation: WriteOperation) async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try await inner.write(operation)
    }
}

/// An adapter that always rejects writes with a network error.
final class FailingAdapter: Adapter {
    func subscribe(query: Query) -> AsyncStream<[Doc]> {
        AsyncStream { $0.finish() }
    }

    func write(_ operation: WriteOperation) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
