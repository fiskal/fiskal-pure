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
