# fiskal-pure

Anti-fragile state management for TypeScript/React and Swift/SwiftUI.

Every write is a named, serializable descriptor. The full action log is the full app history — replayable from any point, shippable to a server on failure. Components have zero imports from the library; all wiring is external and structurally enforced.

See the [spec](specs/adr-0001-core-store-action-log-3pt.md) for full design rationale.

---

## Installation

**TypeScript**

```sh
npm install @fiskal/pure-ts
```

**Swift**

```sh
swift package add https://github.com/fiskal/fiskal-pure --branch main
```

---

## Quickstart — TypeScript

```ts
import { createStore, createMutate, useRead } from '@fiskal/pure-ts'
import { MemoryAdapter } from '@fiskal/pure-ts/adapters/memory'

const store = createStore(MemoryAdapter())

const addTask = createMutate(store, {
  write: ({ id, title }) => ({ collection: 'tasks', id, fields: { title, status: 'active' } }),
})

const tasks = useRead(store, { collection: 'tasks', where: { status: 'active' } })
```

## Quickstart — Swift

```swift
import FiskalPure

let store = PureStore(adapter: MemoryAdapter())
let write = WriteDescriptor(collection: "tasks", id: "t1", fields: ["title": "Ship it", "status": "active"])
try await store.write(write)
let tasks = store.readAll(collection: "tasks")
```

---

## Running the demos

**TypeScript demo**

```sh
npm install
npm run dev --workspace=apps/ts-demo
```

**Swift demo**

```sh
cd apps/swift-demo
swift run
```
