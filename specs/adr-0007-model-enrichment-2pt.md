# ADR-0007: Model Enrichment at the Store Layer

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

`PRINCIPLES.md` specifies `createStore` accepts a `models` map keyed by collection path:

```ts
createStore({
  default: {
    adapter: MemoryAdapter(...),
    models:  { tasks: TaskModel, sprints: SprintModel },
    mutates: { ... },
  },
})
```

The current implementation accepts a single adapter but ignores `models`. As a result,
`Model.compute` getters and computers are never applied to documents — they don't reach
components. `task.createdAtDisplay` is `undefined` at runtime.

---

## User-Facing Feature

> "I define a model with a `createdAtDisplay` getter and an `isAssignedTo(user)` method.
> When a task arrives in the component, both are available directly on the task object —
> no manual formatting, no utility imports."

---

## Decision

### Store accepts models per collection

`createStore` is updated to accept multiple named backing stores, each with its own
`models` map:

```ts
export const store = createStore({
  default: {
    adapter: MemoryAdapter({ tasks: [...] }),
    models:  { tasks: TaskModel, sprints: SprintModel },
    mutates: { archiveTask, moveTask },
  },
  local: {
    adapter: NSUserDefaultsAdapter(),
    models:  { settings: SettingsModel },
    mutates: { setTheme },
  },
})
```

The routing rule: a document's path prefix determines which backing store owns it.
`tasks/*` → default, `settings/*` → local. `ui/*` always routes to a session-scoped
MemoryAdapter that is never persisted.

### Enrichment via `Object.defineProperties`

When a document exits the cache (via `getCache()` or an adapter `onChange` event), the
store looks up the model for that document's collection and applies its `compute` object:

```ts
function enrich(doc: Doc, compute: object): Doc {
  return Object.defineProperties(
    Object.assign(Object.create(null), doc),
    Object.getOwnPropertyDescriptors(compute),
  )
}
```

`Object.getOwnPropertyDescriptors` preserves getter/setter descriptors as live
accessors — they are not called at assignment time. `this` inside a getter refers to
the enriched document, so `get createdAtDisplay() { return new Date(this.createdAt)... }`
works correctly.

**Computers (methods)** are also property descriptors on the compute object. They land
on the document as methods. They must be called as `task.isAssignedTo(user)`, not
destructured — destructuring loses the `this` binding in strict mode.

Rule for components and agent docs: computers are always called as methods on the
document, never as standalone references:

```ts
// Correct
task.isAssignedTo(currentUser)

// Wrong — this === undefined in strict mode
const { isAssignedTo } = task
isAssignedTo(currentUser)
```

### Schema validation on write

`createStore` validates each write descriptor's `fields` against the model's JSON Schema
before passing it to the adapter. A write that violates the schema throws synchronously
(before the optimistic update), surfaces in the `errors` collection, and is not added
to the history log.

```ts
// Throws at write time — never reaches the adapter
archiveTask({ id: 'tasks/task-1', status: 42 })
// store.errors gains: { action: 'ArchiveTask', error: 'status must be string', ... }
```

### `addStore` for runtime registration

Post-construction backing stores can be added:

```ts
store.addStore('mongo', {
  adapter: MongoAdapter(client),
  models:  { users: UserModel },
  mutates: { updateUser },
})
```

Documents under `users/*` are now routed to the mongo backing store.

---

## Consequences

- Components receive enriched documents with compute getters and methods already applied.
- No utility imports in components for formatting or derived values.
- `this` binding in computers requires method-call style (`doc.method(arg)`) — must be
  enforced in agent instructions and docs.
- Schema validation at write time catches type mismatches before they reach the adapter.
- Multiple backing stores allow Keychain, NSUserDefaults, and remote adapters to coexist
  with independent model and mutate registries.
- Enrichment adds one `Object.defineProperties` call per document per subscribe event —
  negligible for document-sized payloads (< 100 fields).
