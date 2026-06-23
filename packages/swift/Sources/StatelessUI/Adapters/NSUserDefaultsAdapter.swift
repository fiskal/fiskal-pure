// ---------------------------------------------------------------------------
// NSUserDefaultsAdapter — local persistence via UserDefaults
// ---------------------------------------------------------------------------
//
// Adapter protocol:
//   subscribe(query:) -> AsyncStream<[Doc]>
//   write(_ operation: WriteOperation) async throws
//
// Design notes:
//   - Keys are "statelessui.<collection>.<id>" stored as JSON Data.
//   - subscribe() emits the current value immediately, then re-emits on every
//     UserDefaults.didChangeNotification (any key change in the suite).
//   - Where/orderBy predicates: not supported at the storage level.
//     If the query has a .where clause on a collection query, results are
//     filtered client-side after reading all docs for that collection.
//   - write() encodes fields as JSON and merges them into the existing stored
//     doc (same semantics as merge=true in Firestore). For delete operations
//     the key is removed entirely.
//   - Atomic ops are resolved with a read-modify-write cycle (synchronous
//     because UserDefaults is itself synchronous).
//   - The `write(_ operation:) async throws` signature fulfils the Adapter
//     protocol; the actual work is synchronous.

import Foundation

// ---------------------------------------------------------------------------
// NSUserDefaultsAdapter
// ---------------------------------------------------------------------------

public struct NSUserDefaultsAdapter: Adapter {

    private let defaults: UserDefaults

    /// - Parameter suiteName: App group suite name (e.g. "group.app.fiskal").
    ///   Pass `nil` to use the standard `UserDefaults.standard`.
    public init(suiteName: String? = nil) {
        if let name = suiteName {
            self.defaults = UserDefaults(suiteName: name) ?? .standard
        } else {
            self.defaults = .standard
        }
    }

    // -----------------------------------------------------------------------
    // MARK: subscribe
    // -----------------------------------------------------------------------

    public func subscribe(query: Query) -> AsyncStream<[Doc]> {
        AsyncStream { continuation in
            // Deliver the current value before setting up the notification.
            let current = readDocs(for: query)
            continuation.yield(current)

            // Observe all UserDefaults changes and re-read the relevant keys.
            let observer = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: nil
            ) { _ in
                let updated = readDocs(for: query)
                continuation.yield(updated)
            }

            continuation.onTermination = { _ in
                NotificationCenter.default.removeObserver(observer)
            }
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

        for desc in descs {
            try applyDescriptor(desc)
        }
    }

    // -----------------------------------------------------------------------
    // MARK: Private — key scheme
    // -----------------------------------------------------------------------

    private func key(collection: String, id: String) -> String {
        "statelessui.\(collection).\(id)"
    }

    /// Prefix used to enumerate all docs in a collection.
    private func collectionPrefix(_ collection: String) -> String {
        "statelessui.\(collection)."
    }

    // -----------------------------------------------------------------------
    // MARK: Private — read helpers
    // -----------------------------------------------------------------------

    private func readDoc(collection: String, id: String) -> Doc? {
        let k = key(collection: collection, id: id)
        guard let data = defaults.data(forKey: k) else { return nil }
        guard var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        dict["id"] = id
        return dict
    }

    private func readAllDocs(collection: String) -> [Doc] {
        let prefix = collectionPrefix(collection)
        return defaults.dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix(prefix) }
            .compactMap { fullKey -> Doc? in
                let id = String(fullKey.dropFirst(prefix.count))
                return readDoc(collection: collection, id: id)
            }
    }

    private func readDocs(for query: Query) -> [Doc] {
        if let id = query.id {
            if let doc = readDoc(collection: query.collection, id: id) {
                return [doc]
            }
            return []
        }

        var docs = readAllDocs(collection: query.collection)

        // Client-side where filter.
        if let clause = query.where, !clause.isEmpty {
            docs = docs.filter { doc in
                clause.allSatisfy { key, value in
                    guard let docValue = doc[key] else { return false }
                    return "\(docValue)" == "\(value)"
                }
            }
        }

        return docs
    }

    // -----------------------------------------------------------------------
    // MARK: Private — write helpers
    // -----------------------------------------------------------------------

    private func applyDescriptor(_ desc: WriteDescriptor) throws {
        let k = key(collection: desc.collection, id: desc.id)

        if desc.delete {
            defaults.removeObject(forKey: k)
            return
        }

        guard let fields = desc.fields, !fields.isEmpty else { return }

        // Load existing stored dict for merge / atomic ops.
        var stored: [String: Any]
        if let existingData = defaults.data(forKey: k),
           let existingDict = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
            stored = existingDict
        } else {
            stored = [:]
        }

        // Apply each field.
        for (key, fieldValue) in fields {
            switch fieldValue {
            case .value(let raw):
                if case .atomic(let op) = fieldValue, case .delete = op {
                    stored.removeValue(forKey: key)
                } else {
                    stored[key] = raw
                }

            case .atomic(let op):
                switch op {
                case .arrayUnion(let additions):
                    var arr = stored[key] as? [Any] ?? []
                    for v in additions {
                        let exists = arr.contains(where: { "\($0)" == "\(v)" })
                        if !exists { arr.append(v) }
                    }
                    stored[key] = arr

                case .arrayRemove(let removals):
                    let arr = stored[key] as? [Any] ?? []
                    let removalSet = Set(removals.map { "\($0)" })
                    stored[key] = arr.filter { !removalSet.contains("\($0)") }

                case .increment(let n):
                    let current = (stored[key] as? Double) ?? 0.0
                    stored[key] = current + n

                case .serverTimestamp:
                    stored[key] = ISO8601DateFormatter().string(from: Date())

                case .delete:
                    stored.removeValue(forKey: key)
                }
            }
        }

        // Remove the doc-level `id` key before storing (it is synthesised on read).
        stored.removeValue(forKey: "id")

        let data = try JSONSerialization.data(withJSONObject: stored)
        defaults.set(data, forKey: k)
    }
}
