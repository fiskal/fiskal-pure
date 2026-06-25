// NSUserDefaultsAdapter — local persistence via UserDefaults.
//
// Keys: "statelessui.<path>.<id>" stored as JSON Data.
// subscribe: emits current value immediately, re-emits on every didChangeNotification.
// write: synchronous read-modify-write; atomic ops applied client-side.
// Where/orderBy: equality only; applied client-side after reading the collection.

import Foundation

private final class ObserverBox: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
}

public enum NSUserDefaultsAdapterError: Error, Sendable {
    case invalidSuite(String)
}

public struct NSUserDefaultsAdapter: Adapter {

    private let defaults: UserDefaults

    public init(suiteName: String?) throws {
        guard let name = suiteName else {
            throw NSUserDefaultsAdapterError.invalidSuite("NSUserDefaultsAdapter requires a non-nil suite name")
        }
        guard let suite = UserDefaults(suiteName: name) else {
            throw NSUserDefaultsAdapterError.invalidSuite("NSUserDefaultsAdapter requires a non-nil suite name")
        }
        self.defaults = suite
    }

    // MARK: - Adapter: subscribe

    public func subscribe(
        query: Query,
        onChange: @Sendable @escaping ([Doc]) -> Void
    ) -> @Sendable () -> Void {
        onChange(readDocs(for: query))

        let capturedDefaults = defaults
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: capturedDefaults,
            queue: nil
        ) { [capturedDefaults] _ in
            onChange(Self.readDocs(for: query, defaults: capturedDefaults))
        }
        let box = ObserverBox(token)
        return { NotificationCenter.default.removeObserver(box.token) }
    }

    // MARK: - Adapter: write

    public func write(_ operation: WriteOperation) async throws {
        let writes: [Write]
        switch operation {
        case .single(let w):           writes = [w]
        case .batch(let ws),
             .transaction(let ws):     writes = ws
        }
        for write in writes {
            applyWrite(write)
        }
    }

    // MARK: - Private — read

    private func readDocs(for query: Query) -> [Doc] {
        Self.readDocs(for: query, defaults: defaults)
    }

    private static func readDocs(for query: Query, defaults: UserDefaults) -> [Doc] {
        if let id = query.id {
            return readDoc(path: query.path, id: id, defaults: defaults).map { [$0] } ?? []
        }
        var docs = readAllDocs(path: query.path, defaults: defaults)
        if !query.where.isEmpty {
            docs = docs.filter { doc in
                query.where.allSatisfy { clause in
                    (doc[clause.field] as? AnyHashable) == clause.value
                }
            }
        }
        return docs
    }

    private static func readDoc(path: String, id: String, defaults: UserDefaults) -> Doc? {
        guard let data = defaults.data(forKey: key(path: path, id: id)),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        dict["id"] = id
        return dict
    }

    private static func readAllDocs(path: String, defaults: UserDefaults) -> [Doc] {
        let prefix = collectionPrefix(path)
        return defaults.dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix(prefix) }
            .compactMap { fullKey -> Doc? in
                let id = String(fullKey.dropFirst(prefix.count))
                return readDoc(path: path, id: id, defaults: defaults)
            }
    }

    // MARK: - Private — write

    private func applyWrite(_ write: Write) {
        let k = Self.key(path: write.path, id: write.id)
        var stored: [String: Any]
        if let data = defaults.data(forKey: k),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            stored = dict
        } else {
            stored = [:]
        }

        for (field, value) in write.fields {
            if let op = value as? AtomicOp {
                switch op {
                case .delete:
                    stored.removeValue(forKey: field)
                case .serverTimestamp:
                    stored[field] = ISO8601DateFormatter().string(from: .now)
                case .increment(let n):
                    stored[field] = ((stored[field] as? Double) ?? 0) + n
                case .arrayUnion(let v):
                    var arr = stored[field] as? [AnyHashable] ?? []
                    if !arr.contains(v) { arr.append(v) }
                    stored[field] = arr
                case .arrayRemove(let v):
                    var arr = stored[field] as? [AnyHashable] ?? []
                    arr.removeAll { $0 == v }
                    stored[field] = arr
                }
            } else {
                stored[field] = value
            }
        }

        stored.removeValue(forKey: "id")
        if let data = try? JSONSerialization.data(withJSONObject: stored) {
            defaults.set(data, forKey: k)
        }
    }

    // MARK: - Private — key helpers

    private static func key(path: String, id: String) -> String {
        "statelessui.\(path).\(id)"
    }

    private static func collectionPrefix(_ path: String) -> String {
        "statelessui.\(path)."
    }
}
