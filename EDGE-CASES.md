# Edge Cases

Hard offline-first scenarios and how fiskal-antifragile handles them.

These are the cases that break Redux, Zustand, Jotai, and Swift Combine in practice —
sourced from postmortems, blog complaints, and GitHub issue trackers.
Full Gherkin coverage is in `_tdd/offline/hard-scenarios.feature`.

---

## Core convention — IDs are full paths

Every document's `id` is the full path: `'{collection}/{localId}'`.

```
'tasks/task-1'          → collection: tasks,   local id: task-1
'sprints/sprint-A'      → collection: sprints, local id: sprint-A
'ui/modal/active'       → collection: ui/modal, local id: active
```

In single-document queries, `id` alone is enough — the store parses the collection from
the prefix. `collection` is only needed for collection-level queries (where, orderBy):

```ts
{ id: 'tasks/task-1' }                              // single doc — no collection needed
{ collection: 'tasks', where: { status: 'active' } } // collection query — collection required
```

This means every write only needs an `id`:

```ts
createMutate(store, { write: ({ id }) => ({ id, fields: { status: 'archived' }, merge: true }) })
//                                          ↑ 'tasks/task-1' — collection is implicit
```

And the `setModal` pattern is just passing `task.id` through — no collection bookkeeping:

```ts
setModal({ id: task.id })    // task.id = 'tasks/task-1' — already a full path
```

---

## 1. Optimistic update divergence

### Server returns enriched data the client didn't anticipate

**The problem (Redux):** The optimistic reducer assumed the write shape. The server added
`completedAt` and `updatedBy` fields. The UI showed the optimistic (wrong) version forever
because nothing re-reconciled after the write confirmed.

**How we handle it:**
The adapter's `subscribe` stream stays open after every write. When the server sends back
the authoritative record, `onChange` fires, the cache updates, and all subscribers re-render.
No reconciliation code — the write and the subscribe are independent channels.

```
write(archiveTask) → optimistic cache update → adapter.write() confirms
                                                ↓
                               adapter.subscribe fires with full server record
                                                ↓
                              cache updated with server data → re-render once
```

The only requirement: the adapter keeps its subscription active for the document that was
just written. MemoryAdapter, FirestoreAdapter, and CloudKitAdapter all do this.

---

### Server rejects the write — derived state doesn't update

**The problem (Jotai):** After rollback, derived atoms cached the stale computed value.
The source atom was reset but the derived atom didn't re-run because its reference equality
check passed on the old shape.

**How we handle it:**
On write failure, `createMutate` calls `restoreCache(snapshot)` and then notifies all
affected collections. There are no derived atoms or memoized selectors — every query runs
fresh against the restored cache snapshot. Structural sharing means "fresh" is cheap.

```
write fails → restoreCache(preWriteSnapshot) → notify('tasks')
                                                     ↓
                               all subscribers re-run their query against the snapshot
                               including any "active tasks count" or filtered views
```

---

### Background subscribe push overwrites an in-flight optimistic write

**The problem (Zustand):** Background polling reset the store while the user was mid-edit.
Stale server data silently overwrote the in-progress optimistic state.

**How we handle it:**
The store tracks in-flight write operations per document. A subscribe push for a document
with a pending write is held until the write confirms or fails. If the push has a server
timestamp older than the write timestamp, it is discarded.

App-level guidance: if using polling (not real-time subscriptions), wrap any background
refresh call in a check — don't push data for documents with queued local writes.

---

## 2. Offline write queue

### Writes replay out of order on reconnect

**The problem:** Writes replayed in network-arrival order rather than user-action order,
producing a different final state (archive → unarchive → archive becomes unarchive →
archive → archive).

**How we handle it:**
The queue is an append-only array of `WriteDescriptor` objects stored in `store.history`.
On reconnect the adapter drains the queue serially — each write awaits confirmation before
the next is sent. The queue is never sent in parallel.

```
queue: [archive(t=1), unarchive(t=2), archive(t=3)]
         ↓ await                 ↓ await              ↓ await
      server confirms        server confirms        server confirms
```

The write descriptors are plain JSON — serializable to disk, diffable, and inspectable.

---

### Offline queue fails halfway through

**The problem (Redux saga):** No way to partially roll back a multi-write queue. The UI
was stuck in an indeterminate state after a partial flush.

**How we handle it:**
Each write in the queue has its own pre-write snapshot. A failure at write N:
1. Restores the cache to the snapshot taken before write N
2. Marks the write N descriptor as `failed` in `store.history.log()`
3. Leaves writes 1 through N-1 committed (they already confirmed)
4. Surfaces the failed write descriptor so the UI can show "Write failed — tap to retry"

Writes 1..N-1 are not rewound. The failure boundary is per-write, not per-session.

---

### OS kills the app mid-queue

**The problem:** The queue lives in memory. When the OS suspends and kills the app, the
queue is gone. On relaunch the UI shows the optimistic state with no way to confirm or
cancel the pending writes.

**How we handle it:**
Before the app goes to background, the queue is persisted to the platform's durable
store (UserDefaults for ephemeral, Keychain or SQLite for anything that should survive
reinstall). On relaunch:
1. Re-hydrate the queue from durable storage
2. Re-apply the optimistic writes to the cache (so the UI looks the same)
3. On reconnect, drain the queue normally

This requires the app to call `store.persist()` in the platform's background handler.
The library provides the serialization; the app owns the lifecycle hook.

---

## 3. Cross-client conflict

### Last-write-wins — the losing client must roll back

**The problem:** Client A's optimistic state (status: done) is never rolled back after
client B's write (status: archived) wins on the server.

**How we handle it:**
The adapter's real-time subscription sends the winning server record to all clients.
Client A's subscribe fires with `{ status: "archived" }`, the cache updates, and the
component re-renders. The rollback is implicit — the subscribe overwrites the stale
optimistic state with the authoritative server value.

The losing write is still in `store.history.log()` for debugging. The `action` field
names what was attempted; the write descriptor shows what was sent.

---

### Merge — two clients modify different fields of the same entity

**The problem (Redux):** The reducer replaced the whole object. The second client's write
dropped the first client's field change.

**How we handle it:**
All `createMutate` writes default to `merge: true`. The adapter applies them as partial
updates — only the fields in `write.fields` are changed. Fields not mentioned are untouched.

```ts
// Both of these survive on the server — they touch different fields
createMutate(store, { write: ({ id }) => ({ collection: 'tasks', id, fields: { title: 'Deploy v2' }, merge: true }) })
createMutate(store, { write: ({ id }) => ({ collection: 'tasks', id, fields: { assignee: 'carol' }, merge: true }) })
```

Only use `merge: false` when you explicitly want to replace the full document.

---

### Delete on one client, edit on another

**The problem:** The editing client receives a 404 on sync, the UI tries to render the
deleted entity, and crashes on null access.

**How we handle it:**
When the adapter receives a "not found" or "deleted" signal, it calls `onChange([])` for
that document's query. The cache removes the document. wireView generates a null-safe
render: `if (!task) return null` — which the wired component wrapper enforces.

The pure view should always handle a null/undefined entity prop — this is a contract, not
a nice-to-have. wireView makes the null state the default return when the query has no result.

---

## 4. Dependent writes

### Write B references a server-generated ID from write A

**The problem:** Task created with client id `tmp-1`. Comment written immediately with
`taskId: "tmp-1"`. Server assigns `id: "srv-99"`. Comment reaches server with the wrong id.

**How we handle it:**
**Don't use server-generated IDs.** The library assumes client-generated UUIDs everywhere.
Pass `id: UUID().uuidString` in every write. Tell the server to accept client ids.
Firestore, Supabase, CloudKit, and GunJS all support this.

If you must use server-assigned IDs (legacy backend), the app must hold write B in the
queue until write A confirms and map `tmp-1 → srv-99` before flushing write B. The
library provides the queue and history API; the ID-remap logic is app-level.

---

### Read-modify-write race (the "lost update")

**The problem:** Two clients both read balance=500, both add 100, both write 600. Final
balance is 600, not 700.

**How we handle it:**
Use atomic operations, not field sets:

```ts
createMutate(store, {
  write: ({ amount }) => ({
    collection: 'accounts', id: 'acct-1',
    fields: { balance: { __op: '::increment', n: amount } },
  }),
})
```

The adapter translates `::increment` to a native atomic operation:
- Firestore: `FieldValue.increment(n)`
- CloudKit: CKRecord fetch + server-side modify (requires transaction)
- MemoryAdapter: read-modify-write inside a synchronous lock

Never read a balance and write `balance: old + n`. Always use `::increment`.

---

### Atomic transaction across entities (transfer money)

**The problem:** Debit succeeds, credit fails. acct-1 loses $50; acct-2 never gains it.

**How we handle it:**
Use the transaction form of `createMutate` — an array of writes executed atomically:

```ts
const transfer = createMutate(store, {
  write: ({ from, to, amount }) => [
    { collection: 'accounts', id: from, fields: { balance: { __op: '::increment', n: -amount } }, merge: true },
    { collection: 'accounts', id: to,   fields: { balance: { __op: '::increment', n:  amount } }, merge: true },
  ],
})
```

The adapter executes both writes in a single transaction. If either fails, neither applies.
The pre-write cache snapshot is restored and both collections are notified.

---

## 5. Entity lifecycle

### Deleted remotely while the user is on the detail screen

**The problem:** Component renders, entity disappears from the store, component crashes on
null access of `task.title`.

**How we handle it:**
When the adapter fires `onChange([])` for a deleted document, the cache removes it and
notifies subscribers. wireView's generated component wrapper returns `null` when the query
result is empty — before the pure component is called. The pure component never sees null.

The app can render a "Not found" state by checking: if the wired component renders
nothing, its parent can show a fallback.

Pattern:
```tsx
// WiredTaskItem returns null when the document is gone
// Parent can handle this:
<WiredTaskItem taskId={id} /> ?? <p>Task no longer exists.</p>
```

---

### Deep link to an entity not in the local cache

**The problem (Jotai):** Async atom threw during suspense when the id wasn't cached yet.
The error boundary caught it but the loading state was never shown — the UI just flashed white.

**How we handle it:**
wireView's initial render returns the cached value synchronously if it exists, or starts the
adapter's subscribe (which fetches from the remote) and returns the "loading" state.
The loading/data/null contract is explicit:

```
undefined   → loading (adapter hasn't responded yet)
null        → not found (adapter responded with empty)
Doc         → data available
```

There is no throw during loading — Suspense is opt-in. The component receives `undefined`
and should render a spinner. There is no flash because the loading state is immediate.

---

## 6. Multi-step transaction rollback

### Wizard cancelled mid-way — 5 writes must roll back as a unit

**The problem:** The user filled 3 screens of data. Steps 1–3 wrote optimistically.
Network drops before step 4. Pressing "Cancel" needs to undo all 3 writes.

**How we handle it:**
Before the wizard starts, snapshot the current history index:

```ts
const wizardStart = store.history.currentIndex()
```

On cancel:

```ts
store.history.goto(wizardStart)  // restores cache to before the wizard; notifies all affected collections
```

`goto` is synchronous — it restores the structural-sharing snapshot for that index and
batch-notifies all collections touched by the range of writes being undone. All wired
components re-render in one pass.

The server is not involved — the queued writes are simply removed from the queue before
they are sent. If some writes already confirmed, they must be explicitly reversed via a
"delete draft" mutate.

---

### Undo a cross-entity action

**The problem (Redux):** Time travel only worked on single-reducer slices. Cross-slice undo
required custom saga logic.

**How we handle it:**
`store.history.back()` restores the entire cache snapshot from before the last write.
The snapshot is the full in-memory cache — all collections simultaneously. It is not a
per-collection undo.

Every write produces a snapshot of the whole cache via structural sharing (only changed
nodes are new objects; everything else reuses references). Restoring a snapshot is O(1)
— just replace the current cache pointer.

The history entry records which collections were modified. On `back()`, exactly those
collections are notified. Components in unchanged collections don't re-render.

---

## 7. Pagination + local mutation

### New item should appear on page 1 while the user is on page 3

**The problem:** A new item is created locally but it appears at the bottom of the visible
page rather than at its sorted position at the top.

**How we handle it:**
The store does not manage pagination state. It manages sorted collections. A query with
`orderBy` returns the full sorted list; the component slices it into pages.

When a new item is written locally, it enters the cache immediately. The collection
subscriber fires. The query re-runs with `orderBy` and returns the new sorted list.
The component re-slices. The new item is at position 0.

The component is responsible for knowing which page it is on — and page is UI state.
Store it in `ui/taskList/view.page` (or `anchorId` for infinite scroll). The component
reads both the full sorted list and the current page from the store and slices accordingly.
When new items arrive, the data is correct; the page state is unchanged; the component
re-slices cleanly.

**Recommendation:** Prefer `anchorId` over page number. An `anchorId` is stable when
items are inserted or deleted. A page number shifts when items are inserted before the
current page.

---

### Infinite scroll — insert at top should not cause a visual jump

**The problem:** An insert at position 0 while the user is at position 50 shifts the
entire list and the user loses their place.

**How we handle it:**
The scroll anchor is UI state. It lives in `ui/scrollList/view` like any other local state.
The store is the source of truth for both the sorted data and the anchor — not the
browser's `scrollTop`.

```ts
// On scroll: record the id of the topmost visible item
const setAnchor = createMutate(store, {
  write: ({ anchorId }) => ({
    collection: 'ui/scrollList', id: 'view', fields: { anchorId }, merge: true,
  }),
})
```

```ts
// wireView reads both the sorted list and the anchor together
wireView('TaskList',
  {
    taskIds:  { collection: 'tasks', where: { status: 'active' }, orderBy: { createdAt: 'desc' } },
    listView: { collection: 'ui/scrollList', id: 'view' },
  },
  ['setAnchor'],
  TaskList,
)
```

The component receives `taskIds` (always correct sorted order) and `listView.anchorId`
(the item the user last scrolled to). It renders the list from the anchor position.

When the new item inserts at position 0, `taskIds` gains one entry at the front.
`listView.anchorId` is still `"item-38"`. The component finds `"item-38"` in the new
list at index 39 and renders from there. No visual jump. No imperative `scrollTop`.
No `useRef`. The component is still a pure function of its props.

```
Before insert:   [item-new, item-1, ..., item-38 (anchor, index 37), ..., item-50]
After insert:    [item-new, item-1, ..., item-38 (anchor, index 38), ..., item-51]
                                          ↑
                               anchor id unchanged — component
                               renders from here in both cases
```

This also means scroll position survives a full re-render, a route change and back,
and serialises naturally for deep linking ("open the list anchored at item-38").

---

## 8. Derived / computed state staleness

### Filtered query count does not update when source changes

**The problem (Jotai):** Q2 (derived count) cached its result. Q1 (source query) updated
but Q2 didn't re-run because the reference equality check passed on the old object shape.

**How we handle it:**
There are no derived atoms or memoized selectors. Both Q1 and Q2 subscribe directly to
the raw cache. When the cache updates, both subscribers re-run their query functions
against the new snapshot. Each query is a pure function: `(cache, querySpec) → Doc[]`.

Queries are cheap: filtering an in-memory Map of 1000 documents takes under 1ms. The
structural-sharing cache ensures the Map itself is only re-traversed for the affected
collection — not the whole store.

```
cache update (tasks collection)
  → notify tasks subscribers
    → Q1 re-runs filter(status == active) → ["item-1"]     (was ["item-1", "item-2"])
    → Q2 re-runs count(status == active)  → 1              (was 2)
```

No invalidation call. No cache key. No `revalidate()`. Just re-run the query.

---

### `isOverdue` depends on wall-clock time, not a stored field

**The problem:** The compute getter reads `Date.now()` which changes constantly but there
is no write to trigger a re-render.

**How we handle it:**
The compute getter runs fresh on every read, but components only re-render when the store
notifies them. Wall-clock changes do not notify the store.

**Recommended pattern:** Store `dueDate` as a number. Create a timer in the component
that fires when `Date.now()` crosses `task.dueDate` and writes a synthetic `isOverdue: true`
field to the cache. This makes `isOverdue` a stored field, not a computed one.

Alternative: the component subscribes to a 1-minute tick event and forces a re-render.
This is explicit — the developer chooses the refresh granularity.

There is no silent auto-refresh for time-sensitive computations. The library does not
poll wall time. This is intentional: silent polling would make test behaviour non-deterministic.

---

### `createdAtDisplay` format compute updates when `createdAt` changes

**How we handle it:**
Compute getters run at read time, not at write time. When `createdAt` changes, the cache
updates and the subscriber fires. The wired component re-renders. The component reads
`task.createdAtDisplay` which the model getter computes fresh from the new `task.createdAt`.

```
write(createdAt: 1760000000)
  → cache updates
  → subscriber fires
  → component re-renders
  → reads task.createdAtDisplay (getter runs: new Date(1760000000 * 1000).toLocaleDateString())
  → renders "Oct 9, 2025"
```

No memoization layer, no stale formatted string. The model getter is pure: same input →
same output.

---

## 9. Subscription lifecycle

### Navigate away and back accumulates duplicate subscriptions

**The problem (React hooks):** Each mount adds a subscriber. Unmount doesn't clean up.
After 10 navigate-away/back cycles, 10 callbacks fire per write.

**How we handle it:**
`wireView`'s `useEffect` returns the unsubscribe function:

```ts
useEffect(() => {
  const unsubs = Object.entries(queries).map(([key, spec]) =>
    store.adapter.subscribe(query, onChange)
  )
  return () => unsubs.forEach(u => u())
}, [queryKey])
```

React calls the cleanup function before every re-run of the effect and on unmount.
The store's `subscribe` returns a function that removes the callback from the subscriber
set. After 10 navigate cycles: exactly 1 active subscriber.

This is the standard React pattern. The key is that `adapter.subscribe` returns an
unsubscribe function (not a token or id) — the closure makes cleanup simple.

---

### Rapid prop changes accumulate subscriptions

**The problem:** `taskId` changes 10 times quickly. Each change should unsub from the old
id and sub to the new id. Without correct deps, 10 subscriptions stack up.

**How we handle it:**
The `useEffect` dependency is `JSON.stringify(resolvedQueryMap)`. When `taskId` changes,
the serialised query string changes, the effect re-runs, and the previous cleanup function
cancels the old subscription before the new one is created.

React guarantees cleanup runs before the next effect for the same component. So:
- taskId changes from item-1 → item-2 → item-3
- cleanup(item-1 subscription) → subscribe(item-2) → cleanup(item-2) → subscribe(item-3)
- Final state: 1 subscription, for item-3

---

### React StrictMode double-mount

**The problem:** StrictMode mounts → unmounts → re-mounts in dev. A naive `useEffect`
fires twice, creating 2 subscriptions and delivering data twice on the first write.

**How we handle it:**
The cleanup function from the first (StrictMode) mount runs before the second mount.
This cancels the first subscription before the second is created. The second mount's
subscription is the only one that survives.

The subscriber set in `store.adapter` is a `Set<callback>`. If the same callback reference
is added twice (which it won't be, since each mount creates a new closure), it is deduplicated.
In practice StrictMode works correctly because cleanup runs in the correct order.

---

## 10. Schema migration

### New required field — old cached records missing it

**The problem (Swift CloudKit):** The app shipped `priority` as a new required field.
Users with cached v1 data got a crash when the view tried to read `task.priority` and
got `undefined`.

**How we handle it:**
The Model `versioning` array defines a `rollforward` transform applied at read time:

```ts
versioning: [
  {
    partialSchema: { priority: { type: 'string', enum: ['high', 'medium', 'low'] } },
    rollforward: (doc) => ({ ...doc, priority: doc.priority ?? 'medium' }),
    rollback:    (doc) => { const { priority, ...rest } = doc; return rest },
  },
]
```

When a v1 document is read from the cache, `rollforward` adds `priority: 'medium'`.
The write to the server does not need to include `priority` unless the user changes it —
but once a v2 client writes the document, `priority` is included permanently.

Old data is never modified in storage by migration — only transformed at read time.

---

### Field renamed across a rolling deployment

**The problem:** v1 writes `dueDate`; v2 writes `due_at`. During rollout, both versions
are active. A v1 client reading a v2-written record gets `undefined` for `dueDate`.

**How we handle it:**
Two versioning entries — one to roll v1 → v2, one to roll v2 → v1:

```ts
versioning: [
  {
    rollforward: (doc) => doc.dueDate ? { ...doc, due_at: doc.dueDate } : doc,
    rollback:    (doc) => doc.due_at  ? { ...doc, dueDate: doc.due_at } : doc,
  },
]
```

The adapter applies the appropriate transform based on which version of the schema is
active for the current app version. Both field names coexist in the document during
the rollout window; neither client gets `undefined`.

---

### Schema rollback — v3 ships, breaks in production, rolls back to v2

**The problem:** v3 clients wrote a `metadata` field. The rollback to v2 caused v3-written
records to crash v2 clients reading them.

**How we handle it:**
The versioning `rollback` function strips the unknown field gracefully:

```ts
{ rollback: (doc) => { const { metadata, ...rest } = doc; return rest } }
```

v2 clients never see `metadata`. They read past it cleanly. Any writes from v2 clients
do not strip `metadata` from the stored record — they use `merge: true`, so untouched
fields survive.

The key invariant: never use `merge: false` on a document that may have fields from a
newer schema version. `merge: true` is the safe default.

---

## 11. UI state / domain state boundary

### `ui/sidebar` write must never reach the remote adapter

**The problem (Zustand):** UI state stored in the same slice as domain data. The sidebar
open/closed flag was persisted to the server on every save.

**How we handle it:**
Paths prefixed with `ui/` are routed to a local-only MemoryAdapter in the store config.
The write dispatch logic inspects `write.path` before choosing which adapter to call:

```ts
// In createStore config:
{
  default:  { adapter: FirestoreAdapter(app), models: [...] },
  ui:       { adapter: MemoryAdapter(), paths: ['ui/'] },     // local-only
}
```

A write to `ui/sidebar/global` never reaches Firestore. A page refresh resets it.
The path prefix is the enforcement mechanism — not a flag on the write, not a check in
the component. Structural.

---

### Cross-user shared device — user A's UI state must not bleed to user B

**The problem:** User A logged out. User B logged in. User A's expanded rows, selected
items, and draft form data were still visible.

**How we handle it:**
On logout, clear the entire `ui/` collection:

```ts
store.clear('ui/')
```

This removes all documents under the `ui/` path and notifies all subscribers.
All wired components reading `ui/` data re-render with empty/null state.

Domain data is NOT cleared on logout — it is re-queried for the new user's credentials.
The adapter handles user identity at the network layer.

---

### Form draft cancelled — no orphaned domain record, no history entry

**The problem (Redux-form):** In-progress form data polluted the store and was never
cleaned up after cancel. Orphaned draft records appeared in the domain collection.

**How we handle it:**
Draft state writes to `ui/taskForm/draft` (local-only path), not to `tasks`.

```ts
const setDraft   = createMutate(store, { write: (fields) => ({ path: 'ui/taskForm', id: 'draft', fields, merge: true }) })
const clearDraft = createMutate(store, { write: ()       => ({ path: 'ui/taskForm', id: 'draft', delete: true }) })
const submitTask = createMutate(store, { write: (fields) => ({ path: 'tasks', id: UUID(), fields }) })
```

On cancel: `clearDraft()` — no domain write, no history entry for AddTask.
On submit: `submitTask(draft)` then `clearDraft()` — the only domain write is `AddTask`.

`store.history.log()` shows `SetDraft` and `ClearDraft` entries, never a spurious `AddTask`.
The tasks collection is untouched until the user explicitly submits.

---

## 12. React patterns engineers reach for — and why they're unnecessary

### Portals and Context — both replaced by the query system

**The portal problem:** A modal triggered from inside a scrollable card with `overflow: hidden`
renders inside that DOM subtree and is visually clipped. Developer escapes with
`ReactDOM.createPortal(modal, document.body)`.

**The context problem:** `{ setModal }` needs to be reachable from any list row deep in the
tree. Developer reaches for `React.createContext` to avoid prop drilling. But context
consumers all re-render when the context value changes — even if they only read `setModal`,
a stable function reference that never changes.

**Root cause for both:** the component that triggers the modal is also responsible for
finding `setModal` and knowing what to render. The data, the trigger, and the render are
all tangled together.

**How we handle it — the query is a value that an action can write:**

`setModal` is a `createMutate` that writes a query descriptor into `ui/modal/active`.
The query descriptor tells the modal _what to fetch_ — not just what type of thing, but
exactly which document from which collection.

**IDs are always full paths — `collection/localId`.**

Every document's `id` encodes both the collection and the local identifier: `'tasks/task-1'`,
`'sprints/sprint-A'`, `'ui/modal/active'`. In most queries you only need to pass `{ id }` —
the store parses the collection from the path prefix automatically. Separate `collection`
is only needed for collection-level queries (where clauses, orderBy).

```ts
// Single-document query — id alone is enough
{ id: 'tasks/task-1' }                              // same as { collection: 'tasks', id: 'task-1' }

// Collection query — collection is needed when querying without a specific id
{ collection: 'tasks', where: { status: 'active' } }
```

```ts
const setModal = createMutate(store, {
  // stores the full path id — the modal reads it back and uses it directly as its query
  write: ({ id }) => ({ id: 'ui/modal/active', fields: { id }, merge: false }),
})
const closeModal = createMutate(store, {
  write: () => ({ id: 'ui/modal/active', delete: true }),
})
```

Any wired component at any depth gets `setModal` as an injected action. No context.
No prop drilling. No Provider anywhere.

```ts
// TaskRow — wired with setModal. task.id is already 'tasks/task-1'.
const WiredTaskRow = wireView('TaskRow',
  ({ taskId }) => ({ task: { id: taskId } }),   // 'tasks/task-1' — no collection needed
  ['setModal'],
  TaskRow,
)

// SprintRow — same action, sprint.id is 'sprints/sprint-A'
const WiredSprintRow = wireView('SprintRow',
  ({ sprintId }) => ({ sprint: { id: sprintId } }),
  ['setModal'],
  SprintRow,
)

// Pure components pass task.id (the full path id) directly — no collection juggling
const TaskRow   = ({ task,   setModal }) => <li onClick={() => setModal({ id: task.id   })}>{task.title}</li>
const SprintRow = ({ sprint, setModal }) => <li onClick={() => setModal({ id: sprint.id })}>{sprint.name}</li>
```

`WiredModal` at the app root reads `ui/modal/active` (which holds the stored path id) and
passes it as the query for `WiredModalDetail`. The modal fetches whatever document the id
points to — no type registry, no collection switch.

```ts
// ModalShell reads the stored path id
const WiredModalShell = wireView('ModalShell',
  { active: { id: 'ui/modal/active' } },
  ['closeModal'],
  ModalShell,
)

// ModalDetail query is driven by the stored id — tasks or sprints, doesn't matter
const WiredModalDetail = wireView('ModalDetail',
  ({ activeId }) => activeId ? { item: { id: activeId } } : {},
  ['closeModal'],
  ModalDetail,
)

const ModalShell = ({ active, closeModal }) =>
  active ? <WiredModalDetail activeId={active.id} /> : null
```

```
TaskRow click → setModal({ id: 'tasks/task-1' })
                  ↓ writes { id: 'tasks/task-1' } to ui/modal/active
                WiredModalShell re-renders (active.id = 'tasks/task-1')
                  ↓ passes activeId to WiredModalDetail
                WiredModalDetail query: { id: 'tasks/task-1' } → fetches task-1
                ModalDetail renders task-1

SprintRow click → setModal({ id: 'sprints/sprint-A' })
                  ↓ same path, different id
                WiredModalDetail query: { id: 'sprints/sprint-A' } → fetches sprint-A
                ModalDetail renders sprint-A
```

**What this replaces:**
- No `ReactDOM.createPortal` — `WiredModalShell` sits at the root, outside all stacking contexts
- No `React.createContext` — `setModal` is an injected action, not a context value
- No `useContext(ModalContext)` in every component that might need to open a modal
- No type registry mapping "task" → TaskModal component — the query just fetches the document and the component renders whatever it receives

The same query-as-value pattern works for any overlay: drawer, tooltip, dropdown, command
palette. One wired component at the root, one action that writes a query descriptor, any
component in the tree can trigger it.

---

### `useCallback` — stabilising action references

**The problem:** Developer writes `<TaskItem onArchive={useCallback(() => archiveTask(id), [id])} />`
because they believe inline arrows cause child re-renders. Sometimes true — but the root
cause is that `archiveTask` itself is an unstable reference, recreated in the parent on
every render.

**How we handle it:**
Actions from `createWireView` are stable references — they are the same function objects
across all renders. wireView passes them directly to the component without wrapping.
The component receives a stable `archiveTask` prop and never needs `useCallback` to
stabilise it. There are no inline arrow wrappers in any component file.

No `useCallback` anywhere. If you find yourself reaching for it, the signal is that
the action is being created inside the component rather than injected from the store.

---

### `useMemo` — memoising filtered lists and formatted values

**The problem:** Developer writes `useMemo(() => tasks.filter(...), [tasks])` to avoid
re-filtering on every parent render. Often cargo-culted from Redux patterns where the
full unfiltered list was in the component.

**How we handle it:**
Filtering happens in the query — the store runs the filter once when the collection
changes and delivers the result to the subscriber. The component receives the already-
filtered list. It never calls `.filter()` itself, so there is nothing to memoize.

Formatted values (dates, labels) are compute getters on the model. The component reads
`task.createdAtDisplay` — a plain string. No formatting call in the component means no
`useMemo` for formatting.

If the component has a `useMemo`, it is a signal that filtering or computation has
drifted into the component from where it belongs.

---

### Cross-entity computed values — model computers

**The problem:** A component needs a value derived from two separate entities — e.g.
a task's completion percentage relative to its sprint's total. This pushes developers
toward either putting the computation in a Redux selector (carrying both entities through
state) or duplicating it as component logic.

**How we handle it:**
The model has two types of computed members:

- **Getter (formatter):** derives from the document's own fields. `get createdAtDisplay()` reads `this.createdAt`.
- **Computer (function):** takes a sibling document as an argument. Called by the view with the sibling it already has wired.

```ts
const TaskModel = {
  compute: {
    // Getter — formats own field
    get createdAtDisplay() {
      return new Date(this.createdAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
    },

    // Computer — takes a sibling model; view calls it with the sibling it already holds
    completionPercent(sprint) {
      return Math.round((this.completedItems / sprint.totalItems) * 100)
    },
  },
}
```

The view destructures the computer from the document and calls it with the sibling:

```ts
const TaskItem = ({ id, title, completionPercent, sprint }) => (
  <li>
    <span>{title}</span>
    <span>{completionPercent(sprint)}%</span>
  </li>
)

// wireView wires both task and sprint
const WiredTaskItem = wireView('TaskItem',
  ({ taskId, sprintId }) => ({
    task:   { collection: 'tasks',   id: taskId },
    sprint: { collection: 'sprints', id: sprintId },
  }),
  [],
  TaskItem,
)
```

The computation is pure — it lives on the model, takes plain objects, returns a plain value.
No selector. No `useMemo`. No store access inside the component. The component gets both
objects as props and calls the function directly.

**Accuracy vs. optimality — a deliberate trade-off:**

By default, `WiredTaskItem` subscribes to the full `sprint` document. If any field on
the sprint changes — even `sprint.description`, which `completionPercent` doesn't use —
the component re-renders. The re-render is correct (the data is always accurate) but may
be unnecessary (the output didn't change).

This is the right default. Accuracy is free; optimality is earned:

```ts
// Default — re-renders when any sprint field changes. Always accurate.
sprint: { collection: 'sprints', id: sprintId }

// Optimised — re-renders only when the fields the computer actually reads change.
sprint: { collection: 'sprints', id: sprintId, fields: ['totalItems'] }
```

The component destructuring signals the intent: if `TaskItem` only destructures
`completionPercent` and `title` from the task prop, the `fields` query can be narrowed
to match. The destructuring is the declaration; the `fields` query is the enforcement.

Start with no `fields` narrowing (accurate, simple). Add it only when profiling shows
the re-render is actually expensive. The transition is one line in the wireView query —
the component doesn't change.

This is the pattern for any cross-entity value: one model owns the function, the view
wires both entities and calls it. The model stays testable in isolation (pass any two plain
objects), the view stays dumb.

---

### `React.memo` — preventing cascading re-renders from parent updates

**The problem:** Parent re-renders cause all children to re-render even if their props
didn't change. Developer wraps every child in `React.memo` and memoizes every callback.

In Redux the root cause is structural: one big state object, every selector reads from
it, every connected component re-renders when any part of the tree changes.
Redux Toolkit's `createSelector` is a patch on that problem — not a rethink of it.
You still write selectors that carry the state shape, memoize them individually, and
compose them carefully to avoid false positives. The overhead is proportional to how
bad the original design is.

**How we handle it — two rules, no exceptions:**

**Rule 1: query by id, not by collection.**
Each `WiredTaskItem` subscribes to exactly one document: `{ collection: 'tasks', id: taskId }`.
A sibling's update fires only the sibling's subscriber. No cascading re-renders.

**Rule 2: destructure the fields you use.**
Components receive a plain object and destructure the properties they actually render.
No selector. No `createSelector`. No memoization. Just:

```ts
const TaskItem = ({ id, title, status, createdAtDisplay }) => (
  <li className={status}>
    <span>{title}</span>
    <span>{createdAtDisplay}</span>
  </li>
)
```

If `createdAt` changes but `title` and `status` don't, wireView can be queried with
`fields: ['title', 'status', 'createdAt']` to further narrow the subscription. The
component only re-renders when a field it declared it cares about actually changed.

The result: no `React.memo`, no `useCallback`, no `useMemo`, no `createSelector`.
Just components that are plain functions of their props. Clean.

**Why Redux selectors carry so much weight:**
A Redux selector is `state => state.tasks.items[id].title`. It has to know the entire
state shape to navigate to the value. When the state shape changes, selectors break.
When you compose selectors, you chain that fragility.

With fiskal-antifragile, a query is a data descriptor: `{ collection: 'tasks', id, fields: ['title'] }`.
It describes what you want, not where in the tree to find it. The store resolves it.
The component never knows or cares how the store is structured.

---

### Context API — unnecessary because the query system is the sharing mechanism

**The problem:** React Context was invented to share a value (a function, a theme, a user)
without threading it through every intermediate component. The cost: every context consumer
re-renders when the context object changes, even if the consumer only reads a field that
didn't change.

**How we handle it:**
Context is not needed for two reasons:

1. **Any component can wire directly to the store.** wireView at any depth reads exactly
   what it needs and subscribes only to that. No Provider, no consumer, no re-render storm.

2. **The query system handles the "pass a function down" use case.** The canonical reason
   to reach for context is `{ setModal }` — a stable action that deep components need to
   call. With wireView, `setModal` is an injected action. Any wired component can declare
   it in its `actionNames` list and receive it as a prop. See the Portal + Context section
   above for the full pattern.

The only place Context is still appropriate: third-party library APIs that require it
(a theme provider, a translation provider). For your own state — never.

---

### `useEffect` in every component for data concerns

**The problem:** The subscription pattern — fetch on mount, subscribe to changes, clean up
on unmount — ends up in every component that needs data. The `deps` array is subtle; it is
easy to get wrong (missing deps, stale closures, double-subscribe in StrictMode).

**How we handle it:**
wireView owns the subscription lifecycle. The component file has zero `useEffect` calls
for data concerns. The only `useEffect` that belongs in a component is for truly local,
non-data concerns: animation timers, focus management, scroll position updates.

If a component file has a `useEffect` that mentions the store, a collection name, or a
fetch, that logic has drifted in from where it belongs.

---

## 13. SwiftUI patterns engineers reach for — and why they're unnecessary

### `@EnvironmentObject` re-render storm

**The problem:** `AppStore: ObservableObject` holds all tasks. Any `@Published` change —
even `task-2.status` — triggers every view that holds a reference to `AppStore` to
recompute, including views that only read `task-1`.

**How we handle it:**
Each wired view subscribes only to its own query. `WiredTaskItem` for `task-1` subscribes
to the `tasks` collection at `id: "task-1"`. A change to `task-2` notifies only
`task-2`'s subscriber. `task-1`'s view body does not recompute.

No `@EnvironmentObject`. No `@ObservedObject`. No `@StateObject`. The store is accessed
through the `\.store` environment key, but that key value never changes — only the data
inside it does, and subscribers are notified per-document.

---

### `@State` for derived values going stale

**The problem:** Developer writes `@State private var displayDate = ""` and sets it in
`.onAppear`. If `task.createdAt` is updated after the view appears, the display never
updates — the `@State` is a stale cached copy of a computed value.

**How we handle it:**
Derived values are compute properties on the `Task` struct, not `@State`. When the
store updates `task-1.createdAt`, the subscriber fires, the view recomputes, and it reads
`task.createdAtDisplay` fresh. No `.onAppear`. No `.onChange`. No `@State` holding a
formatted string.

The rule: `@State` is for local interaction state only (animation, focus, toggle).
Never for values that derive from store data.

---

### `@Binding` threaded 4 levels deep

**The problem:** A toggle deep in the view hierarchy needs to change a value that the
root view owns. `@Binding<Bool>` is passed through every intermediate view — each of which
has to declare it and thread it down.

**How we handle it:**
The toggle writes to `ui/` directly. Any view at any depth can write UI state to the
store without threading a binding through its ancestors. The value is readable anywhere
without threading a prop downward either.

```swift
// No @Binding — just write
struct ArchiveConfirmToggle: View {
  let taskId: String
  var body: some View {
    // wireView reads ui/confirm/taskId and provides setConfirming action
    wireView(name: "ArchiveConfirmToggle",
             queries: ["state": ["path": "ui/confirm", "id": taskId]],
             actions: ["setConfirming"]) { props in
      let isOn = (props.data["state"] as? [String: Any])?["isConfirming"] as? Bool ?? false
      return AnyView(Toggle("Confirm archive", isOn: Binding(
        get: { isOn },
        set: { _ in Task { try? await props.actions["setConfirming"]?(["taskId": taskId, "value": !isOn]) } }
      )))
    }
  }
}
```

---

### `.sheet()` attached to a leaf view causing presentation glitches

**The problem:** `.sheet()` attached to a `List` row is sometimes captured by the `List`'s
scroll container on certain iOS versions, causing animation or presentation glitches.

**How we handle it:**
Same pattern as the React portal solution. The sheet trigger writes to `ui/sheet/active`.
A `WiredSheet` at the `NavigationStack` or `WindowGroup` root reads that state and
attaches `.sheet()` there. The sheet is always presented from the correct level in the
hierarchy — no glitches, no version-specific workarounds.

```swift
// Any view triggers the sheet — just write
struct TaskRow: View {
  let taskId: String
  var body: some View {
    Button("Edit") { /* writes ui/sheet/active.taskId = taskId */ }
    // No .sheet() modifier here
  }
}

// At the root — one .sheet() for the whole app
struct WiredSheet: View {
  var body: some View {
    wireView(name: "Sheet", queries: ["active": ["path": "ui/sheet", "id": "active"]], actions: ["closeSheet"]) { props in
      // render the correct sheet content based on active.type
    }
  }
}
```
