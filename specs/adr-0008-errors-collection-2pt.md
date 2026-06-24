# ADR-0008: Errors as a Root-Level Collection

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

When a write fails (network error, permission denied, schema violation, adapter rejection),
the failure is currently unobservable from the UI except by catching the returned Promise.
This means:

- Toast notifications require try/catch in every call site
- No component can reactively observe "is this action currently failing?"
- "Permission denied" and "not found" are both represented as `null` — indistinguishable
- There is no centralised record of in-flight failures

---

## User-Facing Feature

> "If my archive fails, I want to see 'Failed to archive — tap to retry' without writing
> error handling in the component. If the error is a permissions problem, I want to know
> that specifically."

---

## Decision

### Errors are values in the store, not thrown exceptions

A write failure writes a plain error document to the store's `errors` collection.
This keeps errors as data — subscribable, filterable, dismissible — consistent with
the library's FP principles.

```
errors/ArchiveTask-1750000060  →  {
  id:         'errors/ArchiveTask-1750000060',
  action:     'ArchiveTask',
  kind:       'permission' | 'network' | 'validation' | 'conflict' | 'unknown',
  message:    'Missing or insufficient permissions.',
  payload:    { id: 'tasks/task-1' },
  writes:     [{ id: 'tasks/task-1', fields: { status: 'archived' }, merge: true }],
  at:         1750000060,
  resolved:   false,
}
```

`kind` is derived from the adapter's error signal:
- `permission` — HTTP 403 / Firestore permission denied / CloudKit CKError.permissionFailure
- `network` — no connectivity / timeout
- `validation` — schema violation caught before the adapter
- `conflict` — concurrent write rejected by the server
- `unknown` — anything else

### Contextual scoping — any component can subscribe

Because errors are documents in the store, any wired component subscribes to the subset
it cares about using the standard query system:

```ts
// Subscribe to all unresolved errors
wireView('ErrorBanner',
  { errors: { collection: 'errors', where: { resolved: false } } },
  ['dismissError'],
  ErrorBanner,
)

// Subscribe to errors from a specific action
wireView('ArchiveButton',
  ({ taskId }) => ({
    task:  { id: taskId },
    error: { collection: 'errors', where: { action: 'ArchiveTask', resolved: false } },
  }),
  ['archiveTask', 'retryError'],
  ArchiveButton,
)
```

A global `WiredErrorBanner` at the app root handles all unresolved errors by default.
Individual components can also subscribe to action-scoped or collection-scoped errors
to show inline failure states.

### Error lifecycle

```
write fails
  → optimistic cache rolled back (pre-write snapshot restored)
  → errors/ArchiveTask-{timestamp} written to store
  → all subscribers to 'errors' collection notified
  → WiredErrorBanner re-renders, shows "Archive failed"

user taps "Retry"
  → retryError({ id: 'errors/ArchiveTask-{timestamp}' }) called
  → error's writes re-applied to the adapter
  → on success: error document deleted, all subscribers notified
  → on second failure: error updated with new timestamp, resolved: false

user taps "Dismiss"
  → dismissError({ id: '...' }) sets resolved: true
  → error disappears from all { where: { resolved: false } } subscribers
```

### Errors do NOT appear in `store.history.log()`

The write that failed was rolled back. It did not change the committed state.
`store.history` only records confirmed writes. The `errors` collection is a separate
accountability mechanism for failures, not a history record.

### The three-state contract is unchanged

wireView's three states for data (`undefined` loading / `null` not found / `Doc` data)
remain unchanged. A query that returns `null` means "not found" — not "error".
The `error` for the most recent write can always be read via a separate `errors` query.

This keeps components simple: the data query tells you about the document;
the errors query tells you about the last write attempt. They are independent concerns.

### `kind: 'permission'` vs `kind: 'network'`

Components can branch on `error.kind`:

```ts
const ArchiveButton = ({ task, error, archiveTask, retryError }) => (
  <div>
    <button onClick={() => archiveTask({ id: task.id })}>Archive</button>
    {error && error.kind === 'permission' && <p>You don't have permission to archive this task.</p>}
    {error && error.kind === 'network'   && <button onClick={() => retryError({ id: error.id })}>Retry</button>}
  </div>
)
```

---

## Consequences

- Every write failure is observable from any component in the UI — no try/catch required.
- Errors are contextually scoped via the query system — the same mechanism used for all data.
- Retry is a first-class operation (`retryError` mutate) with no special-casing.
- `store.history.log()` remains clean — only confirmed committed writes appear.
- The `errors` collection is always local-only (routes to a session-scoped MemoryAdapter).
  On page refresh, error state clears. Errors are not persisted or synced.
- PII risk: the `payload` and `writes` fields in an error document may contain sensitive
  data. If `errors` documents are ever shipped to a server for analytics, apply the same
  redaction rules as the history log.
