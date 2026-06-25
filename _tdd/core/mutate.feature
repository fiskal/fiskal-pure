Feature: createMutate — mutation factory with optimistic writes and rollback

  createMutate returns a bound async function that executes one of three
  call forms: write-only, read-then-write, and atomic transaction. The cache
  is updated optimistically before the remote write; on failure the snapshot
  is restored automatically.

  Background:
    Given a store backed by MemoryAdapter with schema "tasks"
    And the store cache contains:
      | key             | value                                                                                                              |
      | tasks/task-alpha | {"id":"task-alpha","title":"Alpha task","done":false,"priority":1,"createdAt":"2026-06-23T08:00:00Z"}            |
      | tasks/task-beta  | {"id":"task-beta","title":"Beta task","done":false,"priority":2,"createdAt":"2026-06-23T08:05:00Z"}             |

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: write-only mutate updates cache immediately and resolves with confirmed descriptor
    Given a write-only mutate defined as:
      """
      createMutate({
        action: "tasks/markDone",
        write: (payload) => ({ key: `tasks/${payload.id}`, patch: { done: true } })
      })
      """
    When I call the mutate with payload { "id": "task-alpha" }
    Then the cache at "tasks/task-alpha" has done = true immediately (before remote confirmation)
    And the mutate resolves with the confirmed descriptor:
      """
      { "key": "tasks/task-alpha", "patch": { "done": true } }
      """
    And the adapter write count for "tasks/task-alpha" is 1

  Scenario: read-then-write mutate reads from cache synchronously then writes
    Given a read-then-write mutate defined as:
      """
      createMutate({
        action: "tasks/toggleDone",
        read: (payload) => [`tasks/${payload.id}`],
        write: (reads) => ({
          key: `tasks/${reads[0].id}`,
          patch: { done: !reads[0].done }
        })
      })
      """
    When I call the mutate with payload { "id": "task-beta" }
    Then the read phase returns the cached value for "tasks/task-beta" without an adapter fetch
    And the write descriptor produced is { "key": "tasks/task-beta", "patch": { "done": true } }
    And the cache at "tasks/task-beta" has done = true
    And the mutate resolves successfully

  Scenario: transaction mutate applies all writes atomically when all succeed
    Given a transaction mutate defined as:
      """
      createMutate({
        action: "tasks/archiveBoth",
        write: [
          (_) => ({ key: "tasks/task-alpha", patch: { done: true } }),
          (_) => ({ key: "tasks/task-beta",  patch: { done: true } })
        ]
      })
      """
    When I call the mutate with payload {}
    Then the cache at "tasks/task-alpha" has done = true
    And the cache at "tasks/task-beta" has done = true
    And the adapter batch write count is 1
    And the mutate resolves with both confirmed descriptors

  Scenario: optimistic update is visible to useRead before the remote write completes
    Given a write-only mutate for "tasks/setPriority" that sets priority = 5 on "tasks/task-alpha"
    And a subscriber attached to "tasks/task-alpha"
    When I call the mutate (remote write takes 200ms)
    Then the subscriber receives priority = 5 within 10ms
    And the remote write completes at 200ms
    And the final cache priority is 5

  Scenario: fire-and-forget mutate call does not block the caller
    Given a write-only mutate for "tasks/markDone" on "tasks/task-beta"
    When I call the mutate without awaiting
    Then control returns to the caller immediately
    And the cache is updated optimistically before the caller's next line executes

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: mutate rolls back the cache snapshot when the remote write fails
    Given a write-only mutate that targets "tasks/task-alpha" with done = true
    And the adapter is configured to reject the next write with error "Network unavailable"
    When I call the mutate and await it
    Then the mutate rejects with error "Network unavailable"
    And the cache at "tasks/task-alpha" has done = false (snapshot restored)
    And any subscriber on "tasks/task-alpha" receives exactly two notifications:
      | notification | value        |
      | 1            | done = true  |
      | 2            | done = false |

  Scenario: transaction mutate rolls back all keys when any write in the batch fails
    Given a transaction mutate that writes to "tasks/task-alpha" and "tasks/task-beta"
    And the adapter is configured to reject the write to "tasks/task-beta"
    When I call the mutate and await it
    Then the mutate rejects
    And the cache at "tasks/task-alpha" has done = false (restored)
    And the cache at "tasks/task-beta" has done = false (restored)
    And the adapter attempted 1 batch write

  Scenario: read-then-write mutate uses cache snapshot; concurrent write to same key does not race
    Given a read-then-write mutate for toggleDone on "tasks/task-alpha"
    And a concurrent write directly sets "tasks/task-alpha" done = true at the same instant
    When both operations complete
    Then the cache reflects exactly one final value (no torn state)
    And the mutate resolves without throwing

  # ---------------------------------------------------------------------------
  # Tier 2 — merge / replace / delete descriptor semantics (F-10, F-11)
  # Platform-agnostic contract: a WriteDescriptor carries path/id/fields/merge/delete.
  # ---------------------------------------------------------------------------

  Scenario: merge defaults to patch — omitting merge preserves untouched fields
    # F-11: the implemented default is PATCH. A descriptor with no `merge` key
    # merges its fields into the existing doc, leaving all other fields intact.
    Given a write descriptor for "tasks/task-alpha" with fields { "title": "Renamed" } and no merge key
    When the descriptor is applied
    Then the cache at "tasks/task-alpha" has title = "Renamed"
    And the cache at "tasks/task-alpha" still has done = false and priority = 1 (untouched fields preserved)

  Scenario: merge false performs a full replace — untouched fields are dropped
    # F-10/F-11: only merge:false opts into whole-document replacement.
    Given a write descriptor for "tasks/task-alpha" with merge = false and fields { "title": "Fresh" }
    When the descriptor is applied
    Then the cache at "tasks/task-alpha" has title = "Fresh"
    And the cache at "tasks/task-alpha" no longer has the "done" field (replaced, not patched)
    And the cache at "tasks/task-alpha" no longer has the "priority" field
    And the doc retains its id "task-alpha"

  Scenario: delete descriptor removes the whole document, not just a field
    # F-10: Swift parity gap — delete must remove the entire doc from its collection.
    Given a write descriptor for "tasks/task-beta" with delete = true
    When the descriptor is applied
    Then the cache no longer contains "tasks/task-beta"
    And a subsequent read of "tasks/task-beta" returns not-found (null), not a partial doc

  Scenario: fields.id is reconciled with the descriptor id — they may not diverge
    # F-11 integrity gap: a descriptor keyed under id "task-alpha" whose fields also
    # carry id "other" must not produce a doc stored under one key but reporting another.
    Given a write descriptor with id "tasks/task-alpha" and fields { "id": "tasks/other", "done": true }
    When the descriptor is applied
    Then the doc is stored under the cache key "tasks/task-alpha"
    And the stored doc's id equals "task-alpha" (the descriptor id wins; fields.id cannot override the key)

  Scenario: a multi-value array union is one descriptor, not many — replay round-trips 1:1
    # F-10 parity: adding three tags must log exactly ONE descriptor on every platform.
    Given "tasks/task-alpha" has tags []
    When a single descriptor applies ::arrayUnion with values ["urgent", "backend", "p1"]
    Then the cache at "tasks/task-alpha" has tags ["urgent", "backend", "p1"]
    And exactly one write descriptor is recorded for this change (not three)
    And replaying that single descriptor on a fresh cache reproduces the same tags array

  Scenario: array union dedups by value, including value-equal objects
    # F-11: equality must be value-based so the optimistic cache matches a remote
    # that dedups by deep value-equality, not reference identity.
    Given "tasks/task-alpha" has tags [{ "k": "a" }]
    When a descriptor applies ::arrayUnion with values [{ "k": "a" }, { "k": "b" }]
    Then the cache at "tasks/task-alpha" has tags [{ "k": "a" }, { "k": "b" }] (value-equal { "k": "a" } not duplicated)

  # ---------------------------------------------------------------------------
  # Tier 2 — schema validation enforced at the write boundary (F-02)
  # CORRECTED BEHAVIOUR: a declared Model.schema is now validated BEFORE the
  # optimistic cache update, so an invalid write never touches the cache.
  # ---------------------------------------------------------------------------

  Scenario: a write violating a required field is rejected before the cache is touched
    Given the "tasks" model declares schema with required field "title"
    And a write-only mutate "tasks/clearTitle" that writes { "title": "::delete" } to "tasks/task-alpha"
    When I call the mutate and await it
    Then the mutate rejects with a validation error
    And the cache at "tasks/task-alpha" is unchanged (no optimistic write applied)
    And the adapter write is NOT dispatched
    And an ErrorDoc is recorded with kind = "validation"

  Scenario: a write violating an enum constraint is rejected with a validation ErrorDoc
    Given the "tasks" model declares schema where "status" must be one of ["active","done","archived"]
    And a write-only mutate that sets status = "frozen" on "tasks/task-alpha"
    When I call the mutate and await it
    Then the mutate rejects
    And the ErrorDoc kind is "validation"
    And the cache at "tasks/task-alpha" has no "status" field set to "frozen"

  Scenario: a valid write passes validation and is applied normally
    Given the "tasks" model declares schema with required field "title" of type string
    And a write-only mutate that sets title = "Valid title" on "tasks/task-alpha"
    When I call the mutate and await it
    Then validation passes
    And the cache at "tasks/task-alpha" has title = "Valid title"
    And the adapter write count for "tasks/task-alpha" is 1

  Scenario: a delete descriptor skips field validation
    # F-02: delete removes the doc, so required-field checks must not fire against it.
    Given the "tasks" model declares schema with required field "title"
    And a write descriptor for "tasks/task-alpha" with delete = true
    When the mutate is applied
    Then validation does not reject the delete
    And the cache no longer contains "tasks/task-alpha"

  # ---------------------------------------------------------------------------
  # Tier 2 — concurrent rollback isolation (F-06)
  # ---------------------------------------------------------------------------

  Scenario: failed mutate A rolls back only its own write, not a concurrent committed mutate B
    # F-06: rollback must NOT restore a whole-cache snapshot. Mutate B commits between
    # A's snapshot and A's failure; A's rollback must leave B's write intact.
    Given mutate A sets done = true on "tasks/task-alpha" with a remote write that takes 200ms then fails
    And while A's remote write is in flight, mutate B sets priority = 9 on "tasks/task-beta" and succeeds
    When A's remote write rejects and A rolls back
    Then the cache at "tasks/task-alpha" has done = false (A's optimistic write reverted)
    And the cache at "tasks/task-beta" still has priority = 9 (B's committed write is NOT clobbered)
