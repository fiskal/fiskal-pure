# ADR-0015: Pluggable History — Snapshot or CRDT Strategy

**Date:** 2026-06-25
**Status:** Accepted
**Deciders:** Engineering
**Points:** 3pt

---

## Context

The headline promise is "every write is logged for replay" with time-travel (F-14). The
substrate for that promise is a choice with opposite trade-offs: single-writer immutable
snapshots are cheap and deterministic; multi-writer CRDTs converge across devices but carry
heavier metadata and weaker deterministic positioning. The library should not force one.

---

## User-Facing Feature

> "Time-travel and undo work out of the box; when I genuinely need multi-device merge I opt
> into a CRDT strategy without changing my views or mutates."

---

## Decision

### One stable public API behind a Strategy seam

A History/merge **Strategy** sits behind the Store with one stable public surface:

```
back()  forward()  goto(n)  log()
```

Views and mutates call only this API. Swapping the substrate never touches them.

### Snapshot strategy (default)

Immutable cache values with structural sharing. Each write captures a cheap snapshot
pointer; `goto(n)` is an O(1) pointer swap. Deterministic, pairs naturally with the
optimistic + rollback path (ADR-0014), and resolves conflicts last-write-wins.

### CRDT strategy (opt-in)

An Automerge/Yjs/Gun-style substrate where the op-log *is* the history and CRDT convergence
*is* the field-level merge. Chosen for true multi-writer / offline-collaborative cases. It
trades heavier metadata and weaker deterministic `goto` for cross-device convergence.

### Serialisable prerequisite

Both strategies require ADR-0016's closed `Value` model so snapshots and ops are
serialisable across platforms and across a restart.

---

## Consequences

- Time-travel, undo, and replay ship by default via the snapshot strategy.
- Multi-device merge is available without rewriting views or mutates — opt in by selecting
  the CRDT strategy.
- The default stays deterministic and cheap; collaborative complexity is paid for only when
  genuinely needed.
- Depends on ADR-0016: a non-serialisable `Value` would break snapshot persistence and CRDT
  op transport alike.
