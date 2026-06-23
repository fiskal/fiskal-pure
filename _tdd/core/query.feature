Feature: useRead / @Query — live data subscription with query shapes

  useRead (TypeScript React hook) and @Query (Swift property wrapper) share
  the same query interface. They subscribe to the store, re-render when data
  changes, and expose loading, not-found, and error states as first-class values.

  Background:
    Given a store backed by MemoryAdapter with schema "tasks"
    And the store cache contains:
      | key              | value                                                                                                                        |
      | tasks/task-001   | {"id":"task-001","title":"Ship v1","done":false,"priority":1,"createdAt":"2026-06-23T09:00:00Z"}                            |
      | tasks/task-002   | {"id":"task-002","title":"Write docs","done":true,"priority":2,"createdAt":"2026-06-22T08:00:00Z"}                          |
      | tasks/task-003   | {"id":"task-003","title":"Open-source","done":false,"priority":1,"createdAt":"2026-06-21T07:00:00Z"}                       |

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: useRead for a single document returns the cached value immediately
    When I call useRead(store, { type: "doc", key: "tasks/task-001" })
    Then the hook returns status "ready" with data:
      """
      {
        "id": "task-001",
        "title": "Ship v1",
        "done": false,
        "priority": 1,
        "createdAt": "2026-06-23T09:00:00Z"
      }
      """
    And the adapter is not called (served from cache)

  Scenario: useRead for a collection returns all matching documents sorted by key
    When I call useRead(store, { type: "collection", prefix: "tasks/" })
    Then the hook returns status "ready" with 3 documents
    And the documents are ordered by key ascending:
      | index | id         |
      | 0     | task-001   |
      | 1     | task-002   |
      | 2     | task-003   |

  Scenario: useRead with a where filter returns only matching documents
    When I call useRead(store, { type: "collection", prefix: "tasks/", where: { done: false } })
    Then the hook returns status "ready" with 2 documents
    And the result contains "task-001" and "task-003"
    And the result does not contain "task-002"

  Scenario: useRead with fields projection returns only the requested fields
    When I call useRead(store, { type: "doc", key: "tasks/task-002", fields: ["id", "title"] })
    Then the hook returns status "ready" with data:
      """
      { "id": "task-002", "title": "Write docs" }
      """
    And the data does not contain "done", "priority", or "createdAt"

  Scenario: useRead re-renders when the store emits an update for the subscribed key
    Given useRead is active on { type: "doc", key: "tasks/task-001" }
    And the render count is 1
    When the store emits an update to "tasks/task-001" with done = true
    Then useRead triggers a re-render
    And the new data has done = true
    And the render count is 2

  Scenario: @Query in Swift publishes new values on the main thread when store updates
    Given a SwiftUI view with @Query(store: store, query: .doc(key: "tasks/task-001"))
    When the store updates "tasks/task-001" with priority = 5
    Then the @Query projected value has priority = 5
    And the update is delivered on the main thread

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: useRead returns status "loading" when the key is not yet in cache and the adapter has not responded
    Given an empty store (cache is empty)
    When I call useRead(store, { type: "doc", key: "tasks/task-999" })
    Then the hook returns status "loading" immediately
    And data is undefined

  Scenario: useRead returns status "not-found" when the adapter confirms the key does not exist
    Given an empty store
    And the adapter is configured to emit "not-found" for key "tasks/task-000"
    When I call useRead(store, { type: "doc", key: "tasks/task-000" })
    Then the hook transitions from status "loading" to status "not-found"
    And data is undefined
    And no error is thrown

  Scenario: useRead with where filter returns empty array (not an error) when no documents match
    When I call useRead(store, { type: "collection", prefix: "tasks/", where: { priority: 99 } })
    Then the hook returns status "ready" with 0 documents
    And data is an empty array

  Scenario: useRead returns status "error" and surfaces the adapter error when the adapter throws
    Given the adapter is configured to throw "Permission denied" for prefix "tasks/"
    When I call useRead(store, { type: "collection", prefix: "tasks/" })
    Then the hook returns status "error"
    And the error message is "Permission denied"
    And no documents are in data
