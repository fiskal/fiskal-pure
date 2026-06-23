// ---------------------------------------------------------------------------
// QueryTests.swift — XCTest suite for query / useRead equivalents
// ---------------------------------------------------------------------------
//
// All tests are marked skip at sprint-plan time.
// Unskip one ADR at a time in Step 3 (see CLAUDE.md §3.1).
//
// Coverage:
//   - Returns nil while loading (async adapter, no cache hit)
//   - Returns doc when found
//   - Returns nil when not found (single-doc query with id)
//   - Collection query returns ids
//   - Where filter returns only matching docs
//   - fields projection returns only requested fields

import XCTest
@testable import StatelessUI

final class QueryTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Loading state
    // -----------------------------------------------------------------------

    func testQueryReturnsNilWhileLoading() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A query against an async adapter that has not yet delivered data
        // must return nil (loading state) on the first synchronous read.
        //
        // Arrange — adapter that never fires synchronously
        let asyncAdapter = NeverDeliveringAdapter()
        let store = TestStore(adapter: asyncAdapter)

        // Act
        let result = store.read(Query(collection: "tasks"))

        // Assert — no data yet
        XCTAssertNil(result)
    }

    // -----------------------------------------------------------------------
    // MARK: Single-doc found
    // -----------------------------------------------------------------------

    func testQueryReturnsDocWhenFound() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A single-doc query with id must return the doc when it is in cache.
        //
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed(["tasks": [["id": "found", "title": "Found it"]]])

        // Act
        let result = store.read(Query(collection: "tasks", id: "found"))

        // Assert
        XCTAssertNotNil(result)
        if case .doc(let doc) = result {
            XCTAssertEqual(doc["title"] as? String, "Found it")
        } else {
            XCTFail("Expected .doc, got \(String(describing: result))")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Single-doc not found
    // -----------------------------------------------------------------------

    func testQueryReturnsNilWhenNotFound() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A single-doc query that finds no matching document must return
        // .notFound (null) rather than staying in loading state.
        //
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        // No docs seeded.

        // Act — MemoryAdapter delivers synchronously so the cache is settled.
        let result = store.read(Query(collection: "tasks", id: "does-not-exist"))

        // Assert
        if case .notFound = result {
            // correct
        } else {
            XCTFail("Expected .notFound, got \(String(describing: result))")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Collection query
    // -----------------------------------------------------------------------

    func testCollectionQueryReturnsIds() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A collection query must return all docs in the collection.
        // The id field must be present on every returned doc.
        //
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed([
            "tasks": [
                ["id": "c1", "title": "Alpha"],
                ["id": "c2", "title": "Beta"]
            ]
        ])

        // Act
        let result = store.read(Query(collection: "tasks"))

        // Assert
        if case .collection(let docs) = result {
            XCTAssertEqual(docs.count, 2)
            let ids = docs.compactMap { $0["id"] as? String }
            XCTAssertTrue(ids.contains("c1"))
            XCTAssertTrue(ids.contains("c2"))
        } else {
            XCTFail("Expected .collection, got \(String(describing: result))")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Where filter
    // -----------------------------------------------------------------------

    func testWhereFilterReturnsMatchingDocs() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A query with a where clause must return only the docs whose fields
        // match all key-value pairs in the clause.
        //
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed([
            "tasks": [
                ["id": "w1", "done": false],
                ["id": "w2", "done": true],
                ["id": "w3", "done": false]
            ]
        ])

        // Act
        let result = store.read(Query(
            collection: "tasks",
            where: ["done": false]
        ))

        // Assert — only the two undone tasks
        if case .collection(let docs) = result {
            XCTAssertEqual(docs.count, 2)
            XCTAssertTrue(docs.allSatisfy { $0["done"] as? Bool == false })
        } else {
            XCTFail("Expected .collection, got \(String(describing: result))")
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Fields projection
    // -----------------------------------------------------------------------

    func testFieldsProjectionReturnsOnlyRequestedFields() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
        // A query with fields projection must return only the named keys
        // plus the mandatory `id` field.
        //
        // Arrange
        let store = TestStore(adapter: MemoryAdapter())
        store.seed([
            "tasks": [["id": "p1", "title": "Secret project", "category": "work", "done": false]]
        ])

        // Act
        let result = store.read(Query(
            collection: "tasks",
            fields: ["title"]
        ))

        // Assert — only id + title returned; category and done absent
        if case .collection(let docs) = result {
            XCTAssertEqual(docs.count, 1)
            XCTAssertNotNil(docs[0]["id"])
            XCTAssertNotNil(docs[0]["title"])
            XCTAssertNil(docs[0]["category"])
            XCTAssertNil(docs[0]["done"])
        } else {
            XCTFail("Expected .collection, got \(String(describing: result))")
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: Test helpers
// ---------------------------------------------------------------------------

/// An adapter that subscribes but never delivers any documents.
/// Used to keep the query in a loading/nil state.
final class NeverDeliveringAdapter: Adapter {
    func subscribe(query: Query) -> AsyncStream<[Doc]> {
        AsyncStream { _ in
            // Never yields — the continuation is just held open.
        }
    }

    func write(_ operation: WriteOperation) async throws {}
}
