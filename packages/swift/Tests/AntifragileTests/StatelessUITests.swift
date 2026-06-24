// StatelessUI — Test Suite
// All tests are hermetic: MemoryAdapter only, no network, no shared state.

import XCTest
@testable import Antifragile

// MARK: - Cache tests (legacy — canonical tests are in CacheTests.swift)

final class CacheCoreTests: XCTestCase {

    @MainActor func testWriteAndRead() {
        let cache = Cache()
        let write = Write(path: "todos", id: "1", fields: ["title": "Buy milk", "done": false])
        cache.applyWrite(write)
        let docs = cache.get(query: Query(path: "todos"))
        XCTAssertEqual(docs.count, 1)
        XCTAssertEqual(docs.first?["title"] as? String, "Buy milk")
    }

    @MainActor func testAtomicIncrement() {
        let cache = Cache()
        cache.applyWrite(Write(path: "counters", id: "a", fields: ["n": 10.0]))
        cache.applyWrite(Write(path: "counters", id: "a", fields: ["n": AtomicOp.increment(5)]))
        let docs = cache.get(query: Query(path: "counters", id: "a"))
        XCTAssertEqual(docs.first?["n"] as? Double, 15.0)
    }

    @MainActor func testAtomicDelete() {
        let cache = Cache()
        cache.applyWrite(Write(path: "items", id: "x", fields: ["a": 1, "b": 2]))
        cache.applyWrite(Write(path: "items", id: "x", fields: ["b": AtomicOp.delete]))
        let docs = cache.get(query: Query(path: "items", id: "x"))
        XCTAssertNil(docs.first?["b"])
        XCTAssertNotNil(docs.first?["a"])
    }

    @MainActor func testAtomicArrayUnionAndRemove() {
        let cache = Cache()
        cache.applyWrite(Write(path: "tags", id: "doc1", fields: ["list": [AnyHashable("a"), AnyHashable("b")]]))
        cache.applyWrite(Write(path: "tags", id: "doc1", fields: ["list": AtomicOp.arrayUnion(AnyHashable("c"))]))
        var docs = cache.get(query: Query(path: "tags", id: "doc1"))
        XCTAssertEqual((docs.first?["list"] as? [AnyHashable])?.count, 3)

        cache.applyWrite(Write(path: "tags", id: "doc1", fields: ["list": AtomicOp.arrayRemove(AnyHashable("a"))]))
        docs = cache.get(query: Query(path: "tags", id: "doc1"))
        XCTAssertEqual((docs.first?["list"] as? [AnyHashable])?.count, 2)
    }

    @MainActor func testSnapshotAndRestore() {
        let cache = Cache()
        cache.applyWrite(Write(path: "todos", id: "1", fields: ["title": "original"]))
        let snap = cache.snapshot()
        cache.applyWrite(Write(path: "todos", id: "1", fields: ["title": "mutated"]))
        XCTAssertEqual(
            cache.get(query: Query(path: "todos", id: "1")).first?["title"] as? String,
            "mutated"
        )
        cache.restore(snap)
        XCTAssertEqual(
            cache.get(query: Query(path: "todos", id: "1")).first?["title"] as? String,
            "original"
        )
    }

    @MainActor func testWhereFilter() {
        let cache = Cache()
        cache.applyWrite(Write(path: "items", id: "a", fields: ["score": 10.0]))
        cache.applyWrite(Write(path: "items", id: "b", fields: ["score": 20.0]))
        cache.applyWrite(Write(path: "items", id: "c", fields: ["score": 30.0]))
        let query = Query(
            path: "items",
            where: [WhereClause(field: "score", op: .greaterThan, value: AnyHashable(15.0))]
        )
        let results = cache.get(query: query)
        XCTAssertEqual(results.count, 2)
    }

    @MainActor func testOrderBy() {
        let cache = Cache()
        cache.applyWrite(Write(path: "users", id: "b", fields: ["name": "Zoe"]))
        cache.applyWrite(Write(path: "users", id: "a", fields: ["name": "Alice"]))
        let query = Query(
            path: "users",
            orderBy: [OrderByClause(field: "name", direction: .ascending)]
        )
        let results = cache.get(query: query)
        XCTAssertEqual(results.first?["name"] as? String, "Alice")
        XCTAssertEqual(results.last?["name"] as? String, "Zoe")
    }

    @MainActor func testFieldProjection() {
        let cache = Cache()
        cache.applyWrite(Write(path: "users", id: "1", fields: ["name": "Bob", "secret": "hidden"]))
        let query = Query(path: "users", id: "1", fields: ["name"])
        let doc = cache.get(query: query).first
        XCTAssertEqual(doc?["name"] as? String, "Bob")
        XCTAssertNil(doc?["secret"])
    }
}

// MARK: - History tests

final class HistoryTests: XCTestCase {

    @MainActor func testAppendAndNavigate() {
        let log = HistoryLog()
        let w = Write(path: "todos", id: "1", fields: ["title": "Task A"])
        log.append(HistoryEntry(action: "addTodo", writes: [w]))
        log.append(HistoryEntry(action: "addTodo", writes: [w]))
        XCTAssertEqual(log.entries.count, 2)
        XCTAssertEqual(log.cursor, 1)

        let prev = log.back()
        XCTAssertEqual(prev?.action, "addTodo")
        XCTAssertEqual(log.cursor, 0)

        let next = log.forward()
        XCTAssertNotNil(next)
        XCTAssertEqual(log.cursor, 1)
    }

    @MainActor func testTruncatesForwardOnAppend() {
        let log = HistoryLog()
        let w = Write(path: "x", id: "1", fields: [:])
        log.append(HistoryEntry(action: "a", writes: [w]))
        log.append(HistoryEntry(action: "b", writes: [w]))
        log.append(HistoryEntry(action: "c", writes: [w]))
        log.back() // cursor = 1
        log.append(HistoryEntry(action: "d", writes: [w]))
        XCTAssertEqual(log.entries.count, 3)  // a, b, d — c was truncated
        XCTAssertEqual(log.entries.last?.action, "d")
    }

    @MainActor func testGoto() {
        let log = HistoryLog()
        let w = Write(path: "x", id: "1", fields: [:])
        for action in ["a", "b", "c", "d"] {
            log.append(HistoryEntry(action: action, writes: [w]))
        }
        let entry = log.goto(index: 1)
        XCTAssertEqual(entry?.action, "b")
        XCTAssertEqual(log.cursor, 1)
    }
}

// MARK: - MemoryAdapter tests (legacy — canonical tests are in MemoryAdapterTests.swift)

final class MemoryAdapterCoreTests: XCTestCase {

    func testWriteAndQuery() async throws {
        let adapter = MemoryAdapter()
        let write = Write(path: "todos", id: "1", fields: ["title": "Hello"])
        try await adapter.write(.single(write))
        let docs = try await adapter.query(Query(path: "todos", id: "1"))
        XCTAssertEqual(docs.first?["title"] as? String, "Hello")
    }

    func testAtomicOpsRoundTrip() async throws {
        let adapter = MemoryAdapter()
        try await adapter.write(.single(Write(path: "counters", id: "c", fields: ["n": 0.0])))
        try await adapter.write(.single(Write(path: "counters", id: "c", fields: ["n": AtomicOp.increment(3)])))
        let docs = try await adapter.query(Query(path: "counters", id: "c"))
        XCTAssertEqual(docs.first?["n"] as? Double, 3.0)
    }

    func testSubscriptionReceivesUpdates() async throws {
        let adapter = MemoryAdapter()
        var received: [[Doc]] = []
        let expectation = XCTestExpectation(description: "subscriber notified")

        let unsubscribe = adapter.subscribe(query: Query(path: "todos")) { docs in
            received.append(docs)
            if received.count >= 2 { expectation.fulfill() }
        }

        // Wait for the subscribe Task to register in the MemoryState actor before writing.
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms — enough for actor scheduling
        try await adapter.write(.single(Write(path: "todos", id: "1", fields: ["title": "First"])))

        await fulfillment(of: [expectation], timeout: 2.0)
        unsubscribe()

        XCTAssertGreaterThanOrEqual(received.count, 2)  // initial + at least one update
    }

    func testInitialSeed() async throws {
        let adapter = MemoryAdapter(initial: [
            "users": ["u1": ["name": "Alice"]]
        ])
        let docs = try await adapter.query(Query(path: "users", id: "u1"))
        XCTAssertEqual(docs.first?["name"] as? String, "Alice")
    }

    func testBatchWrite() async throws {
        let adapter = MemoryAdapter()
        let writes = [
            Write(path: "items", id: "a", fields: ["v": 1.0]),
            Write(path: "items", id: "b", fields: ["v": 2.0])
        ]
        try await adapter.write(.batch(writes))
        let docs = try await adapter.query(Query(path: "items"))
        XCTAssertEqual(docs.count, 2)
    }
}

// MARK: - Store integration tests

final class StoreIntegrationTests: XCTestCase {

    @MainActor func testSeedAndGet() async {
        let store = Store.createStore {
            BackingStoreConfig(name: "main", adapter: MemoryAdapter())
        }
        store.seed(["todos": ["1": ["title": "Seeded"]]])
        let docs: [Doc]? = store.get(query: Query(path: "todos"))
        XCTAssertEqual((docs ?? []).count, 1)
    }

    @MainActor func testMutateOptimisticCacheUpdate() async throws {
        let adapter = MemoryAdapter()
        let addTodo = createMutate(action: "addTodo") { payload in
            [Write(
                path: "todos",
                id: payload["id"] as? String ?? UUID().uuidString,
                fields: payload
            )]
        }
        let store = Store.createStore {
            BackingStoreConfig(
                name: "main",
                adapter: adapter,
                models: ["todos"],
                mutates: [addTodo]
            )
        }

        try await store.mutate(
            action: "addTodo",
            payload: ["id": "t1", "title": "Buy milk"],
            using: addTodo
        )

        // Cache should be updated optimistically.
        let docs: [Doc]? = store.get(query: Query(path: "todos"))
        XCTAssertEqual((docs ?? []).count, 1)
        XCTAssertEqual((docs ?? []).first?["title"] as? String, "Buy milk")
    }

    @MainActor func testRollbackOnAdapterFailure() async {
        struct FailingAdapter: Adapter {
            func subscribe(query: Query, onChange: @Sendable @escaping ([Doc]) -> Void) -> @Sendable () -> Void { {} }
            func write(_ operation: WriteOperation) async throws {
                throw NSError(domain: "test", code: 500)
            }
        }

        let failAdd = createMutate(action: "failAdd") { payload in
            [Write(path: "todos", id: "x", fields: payload)]
        }
        let store = Store.createStore {
            BackingStoreConfig(
                name: "main",
                adapter: FailingAdapter(),
                models: ["todos"],
                mutates: [failAdd]
            )
        }

        do {
            try await store.mutate(
                action: "failAdd",
                payload: ["title": "Doomed"],
                using: failAdd
            )
            XCTFail("Expected throw")
        } catch {
            // Cache should be rolled back to empty.
            let docs: [Doc]? = store.get(query: Query(path: "todos"))
            XCTAssertEqual((docs ?? []).count, 0)
        }
    }

    @MainActor func testDispatchByActionName() async throws {
        let adapter = MemoryAdapter()
        let removeTodo = createMutate(action: "removeTodo") { payload in
            // Produce a no-op write to a sentinel path to verify dispatch routing.
            [Write(path: "_ops", id: "last", fields: ["action": "removeTodo"])]
        }
        let store = Store.createStore {
            BackingStoreConfig(
                name: "main",
                adapter: adapter,
                models: ["_ops"],
                mutates: [removeTodo]
            )
        }
        try await store.dispatch(action: "removeTodo", payload: ["id": "1"])
        let docs: [Doc]? = store.get(query: Query(path: "_ops", id: "last"))
        XCTAssertEqual(docs?.first?["action"] as? String, "removeTodo")
    }
}

// MARK: - Mutate factory tests

final class MutateFactoryTests: XCTestCase {

    @MainActor func testWriteOnlyFactory() async throws {
        let m = createMutate(action: "test") { payload in
            [Write(path: "x", id: "1", fields: payload)]
        }
        XCTAssertEqual(m.action, "test")
    }

    @MainActor func testCallableConvenience() async throws {
        let adapter = MemoryAdapter()
        let setFlag = createMutate(action: "setFlag") { payload in
            Write(path: "flags", id: "main", fields: payload)
        }
        let store = Store.createStore {
            BackingStoreConfig(
                name: "main",
                adapter: adapter,
                models: ["flags"],
                mutates: [setFlag]
            )
        }
        try await setFlag(payload: ["value": true], through: store)
        let docs: [Doc]? = store.get(query: Query(path: "flags", id: "main"))
        XCTAssertEqual(docs?.first?["value"] as? Bool, true)
    }
}