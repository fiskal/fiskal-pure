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
@testable import Antifragile

final class MutateTests: XCTestCase {

    func testWriteOnlyMutateUpdatesCacheSync() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
    }

    func testReadThenWriteResolvesFromCache() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
    }

    func testTransactionAppliesAllWritesAtomically() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
    }

    func testOptimisticUpdateBeforeRemote() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
    }

    func testRollbackOnRemoteFailure() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
    }

    func testResolveWritesReturnDescriptors() async throws {
        throw XCTSkip("sprint-plan: unskip when mutate ADR is coded")
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

    func subscribe(query: Query, onChange: @escaping @Sendable ([Doc]) -> Void) -> @Sendable () -> Void {
        inner.subscribe(query: query, onChange: onChange)
    }

    func write(_ operation: WriteOperation) async throws {
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        try await inner.write(operation)
    }
}

/// An adapter that always rejects writes with a network error.
final class FailingAdapter: Adapter {
    func subscribe(query: Query, onChange: @escaping @Sendable ([Doc]) -> Void) -> @Sendable () -> Void {
        return {}
    }

    func write(_ operation: WriteOperation) async throws {
        throw URLError(.notConnectedToInternet)
    }
}
