# ADR-0017: Subscription Encapsulation — Leaks Are Structurally Impossible

**Date:** 2026-06-25
**Status:** Accepted
**Deciders:** Engineering
**Points:** 1pt

---

## Context

Subscriptions are the number-one source of leaks in stateful UIs. Any API that lets a
developer call `subscribe`/`unsubscribe` by hand eventually leaks. The library must own the
entire subscription lifecycle so a developer never writes one, and must *prove* it doesn't
leak rather than rely on convention.

---

## User-Facing Feature

> "I never write a subscription or a cleanup. I declare a query in wireView and the library
> owns the entire lifecycle — and proves it doesn't leak."

---

## Decision

### All lifecycle lives inside the connection point

Subscription lifecycle lives entirely inside `wireView` (the Container) and `useRead` on TS,
and inside `QueryWrapper` / `WiredView` on Swift. Pure views never import the library and
never see a subscription — the leak surface is removed at the language level (ADR-0002).

### Invariants enforced by tests, not convention

- Every `subscribe` returns an idempotent `unsubscribe`.
- Re-subscribe happens only when the query key changes (F-18).
- Swift subscriptions are structured children of `.task`, so cancellation is automatic
  (F-17).
- Active subscriber count returns to steady state (exactly zero) after N attach/detach
  cycles, and never exceeds one per logical consumer.
- A write to an unrelated path never wakes a scoped subscriber.

### Dev-only introspection

A dev-only `subscriberCount()` introspection backs these assertions, exercised with the
`AsyncMemoryAdapter` (ADR-0014) so attach/detach cycling is deterministic.

---

## Consequences

- Developers cannot leak a subscription because they cannot create one — the API surface for
  manual `subscribe`/`unsubscribe` does not exist.
- Steady-state zero and "one subscriber per consumer" are asserted in tests every build, not
  hoped for in review.
- Scoped queries don't wake on unrelated writes, keeping render churn bounded.
- `subscriberCount()` is dev-only introspection; it is not part of the shipping public API.
