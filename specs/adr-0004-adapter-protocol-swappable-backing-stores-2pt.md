# ADR-0004: Adapter Protocol — Swappable Backing Stores

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

Apps start local and go remote. The moment a backing store is wired directly into
state management, changing it means touching components, queries, and mutates. fiskal-pure
isolates the backing store behind a protocol so the store, components, and mutates are
written once and the adapter is the only thing that changes when the persistence layer
changes.

---

## User-Facing Feature

> "My app starts with in-memory state on day one. When I'm ready for Firestore or CloudKit,
> I change one line in createStore. Every component, query, and mutate works without
> modification."

---

## Decision

### Adapter protocol

```
subscribe(query, onChange: (docs: Doc[]) => void) -> () => void  // returns unsubscribe
write(operation: WriteOperation) async throws -> void
query?(q: Query) async -> Doc[]   // optional: for one-shot reads
```

Adapters are purely reactive on the read side: they deliver documents via `onChange`
callbacks and never return data synchronously from `subscribe`. The cache (ADR-0001)
owns all synchronous reads. Adapters confirm or reject writes asynchronously.

### MemoryAdapter is the default, not a test fake

MemoryAdapter is the adapter used in production at app startup. It is fully functional:
it supports all atomic ops, fires `onChange` callbacks synchronously on write, and
maintains state for the lifetime of the process. It is not a mock or a stub.

Tests run against MemoryAdapter — the same adapter the app uses. There is no separate
"test double" to maintain or diverge from production behavior.

### Available adapters

| Adapter | Platform | Notes |
|---|---|---|
| MemoryAdapter | TS + Swift | Default; in-process; immediate |
| FirestoreAdapter | TS | Real-time subscriptions via Firestore SDK |
| GunAdapter | TS | P2P; offline-first; no server needed |
| CloudKitAdapter | Swift | CKRecord subscriptions; iCloud sync |
| NSUserDefaultsAdapter | Swift | Local persistence; no sync |

### Swapping adapters

```ts
createStore({ ledger: { adapter: new FirestoreAdapter(db), models, mutates } })
```

The adapter name is the only change. No component, query, or mutate is touched.
Different domains within one store can use different adapters simultaneously.

---

## Consequences

- MemoryAdapter as default means the app is fully functional from the first line of
  code — no backend dependency to unblock development.
- Tests are always testing the real adapter path, not a divergent fake, so adapter
  regressions are caught before they ship.
- The protocol is minimal (three methods, one optional) — writing a new adapter is
  straightforward for any persistence layer that supports subscriptions.
- Adapters must interpret atomic op sentinels from ADR-0003; the protocol spec defines
  the required set and the expected behavior for each.
- One-shot reads via `query?` are optional; adapters that omit it force the cache to
  serve all reads from subscription-delivered state.
