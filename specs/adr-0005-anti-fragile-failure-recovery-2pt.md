# ADR-0005: Anti-Fragile Failure Recovery

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

Traditional error handling makes failures observable after the fact — a stack trace, a log
line, a user report. fiskal-pure's action log makes failures fully reproducible: the exact
sequence of writes that produced any broken state is already serialized and shippable.
This changes the failure model from "observe and hope to reproduce" to "receive the exact
sequence, analyze, fix, and guarantee the same failure never reaches a user again."

---

## User-Facing Feature

> "When something breaks, the app ships the full write history to a server automatically.
> I replay the exact sequence that caused the failure — no repro steps, no guessing.
> Once I fix it, that failure path is closed forever."

---

## Decision

### Failure detection and log shipment

On any unhandled error or write failure, the store serializes the current action log and
the pre-failure cache snapshot and ships them to a configured error endpoint. The payload
is the same `HistoryEntry[]` structure used internally — no transformation, no lossy
summarization. The server receives the exact write sequence.

### Time-travel recovery

```ts
store.history.back()           // restore previous snapshot
store.history.goto(index)      // restore any snapshot in the log
```

Each `HistoryEntry` carries a full `CacheSnapshot` (structural sharing keeps this O(1)
storage per entry). Restoring a snapshot replaces the live cache with the stored value
and re-renders all subscribed components. This is the "auto-heal" path: detect a known
failure state → restore the last known-good snapshot from the log.

### Anti-fragile property

A system is anti-fragile when it improves from stress. The action log enforces this:

```
Failure occurs
  → log shipped to server (zero developer action needed)
  → developer replays exact sequence
  → fix applied and deployed
  → same failure state is now impossible to reach
```

The failure surface shrinks with each incident rather than remaining constant.

### What the server receives

```json
{
  "log": [
    { "action": "budget/setAmount", "writes": [...], "snapshot": {...}, "at": 1750000000000 }
  ],
  "failedAt": 3,
  "error": "Invariant violated: amount < 0"
}
```

`failedAt` is the index into `log` where execution failed, so the server knows exactly
which write triggered the error without scanning the full log.

---

## Consequences

- Failure recovery is built into the core data model — no additional instrumentation,
  no third-party error SDK required for the replay capability.
- The structural sharing in `CacheSnapshot` (ADR-0001) makes storing a snapshot per
  write entry practical; without it, log storage would be prohibitive.
- Auto-heal requires the app to ship a new build before the log analysis is complete;
  the `store.history.goto` path restores state for the current session only.
- Shipping the action log to a server means the log must never contain secrets
  (passwords, tokens). Sensitive fields must be redacted in `createMutate` before
  they enter a `WriteDescriptor`.
- The anti-fragile property only holds if the server endpoint is monitored; a silent
  endpoint that drops logs is worse than no shipment at all.
