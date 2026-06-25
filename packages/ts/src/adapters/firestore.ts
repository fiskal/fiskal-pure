/**
 * FirestoreAdapter — wraps Firebase Firestore v9+ modular SDK.
 *
 * Peer dependency: 'firebase' (^9 or ^10). Not bundled.
 * Install separately: npm i firebase
 */
import type {
  Adapter,
  AtomicOp,
  Doc,
  OnChangeCallback,
  Query,
  Unsubscribe,
  WriteDescriptor,
  WriteOp,
} from '../types.js'
import { isAtomicOp } from '../types.js'

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

const translateValue = (v: unknown, fs: FirestoreModule): unknown => {
  if (!isAtomicOp(v)) return v;
  const op = v as AtomicOp;
  switch (op.__op) {
    case '::delete': return fs.deleteField();
    case '::serverTimestamp': return fs.serverTimestamp();
    case '::increment': return fs.increment(op.n);
    case '::arrayUnion': return fs.arrayUnion(...op.values);
    case '::arrayRemove': return fs.arrayRemove(...op.values);
    default: return v;
  }
};

const translateData = (
  data: Record<string, unknown>,
  fs: FirestoreModule,
): Record<string, unknown> => {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(data)) {
    out[k] = translateValue(v, fs);
  }
  return out;
};

// ---------------------------------------------------------------------------
// Query helpers
// ---------------------------------------------------------------------------

const buildCollectionQuery = (
  db: Firestore,
  query: Query,
  fs: FirestoreModule,
): import('firebase/firestore').Query => {
  const colRef = fs.collection(db, query.path) as CollectionReference;
  const constraints: import('firebase/firestore').QueryConstraint[] = [];

  if (query.where) {
    for (const [field, value] of Object.entries(query.where)) {
      constraints.push(fs.where(field, '==', value));
    }
  }
  return fs.query(colRef, ...constraints);
};

const snapshotToDocs = (snap: QuerySnapshot, fields?: readonly string[]): Doc[] => {
  return snap.docs.map(d => {
    const data = { id: d.id, ...d.data() } as Doc;
    if (!fields) return data;
    const out: Doc = { id: data.id };
    for (const f of fields) if (f in data) out[f] = data[f];
    return out;
  });
};

// ---------------------------------------------------------------------------
// FirestoreAdapter
// ---------------------------------------------------------------------------

export const FirestoreAdapter = (db: Firestore): Adapter => {
  const subscribe = (query: Query, onChange: OnChangeCallback): Unsubscribe => {
    let unsub: (() => void) | null = null;

    // Async init — snapshot listener starts immediately
    void (async () => {
      const fs = await loadFirestore();
      if (query.id) {
        const ref = fs.doc(db, query.path, query.id) as DocumentReference;
        unsub = fs.onSnapshot(ref, snap => {
          if (!snap.exists()) {
            onChange([]);
            return;
          }
          const data = { id: snap.id, ...snap.data() } as Doc;
          if (query.fields) {
            const out: Doc = { id: data.id };
            for (const f of query.fields) if (f in data) out[f] = data[f];
            onChange([out]);
          } else {
            onChange([data]);
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

  const write = async (operation: WriteOp): Promise<void> => {
    const fs = await loadFirestore();
    const descs: WriteDescriptor[] = Array.isArray(operation) ? operation : [operation];

    // A single descriptor is applied directly; an array is applied atomically
    // inside a Firestore transaction.
    const applyDescriptor = async (descriptor: WriteDescriptor): Promise<void> => {
      const ref = fs.doc(db, descriptor.path, descriptor.id) as DocumentReference;
      if (descriptor.delete) {
        await fs.deleteDoc(ref);
        return;
      }
      const data = translateData(descriptor.fields ?? {}, fs);
      // Default is merge (patch). Only merge: false opts into full replacement.
      if (descriptor.merge !== false) {
        await fs.setDoc(ref, data, { merge: true });
      } else {
        await fs.setDoc(ref, data);
      }
    };

    if (descs.length === 1) {
      await applyDescriptor(descs[0]);
      return;
    }

    await fs.runTransaction(db, async t => {
      for (const desc of descs) {
        const ref = fs.doc(db, desc.path, desc.id) as DocumentReference;
        if (desc.delete) {
          t.delete(ref);
          continue;
        }
        const data = translateData(desc.fields ?? {}, fs);
        // Default is merge (patch). Only merge: false opts into full replacement.
        t.set(ref, data, desc.merge !== false ? { merge: true } : undefined as never);
      }
    });
  };

  return { subscribe, write };
};
