import type { Doc, Query, WriteDescriptor, WriteOperation, CacheSnapshot } from '../types.js';
import { isWriteOp } from '../types.js';

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

type CollectionMap = Map<string, Doc>;
type EntityTable = Map<string, CollectionMap>;
type Subscriber = (result: Doc | Doc[] | null) => void;

type Subscription = {
  readonly query: Query;
  readonly cb: Subscriber;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Project a doc to only the requested fields. Pure transform. */
const project = (doc: Doc, fields: readonly string[]): Doc => {
  const out: Doc = {};
  for (const f of fields) {
    if (f in doc) out[f] = doc[f];
  }
  return out;
};

/** Deep structural equality check for plain objects / arrays. */
const deepEqual = (a: unknown, b: unknown): boolean => {
  if (a === b) return true;
  if (a === null || b === null) return a === b;
  if (typeof a !== 'object' || typeof b !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) {
      if (!deepEqual(a[i], b[i])) return false;
    }
    return true;
  }
  const aObj = a as Record<string, unknown>;
  const bObj = b as Record<string, unknown>;
  const aKeys = Object.keys(aObj);
  const bKeys = Object.keys(bObj);
  if (aKeys.length !== bKeys.length) return false;
  for (const k of aKeys) {
    if (!deepEqual(aObj[k], bObj[k])) return false;
  }
  return true;
};

/** Apply a where clause filter to an array of docs. Pure transform. */
const applyWhere = (docs: Doc[], where: Query extends { kind: 'collection' } ? NonNullable<(Query & { kind: 'collection' })['where']> : never): Doc[] => {
  return docs.filter(doc => {
    for (const clause of where) {
      const val = (doc as Record<string, unknown>)[clause.field];
      switch (clause.op) {
        case '==':
          if (!deepEqual(val, clause.value)) return false;
          break;
        case '!=':
          if (deepEqual(val, clause.value)) return false;
          break;
        case '<':
          if (typeof val !== typeof clause.value || (val as number) >= (clause.value as number)) return false;
          break;
        case '<=':
          if (typeof val !== typeof clause.value || (val as number) > (clause.value as number)) return false;
          break;
        case '>':
          if (typeof val !== typeof clause.value || (val as number) <= (clause.value as number)) return false;
          break;
        case '>=':
          if (typeof val !== typeof clause.value || (val as number) < (clause.value as number)) return false;
          break;
        case 'array-contains':
          if (!Array.isArray(val) || !val.some(v => deepEqual(v, clause.value))) return false;
          break;
        case 'in':
          if (!Array.isArray(clause.value) || !(clause.value as unknown[]).some(v => deepEqual(v, val))) return false;
          break;
        case 'not-in':
          if (Array.isArray(clause.value) && (clause.value as unknown[]).some(v => deepEqual(v, val))) return false;
          break;
      }
    }
    return true;
  });
};

/** Apply an orderBy directive. Pure transform. */
const applyOrderBy = (docs: Doc[], orderBy: NonNullable<(Query & { kind: 'collection' })['orderBy']>): Doc[] => {
  return [...docs].sort((a, b) => {
    for (const clause of orderBy) {
      const aVal = (a as Record<string, unknown>)[clause.field];
      const bVal = (b as Record<string, unknown>)[clause.field];
      let cmp = 0;
      if (aVal === undefined && bVal === undefined) continue;
      if (aVal === undefined) cmp = 1;
      else if (bVal === undefined) cmp = -1;
      else if (typeof aVal === 'string' && typeof bVal === 'string') cmp = aVal.localeCompare(bVal);
      else if (typeof aVal === 'number' && typeof bVal === 'number') cmp = aVal - bVal;
      else cmp = String(aVal).localeCompare(String(bVal));
      if (cmp !== 0) return clause.direction === 'desc' ? -cmp : cmp;
    }
    return 0;
  });
};

/** Apply a WriteOp sentinel to the existing field value. Pure transform. */
const applyFieldOp = (existing: unknown, op: Record<string, unknown>): unknown => {
  switch (op['__op'] as string) {
    case '::delete':
      return undefined;
    case '::serverTimestamp':
      return new Date().toISOString();
    case '::increment': {
      const n = op['n'] as number;
      return typeof existing === 'number' ? existing + n : n;
    }
    case '::arrayUnion': {
      const arr = Array.isArray(existing) ? [...existing] : [];
      const val = op['value'];
      if (!arr.some(v => deepEqual(v, val))) arr.push(val);
      return arr;
    }
    case '::arrayRemove': {
      const arr = Array.isArray(existing) ? [...existing] : [];
      const val = op['value'];
      return arr.filter(v => !deepEqual(v, val));
    }
    default:
      return existing;
  }
};

/** Merge write data (with ops) into an existing doc. Pure transform. */
const mergeData = (existing: Doc | undefined, data: Record<string, unknown>): Doc => {
  const base: Doc = existing ? { ...existing } : {};
  for (const [key, val] of Object.entries(data)) {
    if (isWriteOp(val)) {
      const result = applyFieldOp(base[key], val as unknown as Record<string, unknown>);
      if (result === undefined) {
        delete base[key];
      } else {
        base[key] = result;
      }
    } else {
      base[key] = val;
    }
  }
  return base;
};

// ---------------------------------------------------------------------------
// Cache implementation
// ---------------------------------------------------------------------------

export type Cache = {
  /** Subscribe to changes for a query. Returns unsubscribe. */
  subscribe(query: Query, cb: Subscriber): () => void;
  /** Synchronous read. */
  get(query: Query): Doc | Doc[] | undefined | null;
  /** Apply a single WriteDescriptor to the cache synchronously. */
  applyWrite(descriptor: WriteDescriptor): void;
  /** Apply a WriteOperation (single or transaction) synchronously. */
  applyOperation(operation: WriteOperation): void;
  /** Cheap structural-sharing snapshot. */
  snapshot(): CacheSnapshot;
  /** Restore from a snapshot (time travel). */
  restore(snapshot: CacheSnapshot): void;
  /** Seed collection with initial data. */
  seed(collection: string, docs: Doc[]): void;
  /** Full reset. */
  reset(): void;
};

export const createCache = (): Cache => {
  let version = 0;
  let table: EntityTable = new Map();
  const subscriptions: Set<Subscription> = new Set();

  // --- Internal helpers ---

  const getCollection = (name: string): CollectionMap => {
    let col = table.get(name);
    if (!col) {
      col = new Map();
      table.set(name, col);
    }
    return col;
  };

  const read = (query: Query): Doc | Doc[] | undefined | null => {
    if (query.kind === 'doc') {
      const col = table.get(query.collection);
      if (!col) return null;
      const doc = col.get(query.id);
      if (doc === undefined) return null;
      return query.fields ? project(doc, query.fields) : doc;
    }
    // collection
    const col = table.get(query.collection);
    if (!col) return [];
    let docs: Doc[] = Array.from(col.values());
    if (query.where) docs = applyWhere(docs, query.where as Parameters<typeof applyWhere>[1]);
    if (query.orderBy) docs = applyOrderBy(docs, query.orderBy);
    if (query.limit !== undefined) docs = docs.slice(0, query.limit);
    if (query.fields) docs = docs.map(d => project(d, query.fields!));
    return docs;
  };

  const notifySubscribers = (): void => {
    for (const sub of subscriptions) {
      sub.cb(read(sub.query));
    }
  };

  const applyDescriptor = (descriptor: WriteDescriptor): void => {
    const col = getCollection(descriptor.collection);
    switch (descriptor.kind) {
      case 'set': {
        const existing = descriptor.merge ? col.get(descriptor.id) : undefined;
        col.set(descriptor.id, mergeData(existing, descriptor.data as Record<string, unknown>));
        break;
      }
      case 'update': {
        const existing = col.get(descriptor.id);
        col.set(descriptor.id, mergeData(existing, descriptor.data as Record<string, unknown>));
        break;
      }
      case 'delete':
        col.delete(descriptor.id);
        break;
    }
  };

  // --- Public API ---

  const subscribe = (query: Query, cb: Subscriber): (() => void) => {
    const sub: Subscription = { query, cb };
    subscriptions.add(sub);
    // Immediate call with current data
    cb(read(query));
    return () => { subscriptions.delete(sub); };
  };

  const get = (query: Query): Doc | Doc[] | undefined | null => read(query);

  const applyWrite = (descriptor: WriteDescriptor): void => {
    version++;
    applyDescriptor(descriptor);
    notifySubscribers();
  };

  const applyOperation = (operation: WriteOperation): void => {
    version++;
    if (operation.kind === 'transaction') {
      for (const desc of operation.writes) applyDescriptor(desc);
    } else {
      applyDescriptor(operation);
    }
    notifySubscribers();
  };

  const snapshot = (): CacheSnapshot => {
    // Structural sharing: copy only the top-level map; inner maps are shared
    const tableCopy: Map<string, ReadonlyMap<string, Doc>> = new Map();
    for (const [k, v] of table) tableCopy.set(k, new Map(v));
    return { version, table: tableCopy };
  };

  const restore = (snap: CacheSnapshot): void => {
    version = snap.version;
    table = new Map();
    for (const [k, v] of snap.table) table.set(k, new Map(v));
    notifySubscribers();
  };

  const seed = (collection: string, docs: Doc[]): void => {
    version++;
    const col = getCollection(collection);
    for (const doc of docs) {
      const id = (doc as Record<string, unknown>)['id'];
      if (typeof id !== 'string') throw new Error(`seed: doc missing string 'id' field in collection '${collection}'`);
      col.set(id, doc);
    }
    notifySubscribers();
  };

  const reset = (): void => {
    version = 0;
    table = new Map();
    notifySubscribers();
  };

  return { subscribe, get, applyWrite, applyOperation, snapshot, restore, seed, reset };
};
