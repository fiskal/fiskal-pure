// ---------------------------------------------------------------------------
// CloudKitAdapter — iCloud private database backing store
// ---------------------------------------------------------------------------
//
// Adapter protocol:
//   subscribe(query:) -> AsyncStream<[Doc]>
//   write(_ operation: WriteOperation) async throws
//
// Design notes:
//   - Uses CKContainer.default().privateCloudDatabase throughout.
//   - Single-doc subscriptions: fetch once, then watch via CKDatabaseSubscription
//     filtered to a specific recordID.
//   - Collection subscriptions: CKQuery with NSPredicate, re-polled every 30 s.
//     CloudKit push for arbitrary queries requires server-side subscription setup
//     that callers must provision separately; polling is the safe default.
//   - Atomic ops (::arrayUnion, ::arrayRemove, ::increment) require a fetch-then-
//     modify cycle because CloudKit has no server-side field-level atomics.
//   - Batch writes use CKModifyRecordsOperation with savePolicy .changedKeys.
//   - Record type is derived from collection name (strips "cloudkit/" prefix).
//   - All CKRecord fields are bridged to native Swift types via CKRecordValue.

import CloudKit
import Foundation

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A document from the backing store. Always has an `id` string key.
public typealias Doc = [String: Any]

/// Atomic write operations that map to CloudKit fetch-then-modify cycles.
public enum AtomicOp {
    case arrayUnion([Any])
    case arrayRemove([Any])
    case increment(Double)
    case serverTimestamp
    case delete
}

/// A plain value or an atomic operation sentinel for a single field.
public enum FieldValue {
    case value(Any)
    case atomic(AtomicOp)
}

public typealias FieldMap = [String: FieldValue]

/// Describes a single write to the backing store.
public struct WriteDescriptor {
    public let collection: String
    public let id: String
    /// When nil and delete is false, an empty document is upserted.
    public let fields: FieldMap?
    /// Merge semantics: update only the provided keys.
    public let merge: Bool
    /// When true, delete the entire document.
    public let delete: Bool

    public init(
        collection: String,
        id: String,
        fields: FieldMap? = nil,
        merge: Bool = false,
        delete: Bool = false
    ) {
        self.collection = collection
        self.id = id
        self.fields = fields
        self.merge = merge
        self.delete = delete
    }
}

/// A query against a collection or a single document.
public struct Query {
    public let collection: String
    public let id: String?
    /// Shallow equality filter; applied client-side for collection queries.
    public let `where`: [String: Any]?
    /// Field projection — return only these keys plus `id`.
    public let fields: [String]?

    public init(
        collection: String,
        id: String? = nil,
        where whereClause: [String: Any]? = nil,
        fields: [String]? = nil
    ) {
        self.collection = collection
        self.id = id
        self.where = whereClause
        self.fields = fields
    }
}

/// One write or many writes applied atomically.
public enum WriteOperation {
    case single(WriteDescriptor)
    case batch([WriteDescriptor])
}

/// Adapter protocol — backing store is the only thing that changes.
public protocol Adapter {
    func subscribe(query: Query) -> AsyncStream<[Doc]>
    func write(_ operation: WriteOperation) async throws
}

// ---------------------------------------------------------------------------
// CloudKitAdapter
// ---------------------------------------------------------------------------

public struct CloudKitAdapter: Adapter {

    private let database: CKDatabase
    private let pollingInterval: TimeInterval

    /// - Parameters:
    ///   - container: CKContainer to use. Defaults to `.default()`.
    ///   - pollingInterval: How often to re-poll collection queries (seconds).
    ///     Default is 30. CloudKit push for arbitrary queries needs server setup.
    public init(
        container: CKContainer = .default(),
        pollingInterval: TimeInterval = 30
    ) {
        self.database = container.privateCloudDatabase
        self.pollingInterval = pollingInterval
    }

    // -----------------------------------------------------------------------
    // MARK: subscribe
    // -----------------------------------------------------------------------

    public func subscribe(query: Query) -> AsyncStream<[Doc]> {
        if let id = query.id {
            return subscribeSingleDoc(collection: query.collection, id: id)
        } else {
            return subscribeCollection(query: query)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: write
    // -----------------------------------------------------------------------

    public func write(_ operation: WriteOperation) async throws {
        let descs: [WriteDescriptor]
        switch operation {
        case .single(let d):
            descs = [d]
        case .batch(let ds):
            descs = ds
        }

        if descs.count == 1 {
            try await writeSingle(descs[0])
        } else {
            try await writeBatch(descs)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — single-doc subscription
    // -----------------------------------------------------------------------

    private func subscribeSingleDoc(
        collection: String,
        id: String
    ) -> AsyncStream<[Doc]> {
        AsyncStream { continuation in
            // Fetch current state immediately.
            let recordType = recordTypeName(collection)
            let recordID = CKRecord.ID(recordName: id)

            Task {
                do {
                    let record = try await database.record(for: recordID)
                    let doc = ckRecordToDoc(record, recordType: recordType)
                    continuation.yield(doc.map { [$0] } ?? [])
                } catch let error as CKError where error.code == .unknownItem {
                    continuation.yield([])
                } catch {
                    continuation.yield([])
                }

                // Set up a subscription so CloudKit notifies us on changes.
                // CKDatabaseSubscription fires on any record change; we filter
                // by recordID inside the notification handler.
                let subscriptionID = "\(recordType)-\(id)"
                let ckSubscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
                let notificationInfo = CKSubscription.NotificationInfo()
                notificationInfo.shouldSendContentAvailable = true
                ckSubscription.notificationInfo = notificationInfo

                do {
                    try await database.save(ckSubscription)
                } catch {
                    // Subscription registration failed; polling not set up.
                    // The initial fetch above still delivered the current value.
                }

                // Poll for changes every 30 s as a safety net alongside push.
                // In production, the app handles incoming remote notifications
                // and calls back into the adapter to re-fetch.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    do {
                        let record = try await database.record(for: recordID)
                        let doc = ckRecordToDoc(record, recordType: recordType)
                        continuation.yield(doc.map { [$0] } ?? [])
                    } catch let error as CKError where error.code == .unknownItem {
                        continuation.yield([])
                    } catch {
                        // Transient error — yield nothing, try again next interval.
                    }
                }
            }

            continuation.onTermination = { _ in
                // Cleanup: the outer Task will observe isCancelled via Task.sleep.
            }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — collection subscription (polling)
    // -----------------------------------------------------------------------

    private func subscribeCollection(query: Query) -> AsyncStream<[Doc]> {
        AsyncStream { continuation in
            Task {
                let recordType = recordTypeName(query.collection)
                let predicate = buildPredicate(where: query.where)
                let ckQuery = CKQuery(recordType: recordType, predicate: predicate)

                // Emit current state immediately.
                let docs = await fetchCollection(ckQuery: ckQuery)
                let filtered = applyWhereFilter(docs, where: query.where)
                continuation.yield(filtered)

                // Poll every `pollingInterval` seconds.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    let refreshed = await fetchCollection(ckQuery: ckQuery)
                    let filteredRefreshed = applyWhereFilter(refreshed, where: query.where)
                    continuation.yield(filteredRefreshed)
                }
            }

            continuation.onTermination = { _ in }
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — write helpers
    // -----------------------------------------------------------------------

    private func writeSingle(_ desc: WriteDescriptor) async throws {
        let recordType = recordTypeName(desc.collection)
        let recordID = CKRecord.ID(recordName: desc.id)

        if desc.delete {
            try await database.deleteRecord(withID: recordID)
            return
        }

        guard let fields = desc.fields, !fields.isEmpty else { return }

        // Determine whether we need a prior fetch (atomic ops or merge).
        let needsFetch = desc.merge || fields.values.contains(where: {
            if case .atomic = $0 { return true }
            return false
        })

        let record: CKRecord
        if needsFetch {
            record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: recordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

        try applyFieldMap(fields, to: record)

        let op = CKModifyRecordsOperation(
            recordsToSave: [record],
            recordIDsToDelete: nil
        )
        op.savePolicy = .changedKeys
        try await database.add(op)
    }

    private func writeBatch(_ descs: [WriteDescriptor]) async throws {
        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []

        for desc in descs {
            let recordType = recordTypeName(desc.collection)
            let recordID = CKRecord.ID(recordName: desc.id)

            if desc.delete {
                recordIDsToDelete.append(recordID)
                continue
            }

            guard let fields = desc.fields, !fields.isEmpty else { continue }

            let needsFetch = desc.merge || fields.values.contains(where: {
                if case .atomic = $0 { return true }
                return false
            })

            let record: CKRecord
            if needsFetch {
                record = (try? await database.record(for: recordID))
                    ?? CKRecord(recordTyp
