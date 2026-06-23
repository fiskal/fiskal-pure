import type {
  StoreConfig,
  StoreDomainConfig,
  StoreInstance,
  HistoryAPI,
  BoundMutate,
  Query,
  Doc,
  Adapter,
} from '../types.js';
import { createCache } from './cache.js';
import { createHistoryLog } from './history.js';
import { bindMutate } from './mutate.js';
import { createUseRead } from '../react/useRead.js';

// ---------------------------------------------------------------------------
// AdapterRegistry — maps collection name → adapter
// ---------------------------------------------------------------------------

export type AdapterRegistry = Map<string, Adapter>;

// ---------------------------------------------------------------------------
// createStore
// ---------------------------------------------------------------------------

export const createStore = (config: StoreConfig): StoreInstance => {
  const cache = createCache();
  const history = createHistoryLog(cache);
  const adapterRegistry: AdapterRegistry = new Map();
  const allActions: Record<string, BoundMutate> = {};

  // Forward reference so bindMutate can receive the store instance
  let storeInstance: StoreInstance;

  const registerDomain = (name: string, domainConfig: StoreDomainConfig): void => {
    const { adapter, models: _models, mutates } = domainConfig;

    // Register adapter under the domain name as the collection key.
    // Individual mutates may span collections, but we key by domain for lookup.
    adapterRegistry.set(name, adapter);

    // Also wire up adapter subscriptions for any models
    if (_models) {
      for (const collection of Object.keys(_models)) {
        if (!adapterRegistry.has(collection)) adapterRegistry.set(collection, adapter);
      }
    }

    // Register and bind mutates
    if (mutates) {
      for (const [muteName, muteConfig] of Object.entries(mutates)) {
        allActions[muteName] = bindMutate(muteConfig, {
          cache,
          history,
          adapters: adapterRegistry,
          // storeInstance is filled in below
          get store() { return storeInstance; },
        });
      }
    }
  };

  // Register all domains in initial config
  for (const [name, domainConfig] of Object.entries(config)) {
    registerDomain(name, domainConfig);
  }

  // Build the React hook (lazy: only created if React is available)
  const useRead = createUseRead(cache);

  storeInstance = {
    useRead,

    actions: allActions,

    get(query: Query): Doc | Doc[] | undefined | null {
      return cache.get(query);
    },

    seed(collection: string, docs: Doc[]): void {
      cache.seed(collection, docs);
    },

    reset(): void {
      cache.reset();
    },

    addStore(name: string, domainConfig: StoreDomainConfig): void {
      registerDomain(name, domainConfig);
    },

    history: {
      log: () => history.log(),
      back: () => history.back(),
      forward: () => history.forward(),
      goto: (index: number) => history.goto(index),
    } satisfies HistoryAPI,
  };

  return storeInstance;
};
