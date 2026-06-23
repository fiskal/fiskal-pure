import type { HistoryEntry, HistoryAPI, WriteOperation, CacheSnapshot } from '../types.js';
import type { Cache } from './cache.js';

// ---------------------------------------------------------------------------
// HistoryLog — append-only, with a cursor for time travel
// ---------------------------------------------------------------------------

export type HistoryLog = HistoryAPI & {
  /** Record a new entry. Truncates any forward history after current cursor. */
  record(mutate: string, operation: WriteOperation, before: CacheSnapshot, after: CacheSnapshot): void;
  /** Current cursor index (points at the last applied entry). */
  cursor(): number;
};

export const createHistoryLog = (cache: Cache): HistoryLog => {
  const entries: HistoryEntry[] = [];
  let cursor = -1;

  const record = (
    mutate: string,
    operation: WriteOperation,
    before: CacheSnapshot,
    after: CacheSnapshot,
  ): void => {
    // Truncate any forward history (branching is not supported — linear only)
    if (cursor < entries.length - 1) {
      entries.splice(cursor + 1);
    }
    const entry: HistoryEntry = {
      index: entries.length,
      at: new Date().toISOString(),
      mutate,
      operation,
      before,
      after,
    };
    entries.push(entry);
    cursor = entries.length - 1;
  };

  const log = (): readonly HistoryEntry[] => [...entries];

  const back = (): void => {
    if (cursor < 0) return;
    const entry = entries[cursor];
    if (!entry) return;
    cache.restore(entry.before);
    cursor--;
  };

  const forward = (): void => {
    if (cursor >= entries.length - 1) return;
    cursor++;
    const entry = entries[cursor];
    if (!entry) return;
    cache.restore(entry.after);
  };

  const goto = (index: number): void => {
    if (index < 0 || index >= entries.length) return;
    const entry = entries[index];
    if (!entry) return;
    cache.restore(entry.after);
    cursor = index;
  };

  return {
    record,
    log,
    back,
    forward,
    goto,
    cursor: () => cursor,
  };
};
