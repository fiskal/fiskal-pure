Feature: createStore — store lifecycle and cache behavior

  A store wraps an adapter and a schema. It maintains an immutable cache
  of the most recent value per key and fans out subscriptions whenever the
  cache changes. Same input always produces the same observable state.

  Background:
    Given a MemoryAdapter named "mem"
    And a schema for "tasks" with fields: id (string), title (string), done (boolean), priority (integer), createdAt (timestamp)

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: createStore returns a store bound to the given adapter
    When I call createStore with adapter "mem" and schema "tasks"
    Then the store is initialised with an empty cache
    And the store exposes a "subscribe" function
    And the store exposes a "read" function
    And the adapter receives no writes at construction time

  Scenario: writing a document populates the cache and notifies subscribers
    Given a store created with adapter "mem" and schema "tasks"
    And a subscriber is attached to key "tasks/task-001"
    When the adapter receives:
      """
      {
        "id": "task-001",
        "title": "Ship fiskal-pure v1",
        "done": false,
        "priority": 1,
        "createdAt": "2026-06-23T09:00:00Z"
      }
      """
    Then the cache at "tasks/task-001" equals:
      """
      {
        "id": "task-001",
        "title": "Ship fiskal-pure v1",
        "done": false,
        "priority": 1,
        "createdAt": "2026-06-23T09:00:00Z"
      }
      """
    And the subscriber is called exactly once with the new value

  Scenario: reading a cached document returns the last-written value without hitting the adapter
    Given a store created with adapter "mem" and schema "tasks"
    And the cache contains:
      | key           | value                                                                              |
      | tasks/task-002 | {"id":"task-002","title":"Write Gherkin","done":true,"priority":2,"createdAt":"2026-06-22T08:00:00Z"} |
    When I call store.read("tasks/task-002")
    Then the result equals:
      """
      {
        "id": "task-002",
        "title": "Write Gherkin",
        "done": true,
        "priority": 2,
        "createdAt": "2026-06-22T08:00:00Z"
      }
      """
    And the adapter "mem" receive-count is 0 for key "tasks/task-002"

  Scenario: multiple subscribers on different keys receive independent notifications
    Given a store created with adapter "mem" and schema "tasks"
    And subscriber A is attached to key "tasks/task-001"
    And subscriber B is attached to key "tasks/task-003"
    When the adapter receives a document at "tasks/task-001" with title "Deploy"
    Then subscriber A is called once
    And subscriber B is not called

  Scenario: unsubscribing stops further notifications
    Given a store created with adapter "mem" and schema "tasks"
    And a subscriber is attached to key "tasks/task-005"
    When I call the unsubscribe function returned by subscribe
    And the adapter receives a document at "tasks/task-005" with title "After unsubscribe"
    Then the subscriber is not called

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: a write with an identical value does not trigger subscriber notification
    Given a store created with adapter "mem" and schema "tasks"
    And the cache at "tasks/task-010" contains:
      """
      {"id":"task-010","title":"Review PR","done":false,"priority":3,"createdAt":"2026-06-20T11:00:00Z"}
      """
    And subscriber C is attached to key "tasks/task-010"
    When the adapter emits the same document again at "tasks/task-010"
    Then subscriber C is not called
    And the subscriber call count for C is 0

  Scenario: a document failing schema validation is rejected and leaves cache unchanged
    Given a store created with adapter "mem" and schema "tasks"
    And the cache at "tasks/task-020" contains:
      """
      {"id":"task-020","title":"Existing task","done":false,"priority":1,"createdAt":"2026-06-21T07:00:00Z"}
      """
    When the adapter emits an invalid payload at "tasks/task-020":
      """
      {"id":"task-020","title":12345,"done":"not-a-bool","priority":"high"}
      """
    Then the cache at "tasks/task-020" still equals the prior value
    And a validation error is logged with key "tasks/task-020"
    And no subscriber is notified

  Scenario: cache read for an unknown key returns undefined without throwing
    Given a store created with adapter "mem" and schema "tasks"
    When I call store.read("tasks/does-not-exist")
    Then the result is undefined
    And no error is thrown

  # ---------------------------------------------------------------------------
  # Tier 2 — live subscriber re-evaluation (F-01)
  # A subscriber must receive the RE-EVALUATED query result on every change,
  # never a hard-coded empty result.
  # ---------------------------------------------------------------------------

  Scenario: a collection subscriber receives the re-evaluated result on each write, never an empty array
    # F-01: on any write, the store must re-run the subscriber's query against the
    # new cache and yield the matching docs — not blank the subscriber with [].
    Given a store created with adapter "mem" and schema "tasks"
    And the cache contains "tasks/task-001" and "tasks/task-002"
    And a collection subscriber is attached to prefix "tasks/"
    When a write updates "tasks/task-001" with title "Updated"
    Then the subscriber receives a non-empty list still containing both task-001 and task-002
    And task-001 in that list has title "Updated"
    And the subscriber is NEVER delivered an empty list while matching docs exist

  Scenario: a write to one collection does not blank subscribers on a different collection
    # F-01 path-gating: notifications must be scoped to the affected path; an
    # unrelated write must not deliver an empty (or any) result to other subscribers.
    Given a store created with adapter "mem" and schema "tasks"
    And the cache contains "tasks/task-001"
    And a collection subscriber A is attached to prefix "tasks/"
    And a collection subscriber B is attached to prefix "sprints/"
    When a write updates "tasks/task-001"
    Then subscriber A receives the re-evaluated "tasks/" result containing task-001
    And subscriber B is not notified (and is never blanked to an empty list)

  Scenario: restore / time-travel re-delivers the restored docs, not an empty result
    # F-01: restore() must re-evaluate each subscriber's query against the restored
    # cache and deliver the matching docs.
    Given a store created with adapter "mem" and schema "tasks"
    And a snapshot was captured while "tasks/task-001" had title "Original"
    And a collection subscriber is attached to prefix "tasks/"
    When the store restores that snapshot
    Then the subscriber receives a list containing task-001 with title "Original"
    And the delivered list is not empty

  # ---------------------------------------------------------------------------
  # Tier 2 — single source of truth: adapter output reaches the rendered cache (F-05)
  # ---------------------------------------------------------------------------

  Scenario: data confirmed by the adapter reaches the store cache the UI renders
    # F-05: adapter-originated changes (server echo, computed fields, conflict merges)
    # must flow back into store.getCache() — not live only in an independent adapter cache.
    Given a store created with adapter "mem" and schema "tasks"
    And a wired/hooked reader is subscribed to "tasks/task-007"
    When the adapter emits "tasks/task-007" with a server-added field serverTimestamp
    Then store.getCache() for "tasks/task-007" includes serverTimestamp
    And the reader renders the serverTimestamp value (not a stale local-only doc)

  Scenario: a read-then-write mutate sees adapter-confirmed docs, not only locally-mutated docs
    # F-05 TOCTOU: the read phase must observe docs that arrived from the adapter,
    # otherwise reads compute from an incomplete view and produce wrong writes.
    Given a store created with adapter "mem" and schema "tasks"
    And the adapter has delivered "tasks/task-008" with priority = 3 (never locally mutated on this client)
    And a read-then-write mutate that reads "tasks/task-008" and increments its priority
    When the mutate runs
    Then the read phase observes priority = 3 (the adapter-confirmed value)
    And the resulting write sets priority = 4

  Scenario: the first frame of an async adapter is loading — not an empty or stale cache
    # F-05 / F-09: before the adapter's first delivery, a reader on an empty store
    # must signal loading, never a confidently-empty result.
    Given a store created with an async adapter that has not yet delivered "tasks/task-009"
    When a reader subscribes to "tasks/task-009"
    Then the reader's initial state is loading (undefined), not not-found and not empty

  # ---------------------------------------------------------------------------
  # Tier 2 — backing-store path ownership (F-12, Swift)
  # ---------------------------------------------------------------------------

  @[SWIFT]
  Scenario: a write to a path owned by no BackingStoreConfig does not silently disappear
    # F-12: Swift filters writes by config.models path-ownership; a path in NO config
    # is applied to the in-memory cache and history but never persisted, then lost on
    # restart with no error. An unowned domain path must not be silently dropped.
    Given a store with one BackingStoreConfig whose models = ["tasks"]
    When the user fires a mutate writing to path "sprints" id "sprint-A"
    Then the write is either persisted by a config that owns "sprints"
    And or it surfaces an error that "sprints" is unrouted (it is not silently optimistic-only)
    And no write is accepted into the cache that can never be persisted

  @[SWIFT]
  Scenario: the internal errors path is intentionally in-memory-only and is not treated as unrouted
    # F-12 caveat: the ErrorDoc write to path "errors" is deliberately local-only and
    # must NOT trip the unrouted-path error.
    Given a store whose configs do not list "errors" in any models array
    When a write fails and an ErrorDoc is written to path "errors"
    Then the ErrorDoc is stored in the in-memory cache
    And no "unrouted path" error is raised for the internal errors write
