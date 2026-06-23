# ADR-0002: wireView — The Only Connection Point

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

The most common source of complexity in stateful UIs is components that directly import and
call the store. This couples business logic to rendering, makes components impossible to test
in isolation, and creates a "smart vs dumb" distinction that must be managed by convention.
fiskal-pure eliminates the distinction structurally: no store API is accessible inside a
component file because no component ever imports the library.

---

## User-Facing Feature

> "My components are plain functions. I test them by passing props directly — no providers,
> no mocks, no store setup. Wiring to live data happens in one external call that I can read
> in isolation."

---

## Decision

### wireView signature

TypeScript:

```ts
wireView(name, queryFn | queryObj, actions, Component) → WiredComponent
```

Swift:

```swift
wireView(name:, queries:, actions:, view:) → some View
```

`wireView` is called in a dedicated wiring file, never inside the component file itself.
It returns a new component (or view) that injects live query results and bound action
functions as props — the original component is not modified.

### Structural impossibility of store coupling

Because no component file imports the library, there is no store API available inside a
component at the language level. This is not a lint rule or a convention — it is a
structural guarantee enforced by the import graph.

### Multiple wirings from one component

The same component can be passed to `wireView` multiple times with different queries and
different action bindings. This covers cases like a shared `ListItem` rendered in both a
"recent" and "pinned" context with different data sources.

### Testing

```tsx
render(<Component items={mockItems} onSelect={mockFn} />)
```

No `Provider`, no store instance, no context. The component is a pure function of its
props. The wired version is integration-tested separately against the real store with a
MemoryAdapter (ADR-0004).

---

## Consequences

- Every component in the codebase is unconditionally testable with plain props — no
  exceptions, no "dumb component" variants to maintain.
- Wiring is discoverable: every data dependency for a screen lives in one file that
  imports `wireView`, not scattered across hooks inside the component.
- The same component can power multiple screens or contexts without modification.
- Developers must learn to find wiring files separately from component files; clear
  folder conventions (`<Feature>.wired.tsx`) mitigate this.
