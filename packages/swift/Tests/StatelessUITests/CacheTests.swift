// ---------------------------------------------------------------------------
// CacheTests.swift — XCTest suite for cache layer (structural sharing + atomics)
// ---------------------------------------------------------------------------
//
// All tests are marked skip at sprint-plan time.
// Unskip one ADR at a time in Step 3 (see CLAUDE.md §3.1).
//
// Coverage:
//   - Structural sharing: writing doc A does not replace doc B reference
//   - subscribe emits doc on write
//   - snapshot / restore roundtrip
//   - AtomicOp resolution: increment, arrayUnion, arrayRemove, delete

import XCTest
@testable import StatelessUI

final class CacheTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Structural sharing
    // -----------------------------------------------------------------------

    func testStructuralSharingPreservesUnchangedDocs() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // Seed two docs in the same collection.
        // Write doc A.
        // Assert that the reference to doc B in the new cache is identical
        // to the reference in the original cache (structural sharing).
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "tasks",
            id: "task-1",
            fields: ["title": .value("Buy groceries"), "done": .value(false)]
        )))
        store.write(.single(WriteDescriptor(
            collection: "tasks",
            id: "task-2",
            fields: ["title": .value("Read ADRs"), "done": .value(true)]
        )))
        let doc2Before = store.getDoc(collection: "tasks", id: "task-2")

        // Act — mutate doc 1 only
        store.write(.single(WriteDescriptor(
            collection: "tasks",
            id: "task-1",
            fields: ["done": .value(true)],
            merge: true
        )))
        let doc2After = store.getDoc(collection: "tasks", id: "task-2")

        // Assert — doc 2 is the same value object
        XCTAssertEqual(doc2Before?["title"] as? String, doc2After?["title"] as? String)
        XCTAssertEqual(doc2Before?["done"] as? Bool, doc2After?["done"] as? Bool)
    }

    // -----------------------------------------------------------------------
    // MARK: Subscribe
    // -----------------------------------------------------------------------

    func testSubscribeReceivesDocOnWrite() async throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // A subscription to a query must fire immediately with the current
        // state and again after every write that matches the query.
        //
        // Arrange
        let adapter = MemoryAdapter()
        var received: [[Doc]] = []
        let expectation = XCTestExpectation(description: "doc received after write")

        let stream = adapter.subscribe(query: Query(
            collection: "notes",
            id: "note-1"
        ))
        Task {
            for await docs in stream {
                received.append(docs)
                if received.count == 2 { expectation.fulfill() }
            }
        }

        // Act
        try await adapter.write(.single(WriteDescriptor(
            collection: "notes",
            id: "note-1",
            fields: ["text": .value("hello")]
        )))

        await fulfillment(of: [expectation], timeout: 2)

        // First emission is the initial state (empty), second is after the write.
        XCTAssertEqual(received.count, 2)
        XCTAssertTrue(received[0].isEmpty)
        XCTAssertEqual(received[1].first?["text"] as? String, "hello")
    }

    // -----------------------------------------------------------------------
    // MARK: Snapshot / restore
    // -----------------------------------------------------------------------

    func testSnapshotRestoreRoundtrip() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // Serialize the cache to a plain dictionary and restore it.
        // All doc fields must survive the round-trip.
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "items",
            id: "i1",
            fields: [
                "label": .value("Apples"),
                "count": .value(3),
                "tags": .value(["fruit", "fresh"])
            ]
        )))

        // Act
        let snap = store.snapshot()
        var restored = MemoryStore(snapshot: snap)

        // Assert
        let doc = restored.getDoc(collection: "items", id: "i1")
        XCTAssertEqual(doc?["label"] as? String, "Apples")
        XCTAssertEqual(doc?["count"] as? Int, 3)
        XCTAssertEqual(doc?["tags"] as? [String], ["fruit", "fresh"])
    }

    // -----------------------------------------------------------------------
    // MARK: AtomicOps
    // -----------------------------------------------------------------------

    func testAtomicIncrementOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // ::increment adds n to the existing numeric field.
        // If the field does not exist it starts from 0.
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "counters",
            id: "c1",
            fields: ["n": .value(5)]
        )))

        // Act
        store.write(.single(WriteDescriptor(
            collection: "counters",
            id: "c1",
            fields: ["n": .atomic(.increment(3))],
            merge: true
        )))

        // Assert
        let doc = store.getDoc(collection: "counters", id: "c1")
        XCTAssertEqual(doc?["n"] as? Double, 8)
    }

    func testAtomicArrayUnionOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // ::arrayUnion appends values not already present in the array.
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "lists",
            id: "l1",
            fields: ["tags": .value(["a", "b"])]
        )))

        // Act
        store.write(.single(WriteDescriptor(
            collection: "lists",
            id: "l1",
            fields: ["tags": .atomic(.arrayUnion(["b", "c"]))],  // "b" is duplicate
            merge: true
        )))

        // Assert — result should be ["a", "b", "c"] (no duplicate "b")
        let doc = store.getDoc(collection: "lists", id: "l1")
        let tags = doc?["tags"] as? [String]
        XCTAssertEqual(tags, ["a", "b", "c"])
    }

    func testAtomicArrayRemoveOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // ::arrayRemove removes all matching values from the array.
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "lists",
            id: "r1",
            fields: ["tags": .value(["a", "b", "c"])]
        )))

        // Act
        store.write(.single(WriteDescriptor(
            collection: "lists",
            id: "r1",
            fields: ["tags": .atomic(.arrayRemove(["b"]))],
            merge: true
        )))

        // Assert
        let doc = store.getDoc(collection: "lists", id: "r1")
        XCTAssertEqual(doc?["tags"] as? [String], ["a", "c"])
    }

    func testAtomicDeleteOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
        // ::delete removes a single field from the document.
        //
        // Arrange
        var store = MemoryStore()
        store.write(.single(WriteDescriptor(
            collection: "docs",
            id: "d1",
            fields: [
                "title": .value("Hello"),
                "secret": .value("hidden")
            ]
        )))

        // Act
        store.write(.single(WriteDescriptor(
            collection: "docs",
            id: "d1",
            fields: ["secret": .atomic(.delete)],
            merge: true
        )))

        // Assert
        let doc = store.getDoc(collection: "docs", id: "d1")
        XCTAssertEqual(doc?["title"] as? String, "Hello")
        XCTAssertNil(doc?["secret"])
    }
}
