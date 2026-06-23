/**
 * FirestoreAdapter — wraps Firebase Firestore v9+ modular SDK.
 *
 * Peer dependency: 'firebase' (^9 or ^10). Not bundled.
 * Install separately: npm i firebase
 */
import type { Adapter, Query, Doc, WriteOperation, WriteDescriptor } from '../types.js';
import { isWriteOp } from '../types.js';

// We import Firebase types lazily to avoid bundling the SDK.
// The actual firebase/firestore module is a peer dependency.
type Firestore = import('firebase/firestore').Firestore;
type CollectionReference = import('firebase/firestore').CollectionReference;
type DocumentReference = import('firebase/firestore').DocumentReference;
type QuerySnapshot = import('firebase/firestore').QuerySnapshot;
type FirestoreModule = typeof import('firebase/firestore');

let _firestoreModule: FirestoreModule | null = null;

const loadFirestore = async (): Promise<FirestoreModule> => {
  if (!_firestoreModule) {
    _firestoreModule = await import('firebase/firestore');
  }
  return _firestoreModule;
};

// ---------------------------------------------------------------------------
// Sentinel translation
// ---------------------------------------------------------------------------

const translateValue = async (v: unknown, fs: FirestoreModule): Promise<unknown> => {
  if (!isWriteOp(v)) return v;
  const op = v as Record<string, unknown>;
  switch (op['__op'] as string) {
    case '::delete': return fs.deleteField();
    case '::serverTimestamp': return fs.serverTimestamp();
    case '::increment': return fs.increment(op['n'] as number);
    case '::arrayUnion': return fs.arrayUnion(op['value']);
    case '::arrayRemove': return fs.arrayRemove(op['value']);
    default: return v;
  }
};

const translateData = async (
  data: Record<string, unknown>,
  fs: FirestoreModule,
): Promise<Record<string, unknown>> => {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(data)) {
    out[k] = await translateValue(v, fs);
  }
  return out;
};

// ---------------------------------------------------------------------------
// Query helpers
// ---------------------------------------------------------------------------

const buildCollectionQuery = (
  db: Firestore,
  query: Query & { kind: 'collection' },
  fs: FirestoreModule,
): import('firebase/firestore').Query => {
  const colRef = fs.collection(db, query.collection) as CollectionReference;
  const constraints: import('firebase/firestore').QueryConstraint[] = [];

  if (query.where) {
    for (const clause of query.where) {
      constraints.push(fs.where(clause.field, clause.op, clause.value));
    }
  }
  if (query.orderBy) {
    for (const ob of query.orderBy) {
      constraints.push(fs.orderBy(ob.field, ob.direction));
    }
  }
  if (query.limit !== undefined) {
    constraints.push(fs.limit(query.limit));
  }
  return fs.query(colRef, ...constraints);
};

const snapshotToDocs = (snap: QuerySnapshot, fields?: readonly string[]): Doc[] => {
  return snap.docs.map(d => {
    const data = { id: d.id, ...d.data() } as Doc;
    if (!fields) return data;
    const out: Doc = {};
    for (const f of fields) if (f in data) out[f] = data[f];
    return out;
  });
};

// ---------------------------------------------------------------------------
// FirestoreAdapter
// ---------------------------------------------------------------------------

export const FirestoreAdapter = (db: Firestore): Adapter => {
  const subscribe = (query: Query, onChange: (docs: Doc | Doc[] | null) => void): (() => void) => {
    let unsub: (() => void) | null = null;

    // Async init — snapshot listener starts immediately
    void (async () => {
      const fs = await loadFirestore();
      if (query.kind === 'doc') {
        const ref = fs.doc(db, query.collection, query.id) as DocumentReference;
        unsub = fs.onSnapshot(ref, snap => {
          if (!snap.exists()) {
            onChange(null);
            return;
          }
          const data = { id: snap.id, ...snap.data() } as Doc;
          if (query.fields) {
            const out: Doc = {};
            for (const f of query.fields) if (f in data) out[f] = data[f];
            onChange(out);
          } else {
            onChange(data);
          }
        });
      } else {
        const q = buildCollectionQuery(db, query, fs);
        unsub = fs.onSnapshot(q, snap => {
          onChange(snapshotToDocs(snap, query.fields));
        });
      }
    })();

    return () => { unsub?.(); };
  };

  const write = async (operation: WriteOperation): Promise<void> => {
    const fs = await loadFirestore();

    const applyDescriptor = async (descriptor: WriteDescriptor): Promise<void> => {
      const ref = fs.doc(db, descriptor.collection, descriptor.id) as DocumentReference;
      switch (descriptor.kind) {
        case 'set': {
          const data = await translateData(descriptor.data as Record<string, unknown>, fs);
          if (descriptor.merge) {
            await fs.setDoc(ref, data, { merge: true });
          } else {
            await fs.setDoc(ref, data);
          }
          break;
        }
        case 'update': {
          const data = await translateData(descriptor.data as Record<string, unknown>, fs);
          await fs.updateDoc(ref, data);
          break;
        }
        case 'delete':
          await fs.deleteDoc(ref);
          break;
      }
    };

    if (operation.kind === 'transaction') {
      await fs.runTransaction(db, async t => {
        for (const desc of operation.writes) {
          const ref = fs.doc(db, desc.collection, desc.id) as DocumentReference;
          switch (desc.kind) {
            case 'set': {
              const data = await translateData(desc.data as Record<string, unknown>, fs);
              t.set(ref, data, desc.merge ? { merge: true } : undefined as never);
              break;
            }
            case 'update': {
              const data = await translateData(desc.data as Record<string, unknown>, fs);
              t.update(ref, data);
              break;
            }
            case 'delete':
              t.delete(ref);
              break;
          }
        }
      });
    } else {
      await applyDescriptor(operation);
    }
  };

  return { subscribe, write };
};
