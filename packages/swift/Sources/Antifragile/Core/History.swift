// StatelessUI — History
// Append-only log of every dispatched mutate. Supports back/forward/goto for
// time-travel debugging. Thread-safe via @MainActor (same actor as Cache + Store).

import Foundation
import Observation

@Observable
@MainActor
public final class HistoryLog {

    // MARK: - State
    private(set) public var entries: [HistoryEntry] = []
    private(set) public var cursor: Int = -1   // index of the "current" entry; -1 = empty

    // MARK: - Append

    /// Records a dispatched action. Truncates any forward entries (like a browser).
    public func append(_ entry: HistoryEntry) {
        // Drop any entries that were "in the future" relative to the cursor.
        if cursor < entries.count - 1 {
            entries = Array(entries[0...cursor])
        }
        entries.append(entry)
        cursor = entries.count - 1
    }

    // MARK: - Navigation

    /// Move the cursor one step back. Returns the entry moved to, or nil at start.
    @discardableResult
    public func back() -> HistoryEntry? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    /// Move the cursor one step forward. Returns the entry moved to, or nil at end.
    @discardableResult
    public func forward() -> HistoryEntry? {
        guard cursor < entries.count - 1 else { return nil }
        cursor += 1
        return entries[cursor]
    }

    /// Jump to an arbitrary index. Clamps to valid range.
    @discardableResult
    public func goto(index: Int) -> HistoryEntry? {
        guard !entries.isEmpty else { return nil }
        cursor = min(max(0, index), entries.count - 1)
        return entries[cursor]
    }

    // MARK: - Read

    /// Full log in chronological order.
    public func log() -> [HistoryEntry] { entries }

    /// The entry at the current cursor position.
    public var current: HistoryEntry? {
        guard cursor >= 0, cursor < entries.count else { return nil }
        return entries[cursor]
    }

    // MARK: - Reset

    public func clear() {
        entries = []
        cursor = -1
    }
}
