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
@testable import Antifragile

final class CacheTests: XCTestCase {

    // -----------------------------------------------------------------------
    // MARK: Structural sharing
    // -----------------------------------------------------------------------

    func testStructuralSharingPreservesUnchangedDocs() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: Subscribe
    // -----------------------------------------------------------------------

    func testSubscribeReceivesDocOnWrite() async throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: Snapshot / restore
    // -----------------------------------------------------------------------

    func testSnapshotRestoreRoundtrip() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    // -----------------------------------------------------------------------
    // MARK: AtomicOps
    // -----------------------------------------------------------------------

    func testAtomicIncrementOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    func testAtomicArrayUnionOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    func testAtomicArrayRemoveOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }

    func testAtomicDeleteOp() throws {
        throw XCTSkip("sprint-plan: unskip when cache ADR is coded")
    }
}
