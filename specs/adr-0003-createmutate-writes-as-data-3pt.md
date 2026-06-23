# ADR-0003: createMutate — Writes as Data

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 3pt

---

## Context

When state changes are expressed as function calls, they are opaque to the action log —
the log can record that a function ran but cannot describe what it did. fiskal-pure
requires every write to be a named, serializable descriptor so the log contains not just
the fact of a write but its full content: what path, what operation, what values. This
makes the log replayable and the write history testable without touching a backing store.

---

## User-Facing Feature

> "I describe what I want to write as data. The library executes it, logs it, and rolls it
> back if it fails — and I can test the descriptor itself with a plain function call, no
> store required."

---

## Decision

### Three mutate forms

1. **Write-only** — produces `WriteDescriptor[]` from payload, no reads needed.
2. **Read-then-write** — reads current cache state, derives `WriteDescriptor[]` from the
   combination of payload and current state.
3. **Transaction** — an array of write-only or read-then-write descriptors executed
   atomically. The adapter either commits all or none.

### Execution flow

```
createMutate(payload)
  → resolveWrites(mutate, payload) → [WriteDescriptor]
  → sync cache update (optimistic re-render)
  → async adapter.write(operation)
  → on success: reconcile diff
  → on failure: rollback to pre-write snapshot; mark log entry failed
```

The synchronous cache update and the async write are always paired. The developer
calls `store.mutate.myAction(payload)` and optionally awaits the Promise.

### Atomic operations

Writes support server-side atomic ops as first-class values in the descriptor:

```
::delete  ::serverTimestamp  ::increment(n)  ::arrayUnion(v)  ::arrayRemove(v)
```

These are serialized into the descriptor and interpreted by the adapter, so they work
across MemoryAdapter, FirestoreAdapter, and CloudKitAdapter without branching.

### Testing without a store

```ts
const writes = resolveWrites(myMutate, { amount: 42 })
expect(writes).toEqual([{ path: 'budgets/abc', op: 'set', data: { amount: 42 } }])
```

`resolveWrites` is a pure function — no store, no adapter, no async. Tests for write
logic are hermetic and run in parallel.

---

## Consequences

- The action log is fully serializable because every write is a descriptor, never a closure.
- Optimistic updates and rollback are automatic — no developer-authored undo logic needed.
- `resolveWrites` makes write logic independently testable: no store setup, no fakes.
- Atomic ops require all adapters to interpret the same sentinel values; adapter authors
  must handle each op or throw a clear unsupported error (see ADR-0004).
- Read-then-write mutates must be designed carefully to avoid stale reads under
  concurrent writes; the transaction form is preferred when ordering matters.
