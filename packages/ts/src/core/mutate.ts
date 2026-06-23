import type {
  MutateConfig,
  WriteOperation,
  StoreInstance,
  BoundMutate,
} from '../types.js';
import type { Cache } from './cache.js';
import type { HistoryLog } from './history.js';
import type { AdapterRegistry } from './store.js';

// ---------------------------------------------------------------------------
// createMutate
// ---------------------------------------------------------------------------

/**
 * Builds a MutateConfig descriptor.
 * The returned object is consumed by registerMutate inside createStore;
 * it is not itself executable until bound to a store.
 */
export const createMutate = <TArgs = unknown, TRead = unknown>(
  config: MutateConfig<TArgs, TRead>,
): MutateConfig<TArgs, TRead> => config;

// ---------------------------------------------------------------------------
// Internal: bind a MutateConfig to live cache + adapters
// ---------------------------------------------------------------------------

export type MutateOptions = {
  readonly cache: Cache;
  readonly history: HistoryLog;
  readonly adapters: AdapterRegistry;
  /** The store instance (passed as second arg to config.read). */
  readonly store: StoreInstance;
};

/**
 * Binds a MutateConfig to the live cache and adapter registry,
 * returning an async BoundMutate function.
 *
 * Strategy:
 *  1. Optimistic write — apply to cache immediately.
 *  2. Optional read — if config.read is defined, await it.
 *  3. Remote write — call adapter.write for each affected collection.
 *  4. On failure — roll back cache to pre-optimistic snapshot.
 */
export const bindMutate = <TArgs = unknown, TRead = unknown>(
  config: MutateConfig<TArgs, TRead>,
  opts: MutateOptions,
): BoundMutate<TArgs> => {
  const { cache, history, adapters, store } = opts;

  return async (args: TArgs): Promise<void> => {
    // --- Optional read step ---
    let readResult: TRead | undefined;
    if (config.read) {
      readResult = await config.read(args, store);
    }

    // --- Produce the write operation ---
    const operation: WriteOperation = config.write(args, readResult);

    // --- Optimistic cache update ---
    const before = cache.snapshot();
    cache.applyOperation(operation);
    const after = cache.snapshot();

    // --- Record history ---
    history.record(config.action, operation, before, after);

    // --- Remote write (with rollback on failure) ---
    try {
      const collectionsInvolved = collectionsFromOperation(operation);
      for (const collection of collectionsInvolved) {
        const adapter = adapters.get(collection);
        if (adapter) {
          await adapter.write(operation);
          // Only write once per operation even if multiple collections share an adapter
          break;
        }
      }
    } catch (err) {
      // Rollback optimistic update
      cache.restore(before);
      throw err;
    }
  };
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/** Collect unique collection names referenced in a WriteOperation. */
const collectionsFromOperation = (operation: WriteOperation): ReadonlySet<string> => {
  const cols = new Set<string>();
  if (operation.kind === 'transaction') {
    for (const w of operation.writes) cols.add(w.collection);
  } else {
    cols.add(operation.collection);
  }
  return cols;
};
