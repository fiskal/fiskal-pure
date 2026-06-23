# fiskal-pure Product Context

---

## What it is

An anti-fragile state management library for TypeScript/React and Swift/SwiftUI.

Every state change is a named, serializable write descriptor. The full action log is the full
app history — replayable from any point, shippable to a server on failure. When something breaks,
you don't ask "what was the user doing?" — you read the log.

The architecture enforces separation structurally. Components have zero imports from the library.
All wiring is external. There is no API available inside a component to touch the store.
AI agents and developers cannot mix logic into views because the wrong code won't compile.

---

## The five primitives

| Primitive | What it does |
|---|---|
| `createStore` | One store per app. Registers adapters, models, mutates. |
| `Model` | JSON Schema + compute getters + migration history for an entity. |
| `createMutate` | Declares a named write as a plain data descriptor. |
| `wireView` | Connects a pure component to the store. Wiring lives outside the component. |
| `Adapter` | Protocol: subscribe + write. Swap MemoryAdapter → Firestore/CloudKit via config. |

---

## wireView is the only connection point

Components are pure functions/structs. They have no store knowledge. They receive props and render.

`wireView` is declared outside the component file at the app or route boundary. It is the only
sanctioned way to connect a component to live data. All query logic and all action bindings live
in the wire declaration, not the component.

The same pure component can be wired multiple times to different queries — no component changes
required. This eliminates the smart/dumb component distinction entirely. All components are dumb.

```ts
// Component — no store imports, no hooks, just props
function TaskItem({ task, archiveTask }) { ... }

// Wire — outside the component file
wireView('TaskItem',
  ({ taskId }) => ({ task: { path: 'tasks', id: taskId } }),
  ['archiveTask'],
  TaskItem,
)

// Same component, different data
wireView('ArchivedTaskItem',
  ({ taskId }) => ({ task: { path: 'archived-tasks', id: taskId } }),
  ['restoreTask'],
  TaskItem,  // exact same component
)
```

---

## Action log = app history

Every write is a descriptor: `{ action: string, write: WriteDescriptor, at: timestamp }`.
The log is append-only, serializable, and shippable.

- **Debugging:** ship the log on error — no reproduction steps needed
- **Time travel:** `store.history.back()` / `.goto(index)` — restore any past state in O(1)
- **Auto-healing:** restore from last known-good snapshot on detected failure
- **Anti-fragile:** each failure improves the system — the log contains everything needed to fix it

---

## MemoryAdapter is the default

Not a test fake. The primary adapter. Start with MemoryAdapter — works immediately, zero config.
Swap to Firestore, CloudKit, or GunJS by changing one line in `createStore`. Components, queries,
and mutates are unchanged. Tests run against MemoryAdapter — no mocks, no providers, no setup.

---

## Backing stores

| Adapter | Language | Notes |
|---|---|---|
| MemoryAdapter | TS + Swift | Default. In-process. Full atomic op support. |
| FirestoreAdapter | TypeScript | Real-time via onSnapshot. Atomic ops via FieldValue. |
| GunAdapter | TypeScript | P2P CRDT. Client-side filtering. |
| CloudKitAdapter | Swift | CKRecord-based. Polling for collections. |
| NSUserDefaultsAdapter | Swift | Key-value only. Local only. |

---

## Anti-fragile = beyond observability

Observability tells you what broke. Anti-fragile means failures make the system stronger:

1. Failure occurs → action log + snapshot shipped to server
2. Engineer replays the exact sequence → root cause found without guessing
3. Fix deployed
4. Same failure detected at runtime → store restores from pre-failure snapshot automatically
5. The failure never reaches the user again

---

## Named personas (for Gherkin scenarios)

Use the task-management domain from the spec for all scenarios:

| Name | Role | Use case |
|---|---|---|
| Alex | Solo developer | Adds wireView declarations to wire a task list to live data |
| Priya | Team lead | Ships a bug; uses action log replay to find root cause in minutes |
| Sam | Agent (AI) | Generates a pure component; wireView call is separate; no logic leaks |
| Jordan | QA engineer | Tests components with plain props — no store, no providers, no setup |
