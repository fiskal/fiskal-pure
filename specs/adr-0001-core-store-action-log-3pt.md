# ADR-0001: Core Store + Action Log

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 3pt

---

## Context

Every app needs a single source of truth for state. Most solutions expose mutable stores or
reducer pipelines that are opaque to tooling — when something breaks, there is no record of
what happened. fiskal-pure makes the write history the primary artifact: every mutation
produces a serializable log entry so the full sequence of writes that produced any state is
always available.

---

## User-Facing Feature

> "I can replay the exact sequence of writes that produced any app state — on my machine, on a
> server, or in a support ticket — because the store keeps a complete, serializable action log."

---

## Decision

### createStore configuration

TypeScript: `createStore({ [name]: { adapter, models, mutates } })`.
Swift: a result builder that accepts adapter, model, and mutate registrations.
The config object is the only place adapters and mutates are registered — nothing is
global. Multiple stores can coexist without interference.

### In-memory flat normalized cache

The cache is `Map<path, Map<id, Doc>>`. Structural sharing ensures unchanged subtrees
are not copied on every write. All reads and optimistic updates operate against this
cache; the adapter is the async persistence layer beneath it.

### Two-phase write

1. **Synchronous:** apply the write to the cache immediately so the UI re-renders
   optimistically.
2. **Async:** send the write to the adapter (remote or local). On completion, reconcile
   any diff between the optimistic result and the adapter's confirmed state.
   On failure, roll back to the pre-write snapshot stored in the log entry.

### Action log as first-class output

Every write produces a `HistoryEntry`:

```
{ action: string, writes: WriteDescriptor[], snapshot: CacheSnapshot, at: timestamp }
```

The log is append-only. It is fully serializable — no functions, no closures. It can be
shipped to a server, stored to disk, or diffed across sessions. The log is not a debug
tool; it is the complete app history and the foundation for anti-fragile recovery (ADR-0005).

---

## Consequences

- Optimistic UI is free — the synchronous cache update gives instant feedback without
  additional code in components.
- The serializable log enables replay, time-travel debugging, and server-side failure
  analysis at no extra cost to the developer.
- Structural sharing keeps memory overhead low even with large or frequently updated caches.
- Two-phase reconciliation adds complexity to the adapter protocol; adapters must confirm
  writes and surface diffs (see ADR-0004).
