# ADR-0006: LocalStorage Adapter

**Date:** 2026-06-23
**Status:** Proposed
**Deciders:** Engineering
**Points:** 2pt

---

## Context

MemoryAdapter resets on every page reload — any locally created or modified data is lost.
For web apps that cannot assume a backend connection, a persistence layer that survives
refresh is needed without the complexity of IndexedDB or a remote adapter.

> "I opened the app on a plane, added three tasks, closed the tab, and they were all gone."

---

## User-Facing Feature

> "My tasks are still there when I come back to the tab — even if I closed the browser
> or lost internet. No account required."

---

## Decision

### Adapter shape

`LocalStorageAdapter` implements the same `Adapter` protocol as `MemoryAdapter` — same
`subscribe` + `write` interface. No changes to components, queries, or mutates. Swap in
one line in `createStore`.

```ts
import { LocalStorageAdapter } from '@fiskal/antifragile/adapters/localstorage'

const store = createStore(LocalStorageAdapter({ namespace: 'fiskal-app', version: 1 }))
```

### Storage layout

Each collection is serialised as a single JSON entry under a namespaced key:

```
fiskal-app:v1:tasks    →  { "task-1": { id, title, status, createdAt }, ... }
fiskal-app:v1:ui/modal →  { "active": { type, taskId } }
```

`namespace` prevents key collisions between apps sharing the same origin.
`version` is included so a schema migration can target and drop stale keys.

### Write path

1. Apply the write to the in-memory cache (same as MemoryAdapter).
2. Serialise the affected collection to JSON.
3. Call `localStorage.setItem(key, json)` synchronously.
4. Notify collection subscribers.

Writes are synchronous. `localStorage.setItem` is a blocking call — acceptable for
document-sized payloads (< 5 MB total). For larger data sets, IndexedDB is the right
tool (a separate future ADR).

### Read / hydration

On construction, read all keys matching `namespace:vN:*` and populate the in-memory
cache. Hydration is synchronous — the first `useState` read in wireView will have data
immediately with no loading flash (same guarantee as MemoryAdapter with seed data).

### Atomic ops

`{ __op: '::increment', n }` is resolved against the in-memory value before writing.
LocalStorage has no native atomic ops — but since all writes go through the in-process
store first, the in-memory value is always authoritative. The persisted value is the
serialised output, not the input.

### `ui/` paths

`ui/` collection writes reach `LocalStorageAdapter` only if the store config maps them
there. The same path-prefix routing as with MemoryAdapter applies. Default: route `ui/`
to a separate MemoryAdapter (reset on reload) and domain data to LocalStorageAdapter.

```ts
const store = createStore({
  default: { adapter: LocalStorageAdapter({ namespace: 'fiskal-app', version: 1 }) },
  ui:      { adapter: MemoryAdapter(), paths: ['ui/'] },
})
```

### Migration

When `version` bumps, the adapter reads the old versioned keys, runs the model's
`versioning.rollforward` functions against each document, writes the results under the
new versioned keys, and deletes the old keys.

---

## Consequences

- Survives page reload with zero backend dependency.
- 5 MB browser quota — suitable for task lists, settings, drafts; not for large media.
- Same-origin only — no sync between devices or browsers.
- SSR environments (Next.js server render) must guard against `window.localStorage` being
  undefined; the adapter should no-op on write and return empty on read in that context.
- No conflict resolution — single writer (the tab). For multi-tab writes, a `storage`
  event listener can notify the in-memory cache of external changes; this is a follow-on
  concern.
