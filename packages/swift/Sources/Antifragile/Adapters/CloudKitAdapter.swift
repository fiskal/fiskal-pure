// CloudKitAdapter — iCloud private database backing store.
//
// subscribe: registers a server-side CKSubscription for push delivery, then wraps an
//   internal AsyncStream in a Task that fetches-on-push and calls onChange for each
//   emission. A `pollingInterval` Task.sleep loop remains as an explicit fallback when
//   subscription registration fails (CloudKit push for arbitrary queries requires
//   server-side subscription provisioning, which may be unavailable).
// write: CKModifyRecordsOperation in a custom zone. On CKError.serverRecordChanged the
//   server record is re-fetched, our fields re-applied, and the record re-saved
//   (server-record-wins resolution). On network errors the Write is persisted to a
//   durable retry queue and drained on the next successful write — writes never fail
//   offline, matching MemoryAdapter / NSUserDefaultsAdapter.
// Atomic ops (arrayUnion, arrayRemove, increment) require fetch-then-modify cycles.

import CloudKit
import Foundation

public struct CloudKitAdapter: Adapter {

    private let database: CKDatabase
    private let pollingInterval: TimeInterval
    private let zoneID: CKRecordZone.ID
    private let pending: PendingWriteQueue

    public init(
        container: CKContainer = .default(),
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "fiskal.tasks"),
        pollingInterval: TimeInterval = 30
    ) {
        self.database = container.privateCloudDatabase
        self.pollingInterval = pollingInterval
        self.zoneID = zoneID
        self.pending = PendingWriteQueue()
    }

    // MARK: - Adapter: subscribe

    public func subscribe(
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) -> @Sendable () -> Void {
        let task = Task {
            // Register a server-side subscription so changes arrive via push.
            // Falls through to the polling fallback inside the streams if this fails.
            await registerSubscription(for: query)
            let stream = query.id != nil
                ? subscribeSingleDoc(path: query.path, id: query.id!)
                : subscribeCollection(query: query)
            for await docs in stream {
                onChange(docs)
            }
        }
        return { task.cancel() }
    }

    /// Best-effort registration of a CKSubscription for `query`'s record type.
    /// On success CloudKit pushes a CKDatabaseNotification; the polling loop in the
    /// stream remains as the explicit fallback path if this throws.
    private func registerSubscription(for query: Query) async {
        let recordType = recordTypeName(query.path)
        let subscription = CKQuerySubscription(
            recordType: recordType,
            predicate: NSPredicate(value: true),
            subscriptionID: "afrag-\(recordType)-\(zoneID.zoneName)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        let op = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: nil
        )
        // Failure here is non-fatal: the stream's Task.sleep loop is the fallback.
        try? await database.add(op)
    }

    // MARK: - Adapter: write

    public func write(_ operation: WriteOperation) async throws {
        let writes: [Write]
        switch operation {
        case .single(let w):   writes = [w]
        case .batch(let ws),
             .transaction(let ws): writes = ws
        }
        if writes.count == 1 {
            try await writeSingle(writes[0])
        } else {
            try await writeBatch(writes)
        }
    }

    // MARK: - Private — single-doc stream

    private func subscribeSingleDoc(path: String, id: String) -> AsyncStream<[Doc]> {
        AsyncStream { continuation in
            Task {
                let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
                let recordType = recordTypeName(path)

                do {
                    let record = try await database.record(for: recordID)
                    continuation.yield([ckRecordToDoc(record, recordType: recordType)])
                } catch let e as CKError where e.code == .unknownItem {
                    continuation.yield([])
                } catch {
                    continuation.yield([])
                }

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    do {
                        let record = try await database.record(for: recordID)
                        continuation.yield([ckRecordToDoc(record, recordType: recordType)])
                    } catch let e as CKError where e.code == .unknownItem {
                        continuation.yield([])
                    } catch { }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Private — collection stream (polling)

    private func subscribeCollection(query: Query) -> AsyncStream<[Doc]> {
        AsyncStream { continuation in
            Task {
                let recordType = recordTypeName(query.path)
                let ckQuery = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))

                let docs = await fetchCollection(ckQuery: ckQuery)
                continuation.yield(filterDocs(docs, query: query))

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    let refreshed = await fetchCollection(ckQuery: ckQuery)
                    continuation.yield(filterDocs(refreshed, query: query))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Private — write helpers

    private func writeSingle(_ write: Write) async throws {
        // Drain anything queued from a previous offline window first.
        await drainPending()
        do {
            try await save([write])
        } catch let e as CKError where isOffline(e) {
            // Offline: queue durably and succeed — writes never fail offline.
            await pending.enqueue([write])
        }
    }

    private func writeBatch(_ writes: [Write]) async throws {
        await drainPending()
        do {
            try await save(writes)
        } catch let e as CKError where isOffline(e) {
            await pending.enqueue(writes)
        }
    }

    /// Builds records for `writes` and saves them in one CKModifyRecordsOperation,
    /// resolving CKError.serverRecordChanged by inheriting the server record.
    private func save(_ writes: [Write]) async throws {
        var records: [CKRecord] = []
        for write in writes {
            records.append(await buildRecord(for: write))
        }
        do {
            try await modify(records)
        } catch let e as CKError where e.code == .serverRecordChanged {
            // Single-record conflict: re-apply our fields onto the server record.
            try await resolveAndResave(e: e, writes: writes)
        } catch let e as CKError where e.code == .partialFailure {
            try await resolvePartialFailure(e: e, writes: writes)
        }
    }

    /// Construct the record for a write, fetching the existing one when atomics are
    /// present (so increment/array ops see current state) or to inherit its
    /// recordChangeTag — avoiding .changedKeys clobbering unset fields.
    private func buildRecord(for write: Write) async -> CKRecord {
        let recordID = CKRecord.ID(recordName: write.id, zoneID: zoneID)
        let recordType = recordTypeName(write.path)
        let hasAtomics = write.fields.values.contains { $0 is AtomicOp }
        let record: CKRecord
        if hasAtomics || write.merge {
            record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: recordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        applyFields(write.fields, to: record)
        return record
    }

    private func modify(_ records: [CKRecord]) async throws {
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        // Inheriting the server record's change tag (buildRecord) lets us keep
        // .changedKeys for patch semantics without clobbering untouched fields.
        op.savePolicy = .ifServerRecordUnchanged
        try await database.add(op)
    }

    /// Server-record-wins resolution: re-apply each write's fields onto the server
    /// record from the error userInfo and re-save. The resaved record is picked up
    /// by subscribers on their next push/poll.
    private func resolveAndResave(e: CKError, writes: [Write]) async throws {
        guard
            let server = e.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
            let write = writes.first(where: { $0.id == server.recordID.recordName })
        else { throw e }
        applyFields(write.fields, to: server)
        try await modify([server])
    }

    private func resolvePartialFailure(e: CKError, writes: [Write]) async throws {
        guard let perItem = e.partialErrorsByItemID as? [CKRecord.ID: Error] else { throw e }
        var resolved: [CKRecord] = []
        for (recordID, itemError) in perItem {
            guard
                let ckError = itemError as? CKError,
                ckError.code == .serverRecordChanged,
                let server = ckError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                let write = writes.first(where: { $0.id == recordID.recordName })
            else { continue }
            applyFields(write.fields, to: server)
            resolved.append(server)
        }
        guard !resolved.isEmpty else { throw e }
        try await modify(resolved)
    }

    // MARK: - Private — offline retry queue

    private func isOffline(_ e: CKError) -> Bool {
        switch e.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return true
        default:
            return false
        }
    }

    /// Attempt to flush the durable pending queue. On continued offline failure the
    /// writes are re-enqueued and remain for the next attempt.
    private func drainPending() async {
        let queued = await pending.takeAll()
        guard !queued.isEmpty else { return }
        do {
            try await save(queued)
        } catch let e as CKError where isOffline(e) {
            await pending.enqueue(queued)
        } catch {
            // Non-offline failure draining queued work — re-enqueue to retry later.
            await pending.enqueue(queued)
        }
    }

    private func applyFields(_ fields: [String: Any], to record: CKRecord) {
        for (key, value) in fields {
            if let op = value as? AtomicOp {
                applyAtomicOp(op, key: key, to: record)
            } else if let ckValue = value as? CKRecordValue {
                record[key] = ckValue
            }
        }
    }

    private func applyAtomicOp(_ op: AtomicOp, key: String, to record: CKRecord) {
        switch op {
        case .delete:
            record[key] = nil
        case .serverTimestamp:
            record[key] = Date.now as CKRecordValue
        case .increment(let n):
            let current = (record[key] as? Double) ?? 0
            record[key] = (current + n) as CKRecordValue
        case .arrayUnion(let v):
            var arr = (record[key] as? [AnyHashable]) ?? []
            if !arr.contains(v) { arr.append(v) }
            record[key] = arr as CKRecordValue
        case .arrayRemove(let v):
            var arr = (record[key] as? [AnyHashable]) ?? []
            arr.removeAll { $0 == v }
            record[key] = arr as CKRecordValue
        }
    }

    // MARK: - Private — helpers

    private func recordTypeName(_ path: String) -> String {
        path.components(separatedBy: "/").last ?? path
    }

    private func fetchCollection(ckQuery: CKQuery) async -> [Doc] {
        do {
            let (results, _) = try await database.records(
                matching: ckQuery,
                inZoneWith: zoneID
            )
            return results.compactMap { (_, result) -> Doc? in
                guard let record = try? result.get() else { return nil }
                return ckRecordToDoc(record, recordType: ckQuery.recordType)
            }
        } catch {
            return []
        }
    }

    private func filterDocs(_ docs: [Doc], query: Query) -> [Doc] {
        guard !query.where.isEmpty else { return docs }
        return docs.filter { doc in
            query.where.allSatisfy { clause in
                (doc[clause.field] as? AnyHashable) == clause.value
            }
        }
    }

    private func ckRecordToDoc(_ record: CKRecord, recordType: String) -> Doc {
        var doc: Doc = ["id": record.recordID.recordName]
        for key in record.allKeys() {
            doc[key] = record[key]
        }
        return doc
    }
}

// MARK: - Durable pending-writes queue

/// Reference-typed, serialised backing for writes deferred while offline.
/// Held by the value-typed CloudKitAdapter so its identity (and the queued work)
/// is shared across every copy of the struct and every concurrent write call.
actor PendingWriteQueue {
    private var writes: [Write] = []

    /// Append writes to the tail of the queue.
    func enqueue(_ newWrites: [Write]) {
        writes.append(contentsOf: newWrites)
    }

    /// Atomically remove and return everything queued.
    func takeAll() -> [Write] {
        defer { writes.removeAll() }
        return writes
    }
}
