# ADR-0016: Cross-Platform Contract in Lockstep

**Date:** 2026-06-25
**Status:** Accepted
**Deciders:** Engineering
**Points:** 3pt

---

## Context

The logged write and the query *are* the cross-platform contract, but they have drifted.
Swift `Write` lacks `merge:false`/`delete` and uses single-element array ops, so "add 3
tags" is one descriptor on TS but three on Swift (F-10). `[String:Any]` is unsound
`Sendable`, increment resets on int/float mismatch, `serverTimestamp` is stored as three
runtime types, and non-JSON writes are silently dropped (F-13). Swift `Query.where` is
structured clauses with 9 operators plus `orderBy`, while TS is equality-only with no
ordering — and Swift adapters ignore the operator anyway (F-20).

---

## User-Facing Feature

> "A bug captured from a web user's write log replays identically on the Watch app, because
> the write and query are the same on both."

---

## Decision

### Canonical Write

`{ path, id, fields, merge (default true), delete }`, mirrored byte-for-byte on both
platforms. Array ops are variadic, so "add 3 tags" is one descriptor everywhere.

### Canonical Value

A closed enum replaces `[String:Any]` and loose `any`:

```
Value = string | number | bool | date | array | map | null
```

It is `Sendable` and serialisable. This fixes increment-reset (one numeric type),
timestamp divergence (one `date` case), and the silent JSON-drop (no unrepresentable write).

### Canonical Query

Structured `where` clauses sharing one operator set, plus `orderBy` and `limit` / cursor.
A single query-evaluation function is shared across all adapters, so no adapter can ignore
an operator.

### Replay parity

The same user action produces an identical descriptor on both platforms. This is the
prerequisite for rewriting the firestore/gun adapters and for serialisable history
(ADR-0015).

---

## Consequences

- A write log captured on web replays identically on Apple — true cross-platform replay.
- `Value` being closed and `Sendable` removes a whole class of type-mismatch and
  concurrency hazards (increment reset, timestamp drift, dropped writes).
- One shared query evaluator means every adapter honours every operator, `orderBy`, and
  pagination — no per-adapter divergence.
- Existing Swift `Write` and `Query` call sites change shape (variadic ops, structured
  clauses); a one-time migration is required and unblocks ADR-0014 and ADR-0015.
