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
