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

  # ---------------------------------------------------------------------------
  # Tier 2 — wireView honours the same three-state contract as useRead (F-09)
  # The loading / not-found / empty states must NOT be collapsed by wireView.
  # ---------------------------------------------------------------------------

  Scenario: wireView reports loading (not empty/not-found) before an async adapter responds
    # F-09: wireView's initial state must be undefined=loading for an unresolved doc
    # and undefined=loading for an unresolved collection — never seeded to null or [].
    Given an empty store backed by an async adapter that has not yet delivered
    When a component is wired with { task: { id: "tasks/task-999" } }
    Then the wired component receives task = undefined (loading), not null and not []
    When a component is wired with { tasks: { path: "tasks", where: { done: false } } }
    Then the wired component receives tasks = undefined (loading), not an empty array

  Scenario: wireView distinguishes loading from genuine not-found
    Given an empty store
    And the adapter is configured to emit "not-found" for "tasks/task-000"
    When a component is wired with { task: { id: "tasks/task-000" } }
    Then the wired component first receives task = undefined (loading)
    And then receives task = null (confirmed not-found)
    And the two states are distinguishable (loading is never conflated with not-found)

  Scenario: wireView distinguishes loading from a genuinely empty collection
    Given a store whose "tasks" collection is confirmed empty by the adapter
    When a component is wired with { tasks: { path: "tasks", where: { priority: 99 } } }
    Then the wired component first receives tasks = undefined (loading)
    And then receives tasks = [] (confirmed empty)

  Scenario: useRead and wireView agree on whether an empty id string is a doc read or a collection read
    # F-08: id "" must be classified consistently across both read paths.
    Given a query whose id is the empty string ""
    When the query is read via useRead
    And the same query is read via wireView
    Then both paths classify it the same way (both a doc read OR both a collection read)
    And they do not disagree on the result shape for the same query

  # ---------------------------------------------------------------------------
  # Tier 2 — where-operator and orderBy parity across platforms and adapters (F-20)
  # ---------------------------------------------------------------------------

  Scenario: a where filter supports comparison operators, not only equality
    # F-20: a query like priority > 1 must be expressible and honoured, not silently
    # downgraded to equality. (TS currently only does equality — this is the contract.)
    When I read a collection of "tasks" where priority is greater than 1
    Then the result contains task-002 (priority 2)
    And the result does not contain task-001 or task-003 (priority 1)

  Scenario: orderBy is honoured consistently across platforms
    # F-20: the same query with orderBy createdAt ascending must produce the same order
    # on every platform, not rely on insertion/key order on one and sort on another.
    When I read a collection of "tasks" ordered by createdAt ascending
    Then the documents are ordered: task-003, task-002, task-001 (oldest createdAt first)

  Scenario: every adapter applies the same where-operator semantics
    # F-20: MemoryAdapter, CloudKitAdapter and NSUserDefaultsAdapter must all honour
    # the clause operator. A "priority > 1" clause must never silently match by equality.
    Given the same "priority greater than 1" query run against each adapter
    Then each adapter returns only docs whose priority is strictly greater than 1
    And no adapter silently degrades the > operator to == (returning equality matches)
