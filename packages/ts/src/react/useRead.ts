import { useSyncExternalStore } from 'react';
import type { Query, Doc } from '../types.js';
import type { Cache } from '../core/cache.js';

// ---------------------------------------------------------------------------
// Structural equality snapshot cache per subscription
// ---------------------------------------------------------------------------

/**
 * Creates a useRead hook bound to a specific Cache instance.
 * Uses useSyncExternalStore for tearing-free concurrent-mode reads.
 */
export const createUseRead =
  (cache: Cache) =>
  (query: Query): Doc | Doc[] | undefined | null => {
    // We use a stable serialized key for the query to avoid re-subscribing on
    // every render when the caller constructs a new object literal inline.
    // The subscription is driven by cache.subscribe which calls back immediately.

    const subscribe = (onStoreChange: () => void): (() => void) => {
      return cache.subscribe(query, () => onStoreChange());
    };

    const getSnapshot = (): Doc | Doc[] | undefined | null => {
      return cache.get(query);
    };

    const getServerSnapshot = (): Doc | Doc[] | undefined | null => {
      return cache.get(query);
    };

    // eslint-disable-next-line react-hooks/rules-of-hooks
    return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  };
