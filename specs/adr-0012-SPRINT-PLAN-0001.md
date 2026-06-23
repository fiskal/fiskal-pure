# ADR-0012: Sprint Plan 0001

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 38pt

---

## Context

Sprint 0001 is the **Foundation Sprint** for fiskal-pure. After this sprint, a developer can install `stateless-ui` (TypeScript) or `StatelessUI` (Swift Package Manager), create a store backed by `MemoryAdapter`, declare mutates (write-only, read-then-write, atomic transaction), and subscribe to live data with `useRead` (React hook) or `@Query` (Swift property wrapper). All four production adapters — Firestore, GunJS, CloudKit, and NSUserDefaults — are implemented, tested, and documented. The library ships zero side effects in its core layer; every adapter is swappable for a fake at test time.

---

## ADRs in this Sprint

- **adr-0001-package-setup-2pt** — Monorepo layout, package names (`stateless-ui` / `StatelessUI`), build tooling (tsup + SPM), CI smoke test, README quickstart.
- **adr-0002-store-primitive-4pt** — `createStore(adapter, schema)` factory. Adapter interface contract. Cache layer (immutable snapshots). Subscription fanout. Cache invalidation rules.
- **adr-0003-memory-adapter-2pt** — `MemoryAdapter`: in-process key-value store. Subscribe, write, atomic batch. Primary adapter for tests and local-only apps.
- **adr-0004-create-mutate-3pt** — `createMutate({ action, read?, write })` factory. Three call forms: write-only, read-then-write, transaction array. Execution contract.
- **adr-0005-optimistic-rollback-3pt** — Optimistic cache writes before remote dispatch. Snapshot restore on failure. Reconcile re-render on server diff. No caller-side rollback code.
- **adr-0006-use-read-ts-3pt** — `useRead(store, query)` React hook. Single-doc, collection, where filter, fields projection. Loading / not-found / error states. Suspense-compatible.
- **adr-0007-query-swift-3pt** — `@Query(store:, query:)` SwiftUI property wrapper. Same query shape as TS. Publishes to `@State` via `Combine`. Loading / not-found / error states.
- **adr-0008-firestore-adapter-5pt** — `FirestoreAdapter`. Subscribe via `onSnapshot`. Write via `setDoc` / `updateDoc` / `runTransaction`. Mock Firestore injected at construction time.
- **adr-0009-gun-adapter-4pt** — `GunAdapter`. Subscribe via `gun.get().on()`. Write via `gun.get().put()`. P2P relay config. Peer reconnect on drop.
- **adr-0010-cloudkit-adapter-5pt** — `CloudKitAdapter` (Swift). Subscribe via `CKSubscription` + push. Write via `CKModifyRecordsOperation`. Query predicate mapping. Private / shared zone support.
- **adr-0011-userdefaults-adapter-3pt** — `NSUserDefaultsAdapter` (Swift). Key-value read/write. Notification-based subscribe (`UserDefaults.didChangeNotification`). App group support for widget sharing.

---

## Gherkin Coverage

### Core domain
- `_tdd/core/store.feature` — `createStore` lifecycle, cache behavior, subscription fanout, invalidation
- `_tdd/core/mutate.feature` — `createMutate` all three call forms, optimistic writes, rollback
- `_tdd/core/query.feature` — `useRead` / `@Query` single-doc, collection, filters, projections, loading states

### Adapters domain
- `_tdd/adapters/memory.feature` — `MemoryAdapter` subscribe, write, atomic ops, isolation
- `_tdd/adapters/firestore.feature` — `FirestoreAdapter` subscribe, write, transaction (mock Firestore)
- `_tdd/adapters/gun.feature` — `GunAdapter` subscribe, write, P2P sync, peer reconnect
- `_tdd/adapters/cloudkit.feature` — `CloudKitAdapter` subscribe, write, query predicate, zone support
- `_tdd/adapters/userdefaults.feature` — `NSUserDefaultsAdapter` key-value, notification subscribe, app group

Total: 8 feature files, ≥ 64 scenarios (≥ 3 Tier-1 happy-path + ≥ 2 Tier-2 edge cases per file, many files exceed minimums).

---

## Test Files

All tests written at plan time. All set to **skip**. Unskip one ADR at a time in Step 3.

### Parallel tests (hermetic, business logic)

**TypeScript (`packages/stateless-ui/src/__tests__/parallel/`)**
- `store.test.ts` — `createStore` factory, cache snapshots, subscription fanout, cache invalidation (adr-0002)
- `memory-adapter.test.ts` — `MemoryAdapter` write, subscribe, atomic batch, isolation (adr-0003)
- `mutate-write-only.test.ts` — write-only mutate: payload flows to adapter, cache updated (adr-0004)
- `mutate-read-then-write.test.ts` — read-then-write: cache read first, descriptor produced (adr-0004)
- `mutate-transaction.test.ts` — atomic batch: all-or-nothing commit, rollback on partial failure (adr-0004)
- `optimistic.test.ts` — optimistic apply, remote confirm, snapshot restore on error (adr-0005)
- `use-read.test.ts` — single-doc, collection, where filter, fields projection, loading states (adr-0006)
- `firestore-adapter.test.ts` — subscribe, write, transaction with FakeFirestore (adr-0008)
- `gun-adapter.test.ts` — subscribe, write, P2P relay config with FakeGun (adr-0009)

**Swift (`Tests/StatelessUITests/Parallel/`)**
- `StoreTests.swift` — `Store` init, cache snapshots, subscription fanout (adr-0002)
- `MemoryAdapterTests.swift` — write, subscribe, atomic ops (adr-0003)
- `MutateTests.swift` — all three call forms (adr-0004)
- `OptimisticTests.swift` — optimistic apply, rollback (adr-0005)
- `QueryPropertyWrapperTests.swift` — `@Query` loading, not-found, error states (adr-0007)
- `CloudKitAdapterTests.swift` — subscribe, write, predicate mapping with FakeCKDatabase (adr-0010)
- `NSUserDefaultsAdapterTests.swift` — read/write, notification-based subscribe, app group (adr-0011)

### Sequential tests (cannot parallelize — shared process state)

**TypeScript**
- `gun-p2p-sync.test.ts` — multi-peer sync: peer A writes, peer B subscribes; must run serial to avoid port conflicts (adr-0009)

**Swift**
- `UserDefaultsNotificationTests.swift` — `UserDefaults.didChangeNotification` fires across test cases; shared notification center requires isolation (adr-0011)

### UI / integration tests (Gherkin-driven)

**TypeScript (Playwright + playwright-bdd)**
- `e2e/store-create.spec.ts` — step definitions for `store.feature` happy paths
- `e2e/mutate.spec.ts` — step definitions for `mutate.feature`
- `e2e/query.spec.ts` — step definitions for `query.feature`

**Swift (XCTest + Cucumberish)**
- `UITests/StoreFeatureSteps.swift` — step definitions for `store.feature`
- `UITests/QueryFeatureSteps.swift` — step definitions for `query.feature`
- `UITests/CloudKitFeatureSteps.swift` — step definitions for `cloudkit.feature`

### Manual tests

- `_tdd/adapters/gun.feature` — scenarios tagged `[MANUAL]` for physical multi-device P2P relay verification
- `_tdd/adapters/cloudkit.feature` — scenarios tagged `[MANUAL]` for production CloudKit subscription delivery (requires real device + provisioning)

---

## Risks

| Risk | Mitigation | ADR |
|---|---|---|
| GunJS has no TypeScript typings; community types are incomplete | Vendor a minimal hand-written `.d.ts`; keep surface area small (get/put/on only) | adr-0009 |
| CloudKit subscription delivery requires APNs entitlement — not available in simulator | Split CloudKit tests: hermetic fake for unit tests, `[MANUAL]` for push delivery | adr-0010 |
| `@Query` property wrapper must publish on main thread; background CK callbacks may cause SwiftUI warnings | Dispatch all `@Query` publisher updates to `DispatchQueue.main` in adapter wrapper | adr-0007 + adr-0010 |
| Firestore `onSnapshot` may fire duplicate events on reconnect; subscribers must be idempotent | Cache snapshot diffing before fanout; if value unchanged, do not notify subscribers | adr-0002 + adr-0008 |
| GunJS P2P sync convergence time is non-deterministic; test flakiness likely | Use FakeGun for all unit tests; real relay only in `[MANUAL]` scenarios with generous timeouts | adr-0009 |
| `NSUserDefaultsAdapter` app-group suite name must match entitlement; mismatch is silent | Assert suite != nil in adapter init; fail fast with a clear error message | adr-0011 |
