# Gaps, Holes, and Hard Limits

A critical analysis of fiskal-antifragile: what it doesn't handle, where it will break,
and how it compares to the state management systems it is meant to replace.

Organised by severity: implementation gaps first (design is right, code is behind),
then architectural holes, then honest comparison with alternatives.

---

## Corrections from PRINCIPLES.md

Several gaps identified in the initial analysis are design-correct but unimplemented:

- **`models` field in `createStore`** — PRINCIPLES.md specifies `models: { tasks: TaskModel }` per backing store. The design is complete. Implementation is missing. → ADR-0007.
- **Multiple backing stores** — `createStore` accepts named backing stores (default, keychain, defaults), each with its own adapter, models, and mutates. Document routing is by path prefix. Not yet implemented.
- **`createMutate` `read` field** — PRINCIPLES.md shows mutates can read from the store before writing (`read + write` pattern). This makes dependent writes first-class. Not yet implemented.
- **`@Observable` under the covers** — The Swift library uses `@Observable` internally. The per-property re-render granularity is an implementation detail, not a gap. The library inherits it.
- **Errors** — Identified as a missing fourth state. Correct design is a root-level `errors` collection, not a per-query state. Any component subscribes to the errors it cares about. → ADR-0008.

---

## Part 1 — Implementation gaps (design correct, code behind)

### 1a. Model compute is never applied — getters and computers don't reach the component

The current `createStore` ignores the `models` field. wireView delivers raw `Doc` objects
from the adapter with no compute applied. `task.createdAtDisplay` is `undefined`.

**Fix:** `createStore` registers models per collection (ADR-0007). When the cache delivers
a document, it enriches it via `Object.defineProperties` with the model's compute
descriptors. Getters stay live — not called at assignment time. Methods land on the
document and must be called as `task.isAssignedTo(user)`, not destructured.

---

### 1b. Computer functions lose `this` when destructured

The docs show:

```ts
const TaskItem = ({ task, sprint, completionPercent }) => (
  <span>{completionPercent(sprint)}%</span>
)
```

When wireView injects `completionPercent` as a separate prop (not as a method on `task`),
the function loses its `this` binding. In strict mode, `this` is `undefined`. The method
reads `this.completedItems` → `TypeError`.

Computers must be called as methods on the document, not as standalone props:

```ts
// WRONG — this binding is lost
const { completionPercent } = task
completionPercent(sprint)  // this === undefined

// CORRECT — this === task
task.completionPercent(sprint)
```

**Fix for the docs and the agent:** Remove all destructured computer examples. The
component receives `task` and `sprint` as props and calls `task.completionPercent(sprint)`.
The computer is a method on the enriched document, not an injected action.

**Fix for wireView:** Do not inject compute functions as separate props. They travel on
the document object after enrichment (fix 1a). Components call them as methods.

---

### 1c. Errors need a home — the `errors` collection

Correct design (ADR-0008): errors are documents in the store's `errors` collection.
When a write fails, the store writes `{ action, kind, message, payload, writes, at }` to
`errors/{action}-{timestamp}`. Any component subscribes to the subset of errors it cares
about using the standard query system. No fourth state in wireView's contract — data
queries and error queries are independent subscriptions.

The three-state contract (`undefined` / `null` / `Doc`) stays unchanged. The distinction
between "not found" and "permission denied" comes from the error document's `kind` field,
not from the data query's return type.

**Not yet implemented.** → ADR-0008.

### 1d. `createMutate` is missing the `read` step

PRINCIPLES.md shows two mutate forms beyond simple write:

```ts
// read-then-write — reads from the store before writing
const completeTask = createMutate({
  action: 'CompleteTask',
  read:  ({ taskId, sprintId }) => ({
    task:   { id: taskId },
    sprint: { id: sprintId },
  }),
  write: ({ task, sprint }) => ({
    id: task.id, fields: { status: 'done', sprintScore: sprint.pointsPerTask },
  }),
})
```

The `read` step runs against the current cache synchronously before the write function.
The write function receives the read results as its argument.

This matters for time travel: the history entry must store both the `reads` (what was
fetched at write time) and the `writes` (the resulting descriptors). Replaying history
from state 0 re-applies the stored `writes` in order — the `reads` are stored for
debugging, not for replay. Write descriptors are always the replay unit.

**Not yet implemented.** The current `createMutate` only supports the `write` form.

---

## Part 2 — Eventual consistency holes

### 2a. Same-field concurrent edits silently lose one write

The library uses last-write-wins for same-field conflicts. Client A sets `title = "Deploy v2"`;
client B sets `title = "Deploy v3"`. Both use `merge: true`. One silently overwrites the
other. The losing client's subscribe stream fires with the winning value — correct — but
the user has no indication their write was overridden.

**What the library provides:** The adapter's subscribe stream delivers the winning value.
The history log shows both writes.

**What the library does not provide:** A "write was overridden" event, a conflict UI hook,
or CRDT semantics for text fields. GunJS (mentioned as an adapter) provides CRDT merging
at the gun/sea layer, but the library itself has no CRDT primitives.

**Acceptable trade-off for most apps.** Only a concern for collaborative text editing.
For task titles, budget amounts, and most user-facing fields, last-write-wins is correct
behaviour — the user who wrote last intended to win.

---

### 2b. Time travel is in-memory only — the server will overwrite it

`store.history.back()` and `store.history.goto(n)` restore the in-memory cache.
They do not send compensating writes to the server. The moment the adapter syncs,
the server's current state overwrites the rolled-back cache.

This means:
- Time travel works correctly as an **undo UI gesture** while offline
- Time travel does **not** work as a persistent undo after sync

**For persistent undo:** implement an explicit compensating write. If `archiveTask` is
the action, the undo is `unarchiveTask`. The history log gives you the payload to reverse.

```ts
const lastEntry = store.history.log().at(-1)
if (lastEntry?.action === 'ArchiveTask') {
  await unarchiveTask({ id: lastEntry.writes[0].id })
}
```

The library's time travel is for debugging and wizard-cancel patterns. It is not a
general-purpose undo system for synced data. This is not documented clearly.

---

### 2c. Offline queue: write timestamps vs server timestamps

If the user is offline and writes at local time T1, then goes online and the server
applies the write at time T2 (after another client's write at T2 - 1), the server may
treat the offline write as the most recent depending on how the adapter handles timestamps.

For Firestore: `FieldValue.serverTimestamp()` in the adapter resolves correctly — the
server assigns the timestamp at commit time, so late-arriving offline writes are always
stamped with their actual commit time. No issue.

For MemoryAdapter, CloudKitAdapter, and custom adapters: depends on implementation.
An adapter that uses `Date.now()` from the client at write time will assign T1, which
may be earlier than another client's T2 but arrive later — causing an incorrect causal
ordering.

**Guidance for adapter authors:** never use client timestamps for ordering. Use server
timestamps for all ordering-sensitive fields. The library should document this as a
contract on the Adapter protocol.

---

### 2d. Two-tab divergence with LocalStorageAdapter

Two browser tabs share `localStorage` but have separate in-memory caches. A write in
tab A updates tab A's cache and writes to `localStorage`. Tab B sees neither — its cache
is stale and it has no `storage` event listener.

The LocalStorageAdapter ADR mentions this as a "follow-on concern". It must be a
requirement, not optional. Without it, multi-tab use of the app produces inconsistent UI.

**Fix:** `LocalStorageAdapter` must listen to the `window.storage` event and update the
in-memory cache when another tab writes:

```ts
window.addEventListener('storage', (e) => {
  if (e.key?.startsWith(`${namespace}:v${version}:`)) {
    const collection = e.key.replace(`${namespace}:v${version}:`, '')
    const docs = JSON.parse(e.newValue ?? '{}')
    hydrate(collection, docs)
    notify(collection)
  }
})
```

Without this, `LocalStorageAdapter` is broken for any app where users might have
multiple tabs open — which is nearly every web app.

---

### 2e. No causality tracking between writes

The history log records `at: number` (timestamp) but no vector clock or happened-before
relationship. If write B causally depends on write A (B was made in response to reading
A's result), the log doesn't capture this relationship.

This matters for debugging: you may not be able to reconstruct the causal chain from the
log alone. And for conflict resolution: the adapter can't distinguish "write made with
knowledge of the current server state" from "write made with stale knowledge".

**Acceptable for most apps.** Causality tracking is only critical for distributed
systems with complex merges. Documented as a known limitation.

---

## Part 3 — Missing features (future ADRs)

### 3a. `limit` and cursor in QuerySpec — required for large collections

The current `QuerySpec` has no `limit`, `cursor`, `startAfter`, or `endBefore` fields.
Without them, a collection query returns all documents. For a collection of 10,000 tasks,
"query all tasks and slice in the component" is not viable.

```ts
// Needed in QuerySpec:
type QuerySpec = {
  collection?: string
  id?: string
  where?: Record<string, unknown>
  orderBy?: Record<string, 'asc' | 'desc'>
  fields?: string[]
  limit?: number          // ← missing
  cursor?: string         // ← missing — the id of the last-seen document
}
```

The cursor must be a document id (full path), not an offset number. Offset pagination
is incompatible with concurrent writes.

**Priority: high.** Any production app with user-generated content hits this.

---

### 3b. Reactive/dependent queries — query A result feeds query B's where clause

"Give me all tasks belonging to the active sprint."

The active sprint id is itself a query result. Currently there's no way to express:

```
step 1: query { id: 'ui/session/activeSprint' } → { sprintId: 'sprints/sprint-A' }
step 2: query { collection: 'tasks', where: { sprintId: 'sprints/sprint-A' } }
```

as a single wireView declaration. The developer must either:
a. Wire two separate components and pass `sprintId` as a prop down to the second
b. Know the active sprint id at call time (e.g., from a parent prop)

Neither is clean for deeply computed queries. A reactive query system where one
query's result can feed another's spec would eliminate this pattern entirely.

**Priority: medium.** Workable with prop threading but awkward.

---

### 3c. DevTools — no store inspector

Redux DevTools is the gold standard: a browser extension that shows the full state tree,
every dispatched action, time-travel replay, and diff view between states. No equivalent
exists for this library.

The history log (`store.history.log()`) provides the raw data, but there's no:
- Live view of the current cache
- Visual diff between snapshots
- Replay of the write sequence
- Query subscription map (which component is subscribed to what)

**What the library has:** `store.history.log()` as a serializable array. This can be
shipped to a server on error. It is not a substitute for live DevTools.

**Priority: medium.** The action log + serializable writes is better than Redux for
post-mortem debugging. Live inspection is the gap.

---

### 3d. PII redaction in the history log

`store.history.log()` contains the full `fields` payload of every write. If a write
contains a user's password, API key, or other sensitive field, it's in the log.

The library should support path-level redaction:

```ts
createStore({
  adapter: ...,
  log: { redact: ['password', 'apiKey', 'ssn'] }  // fields to strip from log payloads
})
```

Without this, shipping the log to a server on error is a PII liability.

**Priority: high before any production use.**

---

### 3e. Persistent vs session-scoped `ui/` state

`store.clear('ui/')` on logout destroys all `ui/` state. But some UI state should
survive logout — the user's preferred sort order, display density, theme, sidebar width.
These are user preferences, not session state.

Currently there's no way to mark some `ui/` paths as persistent. Options:

```ts
// Option A: a separate path prefix
'prefs/sortOrder'    // persisted, user-scoped
'ui/modal/active'    // session-scoped, cleared on logout

// Option B: the ui/ adapter config has a `persistent` flag per sub-path
ui: {
  adapter: MemoryAdapter(),
  paths: ['ui/'],
  persistent: ['ui/prefs/'],  // backed by localStorage, not cleared on logout
}
```

**Priority: medium.** Most apps eventually need this; easy to add a separate `prefs/`
collection with LocalStorageAdapter.

---

### 3f. Registry name collisions in large apps

The wireView registry is global per factory instance. `wireView('Modal', ...)` registers
`Modal`. Any wired component with a prop named `Modal` automatically receives the
`WiredModal` component injected.

In a large app with dozens of wired components:
- `WiredCard` registered for a task card
- `WiredFeatureCard` registered for a marketing card
- A component has a `Card` prop for layout
- It receives `WiredCard` injected, which is not what was intended

**Fix:** Enforce a naming convention in the agent and docs. The registered name must
match the semantic role precisely. Consider namespaced names: `'task:Card'` vs
`'feature:Card'`. The wireView factory could support a `namespace` option.

**Priority: low** for small apps. High for monorepos with shared component registries.

---

### 3g. Code-splitting load order for the registry

When React code-splits a bundle, wired components are imported lazily. If `WiredTaskItem`
is in a chunk that loads after `WiredTaskList`, `TaskList` renders with the `TaskItem`
prop as `undefined` until the `WiredTaskItem` chunk arrives.

The registry is populated at import time. Late-loading components aren't in the registry
when the parent first renders.

**Fix options:**
a. Ensure wired components are always in the same chunk as the parents that need them
b. The registry supports a lazy-register API and the wired parent re-renders when a
   dependency registers

**Priority: medium** for any app using React.lazy or route-based splitting.

---

## Part 4 — AI agent footguns

These are patterns where an AI agent will confidently generate incorrect code.

### 4a. Path-based IDs — agents default to `{ collection, id }` form

The convention `{ id: 'tasks/task-1' }` is non-obvious. Every AI trained on Redux,
Firestore, or general React patterns will write `{ collection: 'tasks', id: 'task-1' }`.
Both work (the store accepts both), but seed data must use path-based IDs, and `setModal`
only works cleanly if ids carry the collection.

**Mitigation:** The `antifragile-engineer` agent instructions must show path-based IDs
in every example and explicitly state the convention.

---

### 4b. Computers as method calls — agents will destructure them

Given:
```ts
const TaskItem = ({ task, sprint }) => ...
```

An AI agent told to "display the completion percent" will likely write:
```ts
const { completionPercent } = task
return <span>{completionPercent(sprint)}%</span>
```

This silently fails (`this` is `undefined`). No error at definition time.

**Correct pattern:**
```ts
return <span>{task.completionPercent(sprint)}%</span>
```

**Mitigation:** The agent instructions must explicitly say: computers are called as
methods on the document object, never destructured.

---

### 4c. Adding `useEffect` / `useState` to components

An AI agent implementing "load more" or "auto-save" will reach for `useEffect` inside
the component. This breaks the zero-library-import rule and mixes concerns.

The rule is structural (components don't import the library) but not compile-enforced.
An AI can write `useEffect` from React (which IS allowed as an import) even if the
useEffect is doing data work that should be in a mutate.

**Mitigation:** The agent rules must say: if the useEffect interacts with data, it belongs
in a new `createMutate` or in a wired action, not in the component.

---

### 4d. Creating a second `createStore` for a new feature

Faced with "add a notifications feature", an AI agent might create:
```ts
// notifications/store.ts
export const notificationsStore = createStore(MemoryAdapter())
export const wireView = createWireView(notificationsStore, { ... })
```

This creates a second store instance, a separate subscription chain, and no history
cross-referencing between the two. Queries from one store's wireView can't access
documents in the other's cache.

**Rule:** One store per app. Add new collections to the existing store. New adapters
(if the new feature uses a different backend) are handled via the store config's
per-path adapter routing.

---

### 4e. The two-component modal pattern — agents try to collapse it into one

The modal requires `WiredModalShell` (reads the stored query descriptor) and
`WiredModalDetail` (uses that descriptor as its live query). An AI agent will try:

```ts
// Agent writes this — doesn't work:
wireView('Modal',
  { modal: { id: 'ui/modal/active' }, item: ??? }  // can't use modal.id as the item query
  ...
)
```

The two-step is necessary because a wireView's query is resolved once from `ownProps`.
The result of one query cannot feed into another query in the same wireView.

**Mitigation:** Document the two-component pattern explicitly in the agent instructions
with the exact code template.

---

### 4f. Seed data with local IDs

An agent writing seed data for MemoryAdapter will write:
```ts
MemoryAdapter({ tasks: [{ id: 'task-1', title: '...' }] })
```

The id `'task-1'` has no collection prefix. When a query `{ id: 'tasks/task-1' }` runs,
the store splits the id to `collection: 'tasks', localId: 'task-1'`. If the stored document
was keyed as `'task-1'` (not `'tasks/task-1'`), the query returns null.

**Rule:** All document ids in seed data and writes must use full path format.

---

### 4g. `merge: false` on documents that have server-added fields

An agent writing an "update task" mutate might write:
```ts
write: ({ id, title, status, createdAt }) => ({
  id, fields: { title, status, createdAt }, merge: false,
})
```

If the server adds `completedAt`, `assignee`, or `updatedBy` to the document,
a `merge: false` write from the client strips them.

**Rule:** Only use `merge: false` when creating a brand-new document. Always use
`merge: true` for updates.

---

### 4h. Implicit registry injection — agents don't understand it

When `wireView('TaskItem', ...)` is called, `WiredTaskItem` is registered as `'TaskItem'`.
Any other wired component that has a prop named `TaskItem` automatically receives it.

An agent writing a new wired component with a prop called `TaskItem` (for a different
purpose — say, a template or a type label) will receive the registered `WiredTaskItem`
injected, silently breaking its intended behaviour. The agent won't understand why the
prop has an unexpected value.

**Mitigation:** Document the injection mechanism explicitly. Convention: prop names
that receive injected components start with an uppercase letter and match a registered
wireView name exactly. All other props use camelCase.

---

## Part 5 — Architectural limits (intentional, but important to know)

### 5a. Single store — no multi-tenant, no per-tab isolation

One store per app. If a tab-based UI needs independent state per tab, or a multi-tenant
app needs isolated data per tenant, there is no built-in mechanism. Multiple store
instances work but the wireView factories can't cross-inject across stores.

**Scope:** Acceptable for single-user, single-session apps. Needs a rethink for
collaborative multi-tab or multi-tenant scenarios.

---

### 5b. No middleware ecosystem

Redux-saga, redux-observable, redux-thunk — none have equivalents here. Reactions to
writes (e.g., "when a task is archived, notify the sprint") must happen in:
a. The mutate's write array (multi-write transaction)
b. The server (cloud function, trigger)
c. A separate mutate called explicitly after the first

There is no "listen to write X, fire write Y automatically" mechanism in the library.
Side effects are at the boundary only, not chained through middleware.

This is intentional (FP principle: side effects at edges). But it means some patterns
natural in Redux are more explicit here.

---

### 5c. Schema validation is declared but not enforced at write time

`Model.schema` (JSON Schema) is defined but no validation runs at `createMutate` write
time. An agent or developer can write `{ title: 42 }` (wrong type) and the library
accepts it silently.

The CLAUDE.md says "validate every payload where it crosses a memory boundary" — but
the implementation doesn't. Schema validation needs to be a step inside `createMutate`
before the write reaches the adapter.

**Priority: high before production.**

---

### 5d. `merge: true` can hide bugs

`merge: true` is the safe default for multi-client apps. But it means a write that
accidentally omits a required field silently succeeds — the old value stays in place.
Bugs where a field should have been cleared (set to `null`) but was omitted from the
write are invisible.

**Mitigation:** Schema validation (5c) catches this — a write that omits a required
field is a validation error.

---

### 5e. The `wireView` factory is not type-safe on query results

`wireView` delivers data as `Doc | Doc[] | null`. The component receives untyped props.
TypeScript can infer prop types from the component signature, but the bridge between
"this query returns a `Task`" and "this prop is a `Task`" is not type-enforced. An agent
can write a query for `tasks` and receive the result as a `Sprint` in the component type
without a compile error.

**Fix:** A typed version of wireView where the query map is associated with a model type:

```ts
wireView('TaskItem',
  ({ taskId }) => ({ task: typed<Task>({ id: taskId }) }),
  ...
)
```

This is a TypeScript-level concern. It doesn't affect runtime correctness but it means
type safety depends on the developer writing correct types, not the compiler enforcing them.

---

## Part 6 — Comparison to other state management systems

### React ecosystem

| Dimension | Redux / RTK | Zustand | Jotai | TanStack Query | fiskal-antifragile |
|---|---|---|---|---|---|
| Subscription granularity | selector-level | store-level (by default) | atom-level | query-key level | per-document |
| Component imports | `useSelector`, `useDispatch` | `useStore` | `useAtom` | `useQuery` | **zero** |
| Write model | reducer (function) | direct mutation | atom setter | mutation fn | descriptor (data) |
| Action log | action history (DevTools) | none | none | none | **built-in, serializable** |
| Offline queue | no | no | no | optimistic only | **built-in, durable** |
| Adapter pattern | no (custom middleware) | no | no | adapter-like | **first-class** |
| Real-time subscriptions | no (custom middleware) | no | no | no | **built-in** |
| Time travel | DevTools only | no | no | no | `history.back/goto()` |
| DevTools | **excellent** | basic | basic | good | none |
| AI safety | low — logic drifts into components | low | medium | medium | **high — structural** |
| Schema migration | no | no | no | no | versioning array |
| Type safety | good | excellent | excellent | excellent | partial (untyped Doc) |
| Learning curve | high | low | medium | medium | medium |

**Key gaps vs Redux:** No DevTools browser extension. No middleware ecosystem. No community.
No support for REST APIs without a custom adapter (the collection/document model doesn't
map cleanly to URL-keyed HTTP endpoints). No SSR/hydration story.

**Key advantages vs Redux:** Zero component imports (structural enforcement), write
descriptors vs reducers, per-document subscriptions vs selector composition, offline
queue built-in, adapter swap in one line, schema migration, errors as subscribable data.

**RTK specifically:** RTK's `createSlice` + `createSelector` is a patch on Redux's
fundamental design — one global state tree that all selectors must traverse. The
memoization overhead grows proportionally to state tree size. fiskal-antifragile
sidesteps this entirely: subscriptions are per-document, there are no selectors.

**TanStack Query specifically:** TanStack is designed for HTTP/REST: `queryKey: ['tasks', id]`,
`queryFn: () => fetch(...)`. It maps directly to a URL. fiskal-antifragile maps to a
document store (collection + id). For teams on REST APIs without real-time subscriptions,
TanStack requires no mental model shift and has excellent TypeScript support.
fiskal-antifragile would require writing a `RestAdapter` that maps collection queries to
HTTP calls — more initial work, in exchange for offline queue, write log, and a
real-time subscription path.

**Where developers genuinely get better ergonomics in TanStack / RTK:**

1. **REST API ergonomics.** `useQuery(['tasks', id])` maps directly to `GET /tasks/:id`.
   No adapter code needed. fiskal-antifragile requires a custom adapter for every
   non-document backend.

2. **TypeScript inference.** `useQuery<Task, Error>` gives strongly-typed data and
   error in one call. fiskal-antifragile delivers `Doc | null` — type must be asserted
   manually. The query-result-to-component-prop type bridge is unverified.

3. **SSR/hydration.** TanStack's `dehydrate`/`hydrate` works seamlessly with Next.js.
   fiskal-antifragile has no SSR support — `window.localStorage` is undefined on the
   server and MemoryAdapter starts empty, so first renders always show loading state.

4. **Background refetch / stale-while-revalidate.** TanStack's `staleTime` + `cacheTime`
   model is battle-hardened for polling APIs. fiskal-antifragile assumes persistent
   subscriptions. For polling-based backends (no WebSockets), the developer must implement
   the refetch loop inside a custom adapter.

5. **Request deduplication.** TanStack deduplicates concurrent requests for the same key.
   fiskal-antifragile doesn't specify whether two wired components with the same query
   make one adapter call or two — it's adapter-dependent.

6. **Infinite scroll via `useInfiniteQuery`.** Built-in cursor management, `hasNextPage`,
   `fetchNextPage`. fiskal-antifragile needs `limit`/cursor in QuerySpec (currently
   missing) and a `ui/scroll/cursor` document — more explicit, more code.

**Where fiskal-antifragile prevents issues those libraries create:**

1. **The "write and forget" error.** `dispatch(archiveTask(id))` in RTK drops the error
   unless the developer wraps the call. In fiskal-antifragile, errors go to the `errors`
   collection — any component subscribes without call-site try/catch.

2. **Selector staleness.** RTK's `createSelector` can return stale memoized results when
   input shapes change subtly. fiskal-antifragile has no selectors — per-document
   subscriptions re-run on every actual change.

3. **Manual `invalidateQueries`.** After every TanStack mutation, the developer must call
   `queryClient.invalidateQueries(key)` to refetch affected data. Forget one, and the
   cache shows stale data indefinitely. fiskal-antifragile's real-time subscriptions
   never need manual invalidation.

4. **`useEffect` fetch chains.** RTK patterns accumulate `useEffect(() => { dispatch(fetch...) }, [id])`
   everywhere — each one a potential race condition, stale closure, or memory leak.
   fiskal-antifragile's wireView handles subscribe + cleanup. Components have zero effects
   for data concerns.

5. **Logic drift into components.** TanStack and RTK require imports inside components
   (`useQuery`, `useSelector`, `useMutation`). AI agents will use these APIs to
   implement business logic inline. fiskal-antifragile's zero-import rule makes this
   physically impossible.

6. **Provider pyramid.** RTK requires `<Provider store={store}>`. TanStack requires
   `<QueryClientProvider>`. Nesting multiple providers is a standard pain point.
   fiskal-antifragile has no provider requirement.

---

### Swift ecosystem

| Dimension | @Observable (Swift 5.9+) | SwiftData | TCA | fiskal-antifragile Swift |
|---|---|---|---|---|
| Re-render granularity | **per-property** (via macro) | **per-property** | store-level | per-document (via @Observable internally) |
| Persistence | none | **automatic** (CoreData) | none | adapter-based |
| CloudKit sync | no | **built-in** | no | CloudKitAdapter |
| Write model | direct mutation | direct mutation | action (data) | descriptor (data) |
| Action log | no | no | **excellent** | built-in |
| Offline queue | no | partial (CloudKit) | no | built-in |
| Cross-platform | no | no | no | **yes (Swift + TS)** |
| Type safety | **excellent** | **excellent** | **excellent** | partial (Doc untyped) |
| Testability | good | needs container | **excellent** | excellent (plain structs) |
| Learning curve | low | medium | **high** | medium |

**`@Observable` is not a competitor — it's the implementation.**
The Swift library uses `@Observable` internally. Property-level re-render granularity
is inherited automatically. fiskal-antifragile adds what @Observable alone doesn't have:
adapter pattern, offline queue, write log, cross-platform model, and `ui/` path routing.

**SwiftData** is the meaningful Apple-native alternative. For apps that only target Apple
platforms and use CloudKit, SwiftData provides schema migration, query macros, and iCloud
sync with zero library code. The gaps: no write log, no offline queue with explicit
ordering, no TypeScript parity. fiskal-antifragile wins if any of those are required.

**TCA (The Composable Architecture)** is the closest in philosophy. Key differences:
- TCA requires explicit `Effect` types for all side effects — highly structured, strongly typed
- fiskal-antifragile's effects are implicit (the adapter handles them) — less structured, less boilerplate
- TCA has an excellent browser-based viewer for state inspection; fiskal-antifragile has none
- TCA has no adapter pattern — swapping backends requires rewriting effects
- fiskal-antifragile compiles to both platforms from a shared model; TCA is Swift-only

---

## Part 7 — What this library does better than all of them

These are genuine advantages, not just trade-offs:

**1. Structural AI safety.** The zero-import rule for components is unique. Redux, Zustand,
Jotai, TCA all require imports inside components. An AI agent writing component code with
access to the store API will eventually pollute the component with store logic. Here it
cannot — physically. This matters enormously for AI-generated codebases.

**2. Write descriptors as first-class values.** Redux actions are serializable but reducers
are not. The action says what happened; the reducer says how to apply it — and the reducer
is a function, not data. In fiskal-antifragile, the `write` descriptor is the entire
semantic unit: `{ id: 'tasks/task-1', fields: { status: 'archived' }, merge: true }`.
Ship it to a server. Replay it. Diff two of them. Compare across sessions. This is
not possible with any reducer-based system.

**3. Adapter swap in one line.** No other library in this list — Redux, Zustand, Jotai,
TCA, @Observable — supports replacing the entire backing store with one line change.
The backend swap doesn't touch components, queries, mutates, or tests.

**4. Offline-first by default.** MemoryAdapter is fully functional, not a test stub.
The developer starts with a working offline app and adds network sync when ready. Every
other system (except SwiftData with its CloudKit mode) requires the developer to
architect offline support from scratch.

**5. The `ui/` path routing.** The distinction between local-only and remote-synced state
is structural (path prefix → adapter routing), not declarative (a flag on the write).
No other system has an equivalent built-in mechanism.

---

## Summary: what to fix before shipping

**Implementation gaps (design is correct — code is behind):**

| Issue | ADR | Sprint |
|---|---|---|
| Model compute not applied — `createStore` needs `models` field + enrichment | ADR-0007 | Next |
| Schema validation not enforced at write time | ADR-0007 | Next |
| Multiple backing stores not implemented | ADR-0007 | Next |
| `createMutate` missing `read` step | New ADR | Next |
| Errors not surfaced as subscribable collection | ADR-0008 | Next |
| LocalStorageAdapter missing cross-tab `storage` event | ADR-0006 (update) | LocalStorage sprint |

**Architectural holes that need fixes or ADRs:**

| Issue | Severity | When |
|---|---|---|
| PII redaction in history log | **High** | Before production |
| `limit` / cursor in QuerySpec — required for large collections | **High** | After first live users |
| wireView not type-safe on query results | **Medium** | Future |
| Registry naming convention to prevent injection collisions | **Medium** | Document now |
| Code-splitting load order for registry | **Medium** | If using React.lazy |
| DevTools / store inspector | **Medium** | Own sprint |
| Reactive/dependent queries | **Low** | Future |

**Honest limits (intentional, document and accept):**

| Issue | Notes |
|---|---|
| Time travel is in-memory only — server overwrites on sync | Document: use compensating writes for persistent undo |
| No REST API ergonomics — requires custom adapter | TanStack Query is better for pure REST |
| No SSR/hydration story | Next.js apps need a dehydrate/hydrate mechanism |
| No middleware ecosystem (no saga, no observable) | Side effects belong in the adapter or in the server |
| No DevTools browser extension | `store.history.log()` is the current substitute |
| TypeScript type safety is partial — Doc is untyped | Typed wireView is a future ADR |
