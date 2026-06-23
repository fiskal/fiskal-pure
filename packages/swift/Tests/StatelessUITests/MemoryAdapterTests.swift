// ---------------------------------------------------------------------------
// MemoryAdapterTests.swift — XCTest suite for MemoryAdapter
// ---------------------------------------------------------------------------
//
// All tests are marked skip at sprint-plan time.
// Unskip one ADR at a time in Step 3 (see CLAUDE.md §3.1).
//
// Coverage:
//   - subscribe emits docs on write
//   - write applies fields to the stored doc
//   - All atomic ops work correctly in the in-process adapter
//   - Where filter is applied correctly by subscribe

import XCTest
@testable import StatelessUI

final class MemoryAdapterTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Subscribe emits on write
    // -----------------------------------------------------------------------

    func testSubscribeEmitsOnWrite() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
        // A subscriber must receive the new doc immediately after a write
        // that matches its query.
        //
        // Arrange
        let adapter = MemoryAdapter()
        let query = Query(collection: "notes")
        var emissions: [[Doc]] = []
        let expectation = XCTestExpectation(description: "emission after write")

        let stream = adapter.subscribe(query: query)
        Task {
            for await docs in stream {
                emissions.append(docs)
                if emissions.count >= 2 { expectation.fulfill() }
            }
        }

        // Allow the first emission (empty initial state) to arrive.
        try await Task.sleep(nanoseconds: 10_000_000)

        // Act
        try await adapter.write(.single(WriteDescriptor(
            collection: "notes",
            id: "n1",
            fields: ["text": .value("Hello, world")]
        )))

        await fulfillment(of: [expectation], timeout: 2)

        // Assert
        XCTAssertGreaterThanOrEqual(emissions.count, 2)
        XCTAssertTrue(emissions[0].isEmpty, "First emission should be empty")
        let secondEmission = emissions[1]
        XCTAssertEqual(secondEmission.count, 1)
        XCTAssertEqual(secondEmission[0]["text"] as? String, "Hello, world")
    }

    // -----------------------------------------------------------------------
    // MARK: Write applies fields
    // -----------------------------------------------------------------------

    func testWriteAppliesFieldsToDoc() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
        // After a write, the adapter must store and return all provided fields.
        //
        // Arrange
        let adapter = MemoryAdapter()

        // Act
        try await adapter.write(.single(WriteDescriptor(
            collection: "users",
            id: "u1",
            fields: [
                "name": .value("Alice"),
                "age": .value(30),
                "active": .value(true)
            ]
        )))

        // Collect result via subscribe.
        var result: Doc? = nil
        let expectation = XCTestExpectation(description: "doc delivered")

        let stream = adapter.subscribe(query: Query(collection: "users", id: "u1"))
        Task {
            for await docs in stream {
                if let doc = docs.first {
                    result = doc
                    expectation.fulfill()
                    return
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2)

        // Assert
        XCTAssertEqual(result?["name"] as? String, "Alice")
        XCTAssertEqual(result?["age"] as? Int, 30)
        XCTAssertEqual(result?["active"] as? Bool, true)
    }

    // -----------------------------------------------------------------------
    // MARK: Atomic ops
    // -----------------------------------------------------------------------

    func testAtomicOpsWorkCorrectly() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
        // All five atomic ops must work correctly via the MemoryAdapter.
        //
        // Arrange
        let adapter = MemoryAdapter()
        try await adapter.write(.single(WriteDescriptor(
            collection: "state",
            id: "s1",
            fields: [
                "count": .value(10),
                "tags": .value(["alpha", "beta"]),
                "secret": .value("hidden")
            ]
        )))

        // Act — apply increment, arrayUnion, arrayRemove, delete in a batch
        try await adapter.write(.batch([
            WriteDescriptor(
                collection: "state",
                id: "s1",
                fields: ["count": .atomic(.increment(5))],
                merge: true
            ),
            WriteDescriptor(
                collection: "state",
                id: "s1",
                fields: ["tags": .atomic(.arrayUnion(["gamma"]))],
                merge: true
            ),
            WriteDescriptor(
                collection: "state",
                id: "s1",
                fields: ["tags": .atomic(.arrayRemove(["alpha"]))],
                merge: true
            ),
            WriteDescriptor(
                collection: "state",
                id: "s1",
                fields: ["secret": .atomic(.delete)],
                merge: true
            )
        ]))

        // Collect via subscribe
        var result: Doc? = nil
        let expectation = XCTestExpectation(description: "updated doc")

        let stream = adapter.subscribe(query: Query(collection: "state", id: "s1"))
        Task {
            for await docs in stream {
                if let doc = docs.first {
                    result = doc
                    expectation.fulfill()
                    return
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2)

        // Assert
        XCTAssertEqual(result?["count"] as? Double, 15)
        XCTAssertEqual(result?["tags"] as? [String], ["beta", "gamma"])
        XCTAssertNil(result?["secret"])
    }

    // -----------------------------------------------------------------------
    // MARK: Where filter
    // -----------------------------------------------------------------------

    func testWhereFilterWorksInMemory() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
        // subscribe with a where-clause query must emit only matching docs.
        //
        // Arrange
        let adapter = MemoryAdapter()
        try await adapter.write(.batch([
            WriteDescriptor(
                collection: "items",
                id: "i1",
                fields: ["category": .value("fruit"), "name": .value("Apple")]
            ),
            WriteDescriptor(
                collection: "items",
                id: "i2",
                fields: ["category": .value("vegetable"), "name": .value("Carrot")]
            ),
            WriteDescriptor(
                collection: "items",
                id: "i3",
                fields: ["category": .value("fruit"), "name": .value("Banana")]
            )
        ]))

        // Act — subscribe with where filter
        let query = Query(collection: "items", where: ["category": "fruit"])
        var result: [Doc] = []
        let expectation = XCTestExpectation(description: "filtered docs")

        let stream = adapter.subscribe(query: query)
        Task {
            for await docs in stream {
                if !docs.isEmpty {
                    result = docs
                    expectation.fulfill()
                    return
                }
            }
        }

        await fulfillment(of: [expectation], timeout: 2)

        // Assert — only fruit items
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0["category"] as? String == "fruit" })
        let names = result.compactMap { $0["name"] as? String }.sorted()
        XCTAssertEqual(names, ["Apple", "Banana"])
    }
}
