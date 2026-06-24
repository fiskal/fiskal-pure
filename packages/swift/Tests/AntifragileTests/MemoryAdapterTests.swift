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
@testable import Antifragile

final class MemoryAdapterTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Subscribe emits on write
    // -----------------------------------------------------------------------

    func testSubscribeEmitsOnWrite() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: Write applies fields
    // -----------------------------------------------------------------------

    func testWriteAppliesFieldsToDoc() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: Atomic ops
    // -----------------------------------------------------------------------

    func testAtomicOpsWorkCorrectly() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: Where filter
    // -----------------------------------------------------------------------

    func testWhereFilterWorksInMemory() async throws {
        throw XCTSkip("sprint-plan: unskip when MemoryAdapter ADR is coded")
    }
}
