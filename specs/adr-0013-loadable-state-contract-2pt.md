# ADR-0013: Loadable — The Canonical Three-State Read Model

**Date:** 2026-06-25
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

TypeScript encodes the three read states as `undefined` (loading), `null` (not-found), and
`Doc` (loaded). Swift has no `undefined`, so `QueryWrapper` collapses to `T?` and cannot
distinguish "still loading" from "loaded but missing". The same three states are modelled
inconsistently across platforms (F-09), so a view that branches on loading behaves
differently on web and on Apple.

---

## User-Facing Feature

> "Loading, missing, and empty are three different things and my view can tell them apart —
> the same way on web and on Apple."

---

## Decision

### Loadable is the canonical read model

`Loadable<T>` is the explicit three-state read model on both platforms. A single-document
query carries all three states; a collection query carries only two — `.loaded([])` is
loaded-but-empty and is never `.missing`.

Swift:

```swift
enum Loadable<T> { case loading; case missing; case loaded(T) }
```

TypeScript:

```ts
type Loadable<T> =
  | { status: 'loading' } | { status: 'missing' } | { status: 'loaded'; data: T }
```

### The prop encoding stays zero-ceremony

The default prop encoding remains `undefined | null | T` — this is documented as the
canonical *encoding* of `Loadable`: `undefined` = loading, `null` = missing, value =
loaded. Pure views keep branching on plain values with no library import and no ceremony.

### Explicit tagged form on demand

A `useReadLoadable` hook and a pure `toLoadable()` converter expose the tagged union for
views and tests that need to branch explicitly. `toLoadable(undefined) → { status:'loading' }`,
`toLoadable(null) → { status:'missing' }`. The converter is pure, so it is trivially testable.

### Additive and backward compatible

Existing views and tests are unchanged. The encoding they already rely on is now named, and
the tagged form is offered alongside it — nothing is rewritten.

---

## Consequences

- A view can render a spinner, an empty state, and a not-found state distinctly — on both
  platforms, with identical semantics.
- Collection queries can never report `.missing`, removing a class of "is `[]` an error?"
  ambiguity.
- Zero-ceremony pure views keep the `undefined | null | T` prop encoding; nothing migrates.
- One more named concept to learn, mitigated by the encoding being the same values
  developers already pass through props.
