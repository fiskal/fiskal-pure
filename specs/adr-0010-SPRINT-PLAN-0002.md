# ADR-0010: Sprint Plan 0002

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 8pt

---

## Context

Sprint 0002 ships three capabilities on top of the Foundation Sprint:
model enrichment (computed properties on documents), errors as a first-class
subscribable collection (write failures become data, not thrown exceptions),
and a bundled developer agent skill for AI-assisted development on the library.

After this sprint a developer can:
- Define a `Model` with `compute` getters and computer methods and receive enriched
  documents in components without any utility imports
- Subscribe to `{ collection: 'errors' }` anywhere in the UI to receive contextual
  failure state — no try/catch at the call site
- Load `/antifragile` in Claude Code and receive architecture-correct guidance for
  any feature they are building on the library

---

## ADRs in this Sprint

- **adr-0007-model-enrichment-2pt** — `createStore` accepts `models` map per collection;
  documents are enriched with compute getters/computers before delivery to subscribers.
- **adr-0008-errors-collection-2pt** — write failures produce `ErrorDoc` in the `errors`
  collection; retryError and dismissError are built-in mutates.
- **adr-0009-antifragile-developer-skill-2pt** — `.claude/agents/antifragile-developer.md`
  bundled in the repo; encodes zero-import, wireView-first, no-memoization, errors-as-data,
  and ui/-prefix rules for AI-assisted development.

---

## Gherkin Coverage

- `_tdd/core/model.feature` — model enrichment: getters, computers, multiple backing stores
- `_tdd/core/errors.feature` — errors collection: write failure, retry, dismiss, contextual subscribe
- `_tdd/core/mutate.feature` — updated: errors-on-failure scenario added (Tier 2)

---

## Test Files

All new tests written at plan time. All set to **skip**. Unskip one ADR at a time in Step 3.

**TypeScript (`packages/ts/__tests__/`)**
- `model.test.ts` — model enrichment: getter applied on doc delivery, computer callable as method
- `errors.test.ts` — write failure writes ErrorDoc to errors collection; retry re-dispatches writes

**Swift (`packages/swift/Tests/AntifragileTests/`)**
- `ModelEnrichmentTests.swift` — Swift model enrich closure applied when delivering docs
- `ErrorsCollectionTests.swift` — mutate failure writes to errors/ path in cache

---

## Risks

- TypeScript `Object.defineProperties` preserves getter descriptors but strict-mode
  destructuring of computers loses `this` — enforced in agent skill and docs, not at runtime.
- Swift enrichment uses a closure-based `enrich(_ doc: Doc) -> Doc` rather than
  getter properties — less ergonomic but compatible with `[String: Any]` document type.
- `errors` collection is always local-only (session MemoryAdapter). On page reload, errors
  clear. This is intentional — document it prominently so developers don't expect persistence.
