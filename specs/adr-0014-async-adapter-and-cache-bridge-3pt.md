# ADR-0014: Async Adapter Fake and the Authoritative Cache Bridge

**Date:** 2026-06-25
**Status:** Accepted
**Deciders:** Engineering
**Points:** 3pt

---

## Context

Only a synchronous `MemoryAdapter` exists, so async behaviour — first-frame loading and the
optimistic → remote → revert path — is untestable. Worse, the store cache is never fed from
`adapter.subscribe` (F-05): a real async adapter would render stale or empty data, and a
read-then-write mutate computes against only local writes instead of the adapter's truth.

---

## User-Facing Feature

> "I can swap MemoryAdapter for Firestore/CloudKit and my views still show a real loading
> state, then live data, then revert cleanly if a write is rejected."

---

## Decision

### Async fake adapter (implemented)

`AsyncMemoryAdapter` is a test fixture that defers subscribe-delivery and write-notification
to a scheduled tick. It exposes:

- `flush()` — deterministically drain pending ticks.
- `failNextWrite()` and latency controls — exercise rollback and revert paths.
- `subscriberCount()` — subscription-hygiene assertions.

This makes the loading state and the revert-to-source-of-truth path observable in tests
without a network.

### Single authoritative cache bridge (deferred design)

The Store subscribes each adapter on init and feeds `onChange` documents back into the
normalized cache. Both read paths — `useRead` on TS and `wireView` / `@Query` on Swift —
read the cache, never component-local state.

```
adapter.subscribe → onChange(docs) → normalized cache → useRead / @Query → render
```

The adapter is the source of truth; the optimistic write is a projection over it. On a
remote nack the cache is reverted to the adapter's authoritative value and an `errors/` doc
is recorded (ADR-0008). A read-then-write mutate now computes against adapter truth, not
just local writes.

### Conflict policy

Last-write-wins today. Field-level merge is a later, opt-in concern delivered through the
history/merge strategy seam (ADR-0015), not baked in here.

---

## Consequences

- Loading, live-data, and revert paths are deterministically testable via `flush()` — no
  real network, no timers in tests.
- One source of truth: the adapter. Optimistic writes are projections, so stale renders and
  local-only read-then-write bugs are eliminated.
- Swapping `MemoryAdapter` for Firestore/CloudKit requires no view or mutate changes.
- The cache bridge adds a subscription per adapter on init; subscription hygiene is enforced
  by ADR-0017 and asserted via `subscriberCount()`.
