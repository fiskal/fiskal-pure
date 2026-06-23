Feature: MemoryAdapter — in-process key-value store

  MemoryAdapter is the zero-dependency adapter used for tests and local-only
  apps. It stores data in an immutable in-process map. Subscribe delivers
  updates synchronously within the same event loop tick. Atomic batch writes
  either all succeed or all fail together.

  Background:
    Given a MemoryAdapter instance named "mem"

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: subscribe receives the current value immediately on attach
    Given the adapter contains:
      """
      { "key": "tasks/task-001", "value": { "id": "task-001", "title": "Deploy pipeline", "done": false, "priority": 1, "createdAt": "2026-06-23T10:00:00Z" } }
      """
    When I subscribe to "tasks/task-001"
    Then the subscriber is called immediately with:
      """
      { "id": "task-001", "title": "Deploy pipeline", "done": false, "priority": 1, "createdAt": "2026-06-23T10:00:00Z" }
      """

  Scenario: write stores the value and notifies the subscriber
    Given a subscriber is attached to "tasks/task-002"
    When I call adapter.write("tasks/task-002", { "id": "task-002", "title": "Fix flaky tests", "done": false, "priority": 2, "createdAt": "2026-06-23T10:05:00Z" })
    Then the adapter contains "tasks/task-002" with title "Fix flaky tests"
    And the subscriber is called with the written value

  Scenario: atomic batch writes all keys or none
    When I call adapter.writeBatch([
      { "key": "tasks/task-010", "value": { "id": "task-010", "title": "Batch item A", "done": false, "priority": 3, "createdAt": "2026-06-23T11:00:00Z" } },
      { "key": "tasks/task-011", "value": { "id": "task-011", "title": "Batch item B", "done": true,  "priority": 4, "createdAt": "2026-06-23T11:01:00Z" } }
    ])
    Then the adapter contains "tasks/task-010" with title "Batch item A"
    And the adapter contains "tasks/task-011" with title "Batch item B"
    And both subscribers (one per key) are each called exactly once

  Scenario: overwriting an existing key replaces the value
    Given the adapter contains "tasks/task-020" with title "Old title"
    When I call adapter.write("tasks/task-020", { "id": "task-020", "title": "New title", "done": true, "priority": 1, "createdAt": "2026-06-22T09:00:00Z" })
    Then the adapter contains "tasks/task-020" with title "New title"

  Scenario: listing keys by prefix returns all matching keys
    Given the adapter contains:
      | key              |
      | tasks/task-001   |
      | tasks/task-002   |
      | archive/task-001 |
    When I call adapter.list("tasks/")
    Then the result contains "tasks/task-001" and "tasks/task-002"
    And the result does not contain "archive/task-001"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: two independent MemoryAdapter instances do not share state
    Given a second MemoryAdapter instance named "mem2"
    When I write "tasks/task-001" with title "Isolated" to "mem"
    Then "mem2" does not contain "tasks/task-001"
    And reading "tasks/task-001" from "mem2" returns undefined

  Scenario: writing undefined (delete) to an existing key removes it and notifies subscriber
    Given the adapter contains "tasks/task-030" with title "To be deleted"
    And a subscriber is attached to "tasks/task-030"
    When I call adapter.write("tasks/task-030", undefined)
    Then the adapter does not contain "tasks/task-030"
    And the subscriber is called with undefined
