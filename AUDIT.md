# Antifragile Audit

`fiskal-antifragile` is a cross-platform state library (TypeScript/React + Swift/SwiftUI) built on a single discipline: views are pure functions of props with zero library imports, all state and logic live in a store, every write is a named serialisable descriptor logged for replay, and `wireView` is the only connection point — injecting data and mutations as plain props. The library builds clean on both platforms and its TypeScript test suite is green (74/74 after this audit, up from 69), but that green baseline masked a set of load-bearing defects whose blast radius only appears with real (async/remote) adapters and on the Swift path. The two most severe were platform-isolating: on Swift, the live cache yielded a hard-coded empty array to every subscriber on each mutation, blanking every wired view after the first frame; on TS, the advertised `firestore`/`gun` adapters were excluded from compilation yet still publicly exported, written against the pre-rename API, and would crash callers with `docs.map`. Cutting across both platforms, four architectural promises were unwired: schema validation was a documented no-op, the adapter never bridged back into the store cache, the time-travel replay log was non-functional, and the write/query contracts had drifted out of cross-platform lockstep. This audit raised 28 findings, confirmed 24, refuted 0, and landed fixes for the platform-critical and most cross-platform defects while leaving a clearly-scoped set of Swift feature enhancements deferred. The build is green and no fix was reverted.

---

## How the library works

The architecture is identical in shape on both platforms; only the host idioms differ.

**The wireView / useRead model.** A UI component is authored as a pure function of props with no library imports. `wireView` is the single connection point: given a registered component name, a query, and a set of action names, it produces a container that reads the queried docs from the store, runs them through `enrich`, and injects them — plus bound mutation closures — as plain props. On TS, `useRead` is the lower-level exported hook that the same container is built on; on Swift, the `@Query` property wrapper (`QueryWrapper`) and `WiredView` play the equivalent roles. Components never see the store, the cache, or any adapter — only data and actions as props.

**Cache and structural sharing.** The store owns a normalised in-memory cache keyed by `path → id → Doc`. Reads project and (on TS) structurally share: `selectDocs` returns the same array reference when contents are unchanged (`shallowEqual`), so React can bail out of re-renders. `enrich` materialises a model's `compute` closures onto each doc as plain properties — `(doc) => value` for simple derived fields and `(doc) => (sibling) => value` for dependent ones — eagerly assigned at read time so they are safe to destructure (no `this`).

**Mutate: optimistic + rollback.** A write is expressed as a `WriteDescriptor` (`path`, `id`, `fields`, optional `merge` defaulting to patch, optional `delete`) or an array of them for an atomic transaction. Atomic field operations (`::increment`, `::serverTimestamp`, `::arrayUnion`, `::arrayRemove`) are carried as sentinel values. `mutate` applies the descriptor optimistically to the cache, notifies subscribers, then awaits `adapter.write`. On remote failure it rolls the cache back and records an `errors/` doc classified by `ErrorKind`.

**History / antifragility.** The headline premise is that every write is a named, serialisable descriptor logged for replay, enabling time-travel (back/forward/goto). The log structure and cursor navigation exist; on Swift the entries carry the descriptors but no cache snapshot, and on TS the `store.history` surface is absent entirely (see F-14).

**Adapters.** The store talks to pluggable adapters implementing `subscribe` + `write` (Swift adds an optional one-shot `query`). TS ships `MemoryAdapter` (working, synchronous) plus excluded `firestore`/`gun` stubs. Swift ships `MemoryAdapter`, `CloudKitAdapter`, and `NSUserDefaultsAdapter` (App-Group widget sharing). Adapters are meant to be transport-only; consumers own actor/main-thread hops.

---

## Audit method

Six principal architect lenses each reviewed the codebase independently, then findings were correlated and adversarially verified:

1. **TS Core** — cache, mutate, structural sharing, optimistic rollback.
2. **TS API** — public types, store construction, README/contract fidelity.
3. **TS React** — `useRead`/`wireView` runtime, React 18 concurrency, memoisation.
4. **Swift Core** — `Cache`, `Store`, `History`, value-type model, Sendable.
5. **Swift SwiftUI** — `WireView`, `QueryWrapper`, task lifecycle, view identity.
6. **Swift Adapters** — `MemoryAdapter`, `CloudKitAdapter`, `NSUserDefaultsAdapter` vs. Gherkin contracts.

Findings that two or more lenses raised independently were marked as consensus. Every finding then went through an **adversarial verification pass**: a reviewer attempted to *refute* each claim by reading the cited source lines, checking whether the bug was live or latent, and recalibrating severity. **28 findings were raised, 24 were confirmed (verified directly in source), 0 were refuted.** Several severities were adjusted downward during verification where the defect proved latent (gated behind dead code) rather than live, and a few were escalated where a single-lens "info" finding proved to be a real cross-platform gap.

---

## Findings

| ID | Severity | Platforms | Area | Status |
|----|----------|-----------|------|--------|
| F-01 | critical | swift | react-runtime | **Fixed** |
| F-02 | high | ts | validation | **Fixed** |
| F-03 | high | ts | adapter | **Fixed** (rewrite + exports/anti-rot) |
| F-04 | high | ts | adapter | **Fixed** (conform + consumer guards) |
| F-05 | high | ts, swift | concurrency | Deferred (architectural) |
| F-06 | high | swift, ts | concurrency | Deferred (Swift) |
| F-07 | medium | ts | parity | **Fixed** |
| F-08 | high | ts | react-runtime | **Fixed** (core); items 3–5 deferred |
| F-09 | medium | ts, swift | react-runtime | **Fixed** (TS); Swift deferred |
| F-10 | high | swift | parity | Partial (Types) / Deferred (apply paths) |
| F-11 | medium | ts | correctness | **Fixed** (JSDoc); cache guards deferred |
| F-12 | high | swift | correctness | **Fixed** |
| F-13 | high | swift, ts | concurrency | Deferred (FieldValue enum) |
| F-14 | medium | swift, ts | correctness | Deferred (cross-file) |
| F-15 | high | swift | adapter | **Fixed** |
| F-16 | medium | swift | concurrency | **Fixed** (MemoryAdapter); rest deferred |
| F-17 | high | swift | memory-leak | **Fixed** |
| F-18 | high | swift | react-runtime | **Fixed** |
| F-19 | medium | swift, ts | api-design | **Fixed** |
| F-20 | high | swift, ts | parity | Deferred (product/contract call) |
| F-21 | high | swift | validation | **Fixed** |
| F-22 | medium | ts, swift | fp-purity | **Fixed** (TS enrich guard); clone deferred |
| F-23 | low | ts | react-runtime | **Fixed** |
| F-24 | medium | swift | react-runtime | **Fixed** |
| F-25 | low | swift | concurrency | Deferred (folds into F-01 + batching) |
| F-26 | low | ts | api-design | **Fixed** (type) / Deferred (threading) |
| F-27 | low | ts | docs | Doc (refresh README) |
| F-28 | info | ts, swift | docs | Doc (refresh GAPS/EDGE-CASES) |

### F-01 · Live cache subscribers received empty arrays on every change (critical, Swift) — Fixed

`Cache.notifySubscribers` and `Cache.restore` yielded a hard-coded `[]` to every registered `AsyncStream` continuation instead of re-running `get(query:)`. The continuation never captured its `Query`, so the cache could not re-evaluate per subscriber. Result: the UI showed correct data for one frame, then blanked on the first mutation and stayed blank — defeating the entire library on Swift. `MemoryAdapter` did fan-out correctly, so the two Swift paths disagreed internally.

**Fix** (`packages/swift/Sources/Antifragile/Core/Cache.swift`): the continuations registry now stores `(query, continuation)` tuples; `subscribe` retains the `Query`; `notifySubscribers(path:)` gates on `sub.query.path == path` and yields `get(query: sub.query)` (fixing both the empty-array bug *and* the over-fire fan-out the old inline comment admitted); `restore` re-evaluates every subscriber with its real result set. This also resolves the over-fire half of F-25.

### F-02 · Declared schema validation was never enforced (high, TS) — Fixed

`Model.schema` was documented (and README-advertised) as "JSON Schema used to validate writes before they reach the adapter," but nothing read it. `createMutate` applied the optimistic write and called `adapter.write` with zero validation — malformed docs entered the cache and remote store unchecked, violating CLAUDE.md's data-contract principle. Swift has no `schema` field, so this was TS-specific.

**Fix** (cross-file): added `models: Record<string, Model>` to `StoreInstance` (`types.ts`), exposed `models` on the store object (`store.ts`), added a pure `validateDoc(schema, fields)` in new `packages/ts/src/validate.ts` (type/properties/required/minLength/enum, skipping atomic sentinels and treating `::delete` as field removal), and added a validation loop in `mutate.ts` over non-delete descriptors **before** `applyWrites` — on failure it records a `validation`-classified ErrorDoc and throws before the cache is touched. Exported from `index.ts`. 5 new tests landed in `__tests__/mutate.test.ts`.

### F-03 · Dead, broken `firestore.ts`/`gun.ts` were publicly exported (high, TS) — Fixed

`tsconfig.json` excluded both files, so the green tests never compiled them. Both were written against the old API (`collection` not `path`, `data` not `fields`, non-existent `WriteOperation`/`isWriteOp`, `op['value']` singular, `query.kind`/`orderBy`/`limit`). Yet `package.json` still exported `./adapters/firestore` and `./adapters/gun` at never-emitted dist paths — a consumer import yields module-not-found. `gun.ts` additionally downgraded `::increment`/`::arrayRemove` (data loss).

**Fix**: rewrote `firestore.ts` to compile against the current contract (`WriteOp`/`isAtomicOp`, `path`, `fields`, `merge`-default semantics, `delete`, plural `values`/`n`). Renamed the 3 stale `collection` references in `gun.ts` to `path` and added loud `console.warn` on the lossy coercions. Removed the broken `./adapters/firestore` and `./adapters/gun` exports from `package.json` (they pointed at files never produced because they need optional peer deps `firebase`/`gun`).

### F-04 · Firestore adapter delivered `null`/single Doc to `Doc[]` callbacks (high, TS) — Fixed

The `OnChangeCallback` contract guarantees `Doc[]`, but `FirestoreAdapter.subscribe` emitted `onChange(null)` and a single bare `Doc` for doc queries — `null.map`/`data.map` TypeError. This was the runtime face of F-03.

**Fix**: `subscribe` now conforms — missing doc emits `onChange([])`, found single doc is wrapped `onChange([data])`, doc-vs-collection branches off `query.id`. Added defense-in-depth `Doc[]` coercion guards in the subscribe callbacks of `react/wireView.ts` and `useRead.ts` so a buggy custom adapter can't crash `enrich`/`map`.

### F-05 · Store cache is never synced from the adapter (high, TS + Swift) — Deferred

There is no bridge from `adapter.subscribe` back into the store cache on either platform. TS: the store cache is written only by the optimistic mutate path; the adapter pushes data straight into component-local `useState`. Consequences: async adapters render a stale/empty first frame, and read-then-write mutates compute against only locally-mutated docs. Swift: the UI subscribes to `store.cache` while writes persist through `config.adapter.write`; adapter-computed values never reach the cache, and `Store.adapterSubscriptions` is declared but dead.

**Deferred** — this is a coordinated architectural change touching `store.ts`, `useRead.ts`, `wireView.ts`, and `mutate.ts` (TS) plus `Store.swift`/`WireView.swift`; a half-fix would add a third divergent cache. MemoryAdapter is synchronous and the optimistic path keeps tests green, so the gap is invisible today and bites only with async/remote adapters. Pick one authoritative cache: the Store subscribes each adapter on init and feeds `onChange` docs back into the cache, with both read paths routed through one shared `readDocs(store, query)` helper.

### F-06 · Optimistic rollback uses a whole-cache snapshot (high, Swift + TS) — Deferred (Swift)

Both platforms snapshot the entire cache before a mutate and restore it on failure. The `await adapter.write` is a suspension point where a concurrent mutate B can commit; if A fails, restore rewinds the whole cache, discarding B. The snapshot is also O(total docs) and (on TS) shallow, so nested data shares references.

**Deferred** — the Swift fix needs `Cache`/`Types` changes (read prior docs, a full-doc-replace path, a remove-previously-absent API) outside a single-file scope. Roll back per-document: capture only the touched docs' prior values; on failure re-apply just those. Reserve full snapshots for explicit time-travel checkpoints (F-14).

### F-07 · `useRead` never enriched docs (medium, TS) — Fixed

`wireView` ran every doc through `store.enrich`; `useRead` did not, so the same query returned compute properties through one path and `undefined` (silently) through the other.

**Fix** (`useRead.ts`): added a shared `readDocs` helper that enriches via `store.enrich` before projection and routed both read paths through it.

### F-08 · Read paths were tearing-prone (high, TS) — Fixed (core)

Both reads used `useState`+`useEffect`(subscribe) — the pattern React 18's `useSyncExternalStore` replaces — risking tearing under concurrent rendering and double-subscribing in StrictMode. The `useRead`/`wireView` id-presence semantics also disagreed (`query.id` truthy vs. `id !== undefined`).

**Fix** (`useRead.ts`): reimplemented on `useSyncExternalStore` with a referentially-stable `getSnapshot` (cached shaped value reused when raw docs are unchanged — this also fixed a "Maximum update depth exceeded" regression caught by the gate), unified id semantics to `id !== undefined`, and an `idKey` sentinel distinguishing `id:''` from absent-id. Deferred: a shared key-sorted serializer reused by `wireView` (item 3), converting `wireView`'s container to `useSyncExternalStore` (item 4), and documenting the adapter's synchronous-first-delivery requirement (item 5).

### F-09 · `wireView` had no loading state (medium, TS + Swift) — Fixed (TS)

The 3-state read contract (undefined=loading, null=not-found, Doc/Doc[]=loaded) was violated by `wireView`, which seeded `null`/`[]` for missing data — collapsing loading into loaded-empty. Swift was worse: `QueryWrapper` is a single `T?` and `WiredView.data` starts `[:]`.

**Fix** (`react/wireView.ts`): widened `data` to allow `undefined` and reworked the initializer to seed `undefined` (loading) when a doc/collection is absent, resolving to `null`/`[]`/Doc only after the first subscribe callback. Deferred: centralising the contract type in `types.ts` and the entire Swift `Loadable<T>` side.

### F-10 · Swift Write/AtomicOp is an incomplete port (high, Swift) — Partial / Deferred

The Swift descriptor lacks `merge:false`/`delete` (so a caller can never replace or delete a whole doc), and models array ops as single-element rather than variadic — so "add three tags" is one descriptor on TS but three on Swift, voiding 1:1 replay parity.

**Partial fix** (`Core/Types.swift`): added `merge: Bool = true` and `delete: Bool = false` to `Write` (additive, all call sites compile). **Deferred**: changing `arrayUnion`/`arrayRemove` to `[AnyHashable]` and the delete/merge apply logic touches `Cache.swift`, all three adapters, and test call sites.

### F-11 · `merge` JSDoc inverted; replace path lets `fields.id` diverge (medium, TS) — Fixed (JSDoc)

The public JSDoc documented the old `merge = false` default while the implementation patches by default. Separately, `applyFields` writes `next[key]=value` for any key including `id`, so a descriptor with `id:'a'`/`fields.id:'b'` produces a doc keyed under 'a' whose `.id` is 'b'. Array dedup also uses reference identity, not deep value-equality.

**Fix** (`types.ts:68-71`): corrected the JSDoc to "merge defaults to true (patch); pass `merge:false` to fully replace." **Deferred** (cache.ts): force `nextDoc.id = desc.id`, and decide/document the array-op equality rule and mirror it in Swift.

### F-12 · Writes to unrouted paths silently never persisted (high, Swift) — Fixed

`Store.mutate` persists a write only to configs whose `models` array contains the write's path. With `models` defaulting to `[]`, a write to an unowned path was applied optimistically and appended to history but **never sent to any adapter** — silent offline-first data loss surviving until restart.

**Fix** (`Core/Store.swift`): added `StoreError.unroutedWrite(paths:)` and a guard that computes `ownedPaths` and throws if any write path is unowned, reusing the existing catch (which rolls back and records an `errors/` doc). `classifyError` returns `"configuration"` for it. The internal `errors` path stays exempt (only written via `applyWrite` inside the catch).

### F-13 · `Any`-typed fields: unsound Sendable, increment reset, timestamp divergence, JSON-drop (high, Swift + TS) — Deferred

`Doc = [String: Any]`; `Write`/`CacheSnapshot` are declared `Sendable` while storing `Any` (unsound under Swift 6). This keystone causes: Int-stored counters cast-fail on `as? Double` and reset to the delta; `serverTimestamp` stored as three runtime types across adapters; and `NSUserDefaults` `try? JSONSerialization` silently dropping non-JSON writes.

**Deferred** — adopt a closed `Sendable` value enum (`enum Value { case string, number, bool, date, array, map, null }`) as the canonical Doc field model on both platforms. This redefinition breaks every `[String: Any]` consumer and must land coordinated across `Cache.swift`, all three adapters, and the TS cache.

### F-14 · Time-travel replay log non-functional (Swift) / absent (TS) (medium, both) — Deferred

The headline "every write is logged for replay" is unimplemented. Swift `HistoryEntry` holds no `CacheSnapshot` and navigation doesn't touch the cache; TS `store.history` doesn't exist at all (README references it 10+ times — every call would throw).

**Deferred** — `History.swift` is already correct (navigation returns the entry). The work is cross-file: add `snapshot: CacheSnapshot` to `HistoryEntry` (`Types.swift`), capture it in `Store.mutate`, add Store-level `undo/redo/goto` calling `cache.restore`, and on TS implement or remove `store.history`.

### F-15 · CloudKitAdapter was a thin fetch/save shim (high, Swift) — Fixed

Three Gherkin-contract failures: polling not push (up to 30s latency, no zones), no conflict handling (fresh `CKRecord` + `.changedKeys` clobbers and throws on `serverRecordChanged`), and no offline retry queue (violating offline-first).

**Fix** (`CloudKitAdapter.swift`): added a configurable `zoneID` threaded through all record IDs and the collection fetch; `registerSubscription` saves a `CKQuerySubscription` with polling kept as explicit fallback; writes route through a shared `save` that fetches the existing record for its change tag, uses `.ifServerRecordUnchanged`, and on `serverRecordChanged` re-applies onto the server record (server-wins) and on `partialFailure` resolves per-record; an in-process `actor PendingWriteQueue` enqueues on network errors without throwing and drains on the next write. (Disk-durable cross-process queue remains unimplemented — the current init takes no persistence path.)

### F-16 · Swift adapter delivery contract unspecified (medium, Swift) — Fixed (MemoryAdapter)

Five lifecycle/delivery bugs sharing one missing contract: registration race (lost update), over-fire (`NSUserDefaults` suite-wide observer), off-main-actor delivery, and leak on dropped cancel.

**Fix** (`MemoryAdapter.swift`): added an atomic `MemoryState.subscribe(id:query:onChange:)` that registers and returns the snapshot in one isolated step (register-then-emit), closing the lost-update race; documented the delivery contract. **Deferred**: the AsyncStream/`onTermination` protocol refactor (`Types.swift`), the `NSUserDefaults` over-fire dedup, and the CloudKit MainActor hop.

### F-17 · WiredView leaked its subscription Task on disappear (high, Swift) — Fixed

`subscribeToQueries` spawned a *new* unstructured `Task { withTaskGroup ... }` not parented to `.task`, so SwiftUI's auto-cancellation never reached it; the infinite `for await` loops ran forever after the view was removed, writing into dead `@State`.

**Fix** (`WireView.swift`): dropped the nested `Task`, run `withTaskGroup` inline so it's a structured child of `.task`, and switched to `.task(id: queriesKey)` so it re-subscribes only when the query set changes. Removed the `@State subscriptionTask`.

### F-18 · QueryWrapper re-subscribed on every graph evaluation (high, Swift) — Fixed

`DynamicProperty.update()` (called before every body eval) unconditionally cancelled and rebuilt the subscription with a new UUID continuation — any unrelated parent re-render churned the subscription, causing flicker and transient continuation accumulation.

**Fix** (`Query.swift`): added `@State lastQuery` and an early-return guard — only cancel+resubscribe when the resolved query actually differs. `Query` is already `Equatable`, so the fix is self-contained.

### F-19 · Unknown action silently no-ops (medium, Swift + TS) — Fixed

A typo'd/unregistered action silently succeeded with no write, error, or history entry — a correctness hole for a replay library.

**Fix**: Swift `Store.dispatch` now throws `DispatchError.unknownAction(action)` instead of falling through (a self-contained enum, since no shared `AntifragileError` exists; documented first-wins on duplicate names). TS deferred to the registry hardening. (TS `wireView` keeps the `?? NOOP` stable fallback — see F-23 — and dev-warning is a follow-up.)

### F-20 · Query/Adapter shape diverged between platforms (high, both) — Deferred

Swift `Query.where` is structured clauses with 9 operators + `orderBy`; TS is equality-only `Record` with no `orderBy`. CloudKit/UserDefaults Swift adapters also ignore `clause.op`, so a `priority > 2` clause silently returns equality matches. No pagination on either side.

**Deferred** — this is a product/contract decision that gates adapter parity, pagination, and the dead-adapter rewrite. Define one canonical Query shape, mirror it on both platforms, and share one query-evaluation function across the three Swift adapters.

### F-21 · NSUserDefaultsAdapter silently fell back to `.standard` (high, Swift) — Fixed

`init` coalesced both a nil suite name and a failed `UserDefaults(suiteName:)` into `.standard` — in the App-Group widget use case, a typo'd suite routes writes to standard defaults while the widget reads an empty suite, invisibly.

**Fix** (`NSUserDefaultsAdapter.swift`): made `init(suiteName:)` throwing — guards non-nil, rejects a nil suite result, and removes the `.standard` fallback and the `= nil` default. Added `NSUserDefaultsAdapterError.invalidSuite` carrying the exact spec message.

### F-22 · Compute/error log not isolated from throws or aliasing (medium, TS + Swift) — Fixed (TS enrich)

`enrich` ran each compute closure with no try/catch, so one malformed doc crashed the whole list render. The TS error descriptor also embedded `writes`/`payload` by reference, so a later mutation could rewrite the logged record.

**Fix** (`store.ts`): wrapped each compute invocation in try/catch, degrading a single derived property to `undefined` on throw. **Deferred**: `structuredClone` of `payload`/`writes` in the mutate error descriptor (`mutate.ts`). The Swift mirror mostly does not apply (no `enrich`; error doc embeds only scalars).

### F-23 · Injected actions allocated fresh every render (low, TS) — Fixed

The only genuinely unstable injected prop was the `?? (async () => {})` missing-action fallback (real actions and views are already per-prop stable).

**Fix** (`react/wireView.ts`): hoisted a single module-scope `NOOP` and used `?? NOOP`.

### F-24 · Every wired Swift component force-erased through AnyView (medium, Swift) — Fixed

`wireView` required `(WireProps) -> AnyView`, erasing static view type so SwiftUI tears down and rebuilds the subtree on each data change instead of diffing by identity.

**Fix** (`WireView.swift`): made `wireView`/`WiredView` generic over `Content: View`; `body` returns the concrete `Content`. `AnyView` remains an opt-in escape hatch.

### F-25 · WiredView fans out N subscriptions rewriting the whole data dict (low, Swift) — Deferred

A downstream symptom of F-01's broadcast-to-all (now fixed by the path-gating half). The remaining batching concern — coalescing the per-query `data` dict updates into one transaction — is deferred.

### F-26 · `MutateSpec.write` untyped; wireView injects via unsafe casts (low, TS) — Fixed (type)

**Fix** (`types.ts:152-154`): made `MutateSpec<P>` generic with a default type param. **Deferred**: threading `P` through `createStore`/`createWireView` to remove the casts.

---

## Refuted claims

No findings were refuted outright — all 24 verified claims held against the source. The verification pass instead **recalibrated severity** rather than rejecting findings:

- **F-03 / F-04** were lowered from *critical* to *high*: real defects, but contained to opt-in adapters that never compiled and never shipped, so the green tests and the working MemoryAdapter path were unaffected. The live crash is gated behind first repairing the compile breakage.
- **F-07, F-09, F-23, F-24** were lowered to *medium/low*: F-07 only bites a store with compute models read through the exported hook; F-09 causes a brief empty-flash, not corruption, and is invisible with the synchronous default adapter; F-23's broad "breaks memoization" premise was narrowed to the single noop-fallback prop (real actions/views are already referentially stable); F-24 is a perf/idiom tax, not a correctness bug, and its blast radius was overstated until F-01 was fixed.
- **F-22's cross-platform claim was trimmed**: the TS enrich-throw and error-doc aliasing are real, but Swift has no `enrich` and its error doc embeds only scalars, so the Swift mirror mostly does not apply.

This shows the findings survived an adversarial read; what changed was honesty about live-vs-latent and blast radius.

---

## Edge cases & how the library handles them

- **Merge default.** Omitting `merge` patches existing fields (preserves untouched ones); `merge:false` fully replaces, dropping unset fields. TS implements this (F-11 JSDoc now matches); Swift gained the `merge`/`delete` fields (F-10) but the apply paths are still deferred.
- **Optimistic rollback.** On remote failure the cache is restored and an `errors/` doc is recorded. Today rollback is whole-cache, which can clobber a concurrent mutate (F-06, deferred) — per-document rollback is the prescribed fix.
- **Compute / enrich.** Closures `(doc) => value`, eagerly assigned as plain properties (safe to destructure). Now isolated from throws on TS (F-22) and applied on both read paths (F-07). A throwing closure degrades a single derived field rather than crashing the list.
- **Subscription cleanup.** Swift wired views now cancel their subscription task on disappear (F-17) and re-subscribe only on query change (F-18); the cache fan-out is path-gated (F-01). MemoryAdapter registers-then-emits atomically (F-16). The AsyncStream/`onTermination` protocol-level cleanup is deferred.
- **Concurrent writes.** Interleaving at the `await adapter.write` suspension point is a known hazard (F-06) — serialise mutate dispatch or roll back per-document.
- **Offline ordering.** CloudKit now queues writes on network errors without throwing and drains on the next write (F-15); cross-process disk durability is deferred. NSUserDefaults now fails fast on an invalid suite instead of silently writing to `.standard` (F-21).
- **Cross-platform parity.** The write/query contracts have drifted (F-10, F-13, F-20): variadic array ops, the canonical value model, where-operators and orderBy must be reconciled before logged writes round-trip 1:1 and before the dead adapters are rewritten. These are the largest remaining parity items.
- **Loading vs. not-found vs. empty.** TS `wireView` now seeds `undefined` (loading) and resolves to `null`/`[]`/Doc after first delivery (F-09). Swift `Loadable<T>` is deferred.

---

## What was fixed

**TypeScript**
- `packages/ts/src/types.ts` — added `models` to `StoreInstance`; corrected `WriteDescriptor.merge` JSDoc (F-11); generic `MutateSpec<P>` (F-26).
- `packages/ts/src/store.ts` — exposed `models` on the store; wrapped compute closures in try/catch (F-22).
- `packages/ts/src/validate.ts` (new) — pure `validateDoc(schema, fields)` (F-02).
- `packages/ts/src/mutate.ts` — pre-cache schema validation loop + shared `recordError` helper (F-02).
- `packages/ts/src/useRead.ts` — `useSyncExternalStore` rewrite, shared `readDocs` enrich helper, unified id semantics, `Doc[]` guard, cached-shape `getSnapshot` (F-07, F-08, F-04).
- `packages/ts/src/react/wireView.ts` — loading-state seeding (F-09), hoisted `NOOP` (F-23), `Doc[]` guard (F-04).
- `packages/ts/src/adapters/firestore.ts` — full rewrite to the current contract + `Doc[]` conformance (F-03, F-04).
- `packages/ts/src/adapters/gun.ts` — `collection`→`path`, warn on lossy coercions (F-03).
- `packages/ts/src/index.ts` — export `validate.js`.
- `packages/ts/package.json` — removed broken `./adapters/firestore` and `./adapters/gun` exports (F-03).
- `packages/ts/__tests__/mutate.test.ts` — 5 new schema-validation tests.

**Swift**
- `Core/Cache.swift` — `(query, continuation)` registry, path-gated re-evaluation, restore re-delivery (F-01).
- `Core/Store.swift` — `StoreError.unroutedWrite` guard + `configuration` classification (F-12).
- `Core/Types.swift` — `merge`/`delete` on `Write` (F-10 partial).
- `Adapters/CloudKitAdapter.swift` — zones + CKQuerySubscription, conflict resolution, offline queue (F-15).
- `Adapters/MemoryAdapter.swift` — atomic register-then-emit (F-16).
- `Adapters/NSUserDefaultsAdapter.swift` — throwing init, no `.standard` fallback (F-21).
- `SwiftUI/WireView.swift` — structured task lifecycle (F-17), generic over `Content` (F-24), throwing dispatch (F-19).
- `SwiftUI/Query.swift` — stable-key re-subscription guard (F-18).

**Regression result (release gate: GREEN)**
- TS `npm test`: **74/74 pass** (was 69; +5 schema-validation tests).
- TS `npm run build` (tsc): **clean, exit 0**.
- Swift `swift build`: **Build complete, no errors**; test target compiles fully.
- `swift test` fails only at the CodeSign step — a known local environment quirk (xctest bundle codesigning), **not a code error**.
- One baseline regression was caught and fixed by the gate: a "Maximum update depth exceeded" loop in the F-08 `useRead.ts` rewrite, resolved by caching the shaped snapshot value when raw docs are unchanged.
- Nothing was reverted; no fix proved unsafe.

---

## Gherkin / scenario updates

All edits confined to `/Users/fiskal/Documents/code.nosync/fiskal-antifragile/_tdd/`. House style preserved; Swift-only scenarios tagged `@[SWIFT]`, planned/unimplemented tagged `@[SKIP]`.

**Added** (selected): `core/store.feature` — F-01 re-evaluation trio (re-evaluated result per write, no cross-collection blanking, restore re-delivers) and F-05/F-12 routing; `core/mutate.feature` — merge/delete/replace parity (F-10/F-11), F-02 validation quartet, F-06 concurrent-rollback; `core/model.feature` — F-07 enrich parity, F-22 throw isolation/immutability; `core/query.feature` — F-09 3-state, F-08 id semantics, F-20 operators/orderBy; `core/errors.feature` — F-19 dispatch; `offline/hard-scenarios.feature` — F-14 redo, F-17/F-18 (`@[SKIP] @[SWIFT]`); `adapters/userdefaults.feature` + `adapters/memory.feature` — F-13 increment/timestamp/JSON, F-16 over-fire/leak, F-10 multi-value union.

**Updated**: `core/model.feature` rewritten from the old getter/`this` model to the closure model; `offline/hard-scenarios.feature` undo scenario annotated with the F-14 cache-revert requirement; stale `{ collection: ... }` wiring samples in `core/errors.feature` and `ui/frontend-concerns.feature` updated to `{ path: ... }`.

**To wire into runners next sprint**:
- **Highest value, currently uncovered**: F-01 store re-evaluation trio and F-06 concurrent-rollback — both silent-data-loss contracts.
- **F-02 validation scenarios** map to the 5 landed unit tests in `__tests__/mutate.test.ts`; link them. Keep TS-scoped (Swift has no `schema`).
- **Async-adapter scenarios** (F-05 first-frame loading, F-09 3-state, F-20 cross-adapter operators) need a deferred/fake-async adapter fixture in `_test/` before unskipping — they can't pass against the synchronous MemoryAdapter.
- **F-14 time-travel** scenarios assert an API absent on TS and non-functional on Swift — keep `@[SKIP]` as the spec for that work.
- `@[SWIFT]` scenarios (F-12, F-17, F-18, F-13, F-16) require `Cucumberish` and cannot run on the TS runner.

---

## Remaining work & recommendations

**Deferred fixes, prioritised:**

1. **F-05 — collapse divergent cache sources (architectural, both platforms).** The single highest-leverage fix: make the adapter the authoritative source, have the Store subscribe each adapter on init and feed `onChange` back into the cache, and route both read paths through one shared `readDocs`. Unblocks correct async-adapter rendering and correct read-then-write mutates.
2. **F-13 — adopt the closed `Sendable Value` enum (Swift, shared model).** Resolves increment-reset, serverTimestamp divergence, the JSON-drop, and Swift-6 Sendable soundness in one stroke. Keystone for replay serialisability.
3. **F-20 — decide one canonical Query shape (product/contract call).** Gates adapter parity, pagination, and the dead-adapter rewrite. Share one query-evaluation function across the three Swift adapters so a `priority > 2` clause stops silently returning equality matches.
4. **F-06 — per-document optimistic rollback (Swift).** Stop whole-cache snapshots from clobbering concurrent mutates.
5. **F-10 (apply paths) + F-14 (time-travel wiring).** Variadic array ops and whole-doc delete/replace on Swift; capture `CacheSnapshot` in history entries and wire `back/forward/goto` to `cache.restore`; implement or remove `store.history` on TS.
6. **F-08 items 3–5, F-09 Swift `Loadable<T>`, F-22 `structuredClone`, F-26 generic threading.** Non-blocking refinements.

**Stale docs to refresh:**

- **`README.md` (F-27)** — rewrite compute examples to closures (not getter `this`); add required `path` to the `addTask` descriptor (or implement id-splitting); implement or remove every `store.history` reference; fix Swift/TS code-block mixups.
- **`GAPS.md` §1a/1b (F-28)** — describe the *old* getter-based compute and falsely claim compute "is never applied." Compute is now closures, eagerly applied via `enrich`. Update or add a stale-doc banner.
- **`EDGE-CASES.md` (F-28)** — still uses `collection:` and explicit `merge:` conventions. Update to `path` and merge-defaults-to-patch.

**Recommendation.** The library's foundations are sound and the platform-critical defects are fixed. The remaining work is dominated by three cross-platform contract decisions (F-05 cache authority, F-13 value model, F-20 query shape). Resolve those three first — they unblock parity, the dead-adapter rewrite, and the replay/time-travel selling point — before adding new surface area.
