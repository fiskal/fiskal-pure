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
@testable import Antifragile

final class QueryTests: XCTestCase {

    func testQueryReturnsNilWhileLoading() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }

    func testQueryReturnsDocWhenFound() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }

    func testQueryReturnsNilWhenNotFound() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }

    func testCollectionQueryReturnsIds() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }

    func testWhereFilterReturnsMatchingDocs() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }

    func testFieldsProjectionReturnsOnlyRequestedFields() throws {
        throw XCTSkip("sprint-plan: unskip when query ADR is coded")
    }
}

// ---------------------------------------------------------------------------
// MARK: Test helpers
// ---------------------------------------------------------------------------

/// An adapter that subscribes but never delivers any documents.
/// Used to keep the query in a loading/nil state.
final class NeverDeliveringAdapter: Adapter {
    func subscribe(query: Query, onChange: @escaping @Sendable ([Doc]) -> Void) -> @Sendable () -> Void {
        // Never calls onChange — keeps the query in loading/nil state.
        return {}
    }

    func write(_ operation: WriteOperation) async throws {}
}
