// CloudKitAdapter — iCloud private database backing store.
//
// subscribe: wraps internal AsyncStream polling in a Task, calls onChange for each emission.
// write: CKModifyRecordsOperation with .changedKeys save policy.
// Atomic ops (arrayUnion, arrayRemove, increment) require fetch-then-modify cycles.
// Collection queries poll every `pollingInterval` seconds (CloudKit push for arbitrary
// queries requires server-side subscription provisioning).

import CloudKit
import Foundation

public struct CloudKitAdapter: Adapter {

    private let database: CKDatabase
    private let pollingInterval: TimeInterval

    public init(
        container: CKContainer = .default(),
        pollingInterval: TimeInterval = 30
    ) {
        self.database = container.privateCloudDatabase
        self.pollingInterval = pollingInterval
    }

    // MARK: - Adapter: subscribe

    public func subscribe(
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) -> @Sendable () -> Void {
        let task = Task {
            let stream = query.id != nil
                ? subscribeSingleDoc(path: query.path, id: query.id!)
                : subscribeCollection(query: query)
            for await docs in stream {
                onChange(docs)
            }
        }
        return { task.cancel() }
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
                let recordID = CKRecord.ID(recordName: id)
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
        let recordID = CKRecord.ID(recordName: write.id)
        let recordType = recordTypeName(write.path)

        let hasAtomics = write.fields.values.contains { $0 is AtomicOp }
        let record: CKRecord
        if hasAtomics {
            record = (try? await database.record(for: recordID))
                ?? CKRecord(recordType: recordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }

        applyFields(write.fields, to: record)

        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        try await database.add(op)
    }

    private func writeBatch(_ writes: [Write]) async throws {
        var records: [CKRecord] = []
        for write in writes {
            let recordID = CKRecord.ID(recordName: write.id)
            let recordType = recordTypeName(write.path)
            let hasAtomics = write.fields.values.contains { $0 is AtomicOp }
            let record: CKRecord
            if hasAtomics {
                record = (try? await database.record(for: recordID))
                    ?? CKRecord(recordType: recordType, recordID: recordID)
            } else {
                record = CKRecord(recordType: recordType, recordID: recordID)
            }
            applyFields(write.fields, to: record)
            records.append(record)
        }
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        try await database.add(op)
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
            let (results, _) = try await database.records(matching: ckQuery)
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
