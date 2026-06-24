# ADR-0009: Antifragile Developer Agent Skill

**Date:** 2026-06-23
**Status:** Accepted
**Deciders:** Engineering
**Points:** 2pt

---

## Context

Developers and AI agents writing apps with fiskal-antifragile frequently make the same
architectural mistakes: importing the library inside components, using try/catch on
mutates, destructuring model computer methods (losing `this`), using RTK selector
patterns that don't exist here, reaching for Context when a query is enough.

The library's structural zero-import rule makes these mistakes a compile error —
but only if the developer understands the wireView pattern to begin with. Without
guidance, the first instinct is to write `useStore()` hooks inside components, use
`useEffect` to subscribe, or add business logic to component files.

A bundled agent skill removes the learning curve by encoding all patterns,
anti-patterns, and FP rules into a reusable agent that any developer can load into
their Claude Code session when building on the library.

---

## User-Facing Feature

> "I open the library in Claude Code, type `/antifragile`, and the agent helps me
> implement any feature correctly — wiring components, defining models, writing mutates,
> subscribing to error states — without ever importing the library inside a component."

---

## Decision

### Agent skill file

A `.claude/agents/antifragile-developer.md` file is included in the repo root.
It is a self-contained Claude Code agent skill that any developer consuming the library
can load by placing it in their project's `.claude/agents/` directory.

The skill encodes:

1. **Zero-import rule** — components never import from the library or store file. The
   only allowed import in a component file is from sibling component files.

2. **wireView first** — every data connection is declared via `wireView` outside the
   component file. If the developer asks "how do I get X into my component", the answer
   is always a wireView spec, never a hook inside the component.

3. **ID is always the full path** — `'tasks/task-1'`, not `'task-1'`. Single-doc queries
   need only `{ id }`. Collection field required only for `where` / `orderBy` queries.

4. **Model compute rules** — getters are read as plain values; computers (methods
   taking sibling args) must be called as `doc.method(arg)`, never destructured.

5. **Errors as data** — never wrap mutate calls in try/catch. Subscribe to
   `{ collection: 'errors', where: { resolved: false } }` for failure UX.

6. **No memoization** — no `React.memo`, no `useCallback`, no `useMemo` in library
   code. Per-document subscriptions and field narrowing make these unnecessary.

7. **No Context, no Provider, no portal** — write the query descriptor as a store
   value instead. `setModal` writes `{ id: 'tasks/task-1' }` to `ui/modal/active`;
   the modal shell reads it as its live query.

8. **`ui/` prefix for ephemeral state** — scroll position, modal state, tab selection,
   active filter — anything session-only lives under `ui/`. Always routes to a
   session-scoped MemoryAdapter. Never persisted, never synced.

### Context loading

The skill loads at startup:
- `PRINCIPLES.md` — canonical API reference
- `EDGE-CASES.md` — 27 offline-first scenarios + React/SwiftUI patterns
- `GAPS.md` — known limits and honest comparison with TanStack/RTK

### Skill file location and distribution

- Lives at `.claude/agents/antifragile-developer.md` in the library repo.
- Documented in `README.md` under an "AI-assisted development" section.
- Developers copy the file into their own project's `.claude/agents/` to activate it.
- Future: ship as an npm postinstall script that copies the file automatically.

---

## Consequences

- Developers get correct-by-default AI assistance when building on the library.
- The agent enforces zero-import and zero-memoization structurally — it will refuse
  to write components that import from the store.
- AI-generated code passes the library's test suite because the agent knows the exact
  mutation contract and query shapes.
- The skill file must be updated whenever the library API changes; it is part of the
  library's public surface area.
