Feature: FirestoreAdapter — Firestore-backed adapter with snapshot subscriptions

  FirestoreAdapter wraps the Firestore SDK. Subscribe opens an onSnapshot
  listener; write calls setDoc / updateDoc. A FakeFirestore is injected at
  construction time so all unit tests run hermetically without a live project.

  Background:
    Given a FakeFirestore instance
    And a FirestoreAdapter constructed with the FakeFirestore

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: subscribe opens an onSnapshot listener and delivers the initial document
    Given the FakeFirestore contains document "tasks/task-fs-001":
      """
      { "id": "task-fs-001", "title": "Land in prod", "done": false, "priority": 1, "createdAt": "2026-06-23T12:00:00Z" }
      """
    When I subscribe to "tasks/task-fs-001" via the adapter
    Then the subscriber receives:
      """
      { "id": "task-fs-001", "title": "Land in prod", "done": false, "priority": 1, "createdAt": "2026-06-23T12:00:00Z" }
      """
    And the FakeFirestore listener count for "tasks/task-fs-001" is 1

  Scenario: write calls setDoc and delivers the update to the subscriber
    Given a subscriber is attached to "tasks/task-fs-002"
    When I call adapter.write("tasks/task-fs-002", { "id": "task-fs-002", "title": "Merge PR", "done": false, "priority": 2, "createdAt": "2026-06-23T12:10:00Z" })
    Then the FakeFirestore document "tasks/task-fs-002" contains title "Merge PR"
    And the subscriber is called with title "Merge PR"
    And the FakeFirestore setDoc call count is 1

  Scenario: atomic batch write uses a Firestore WriteBatch
    When I call adapter.writeBatch([
      { "key": "tasks/task-fs-010", "value": { "id": "task-fs-010", "title": "Batch write A", "done": false, "priority": 3, "createdAt": "2026-06-23T13:00:00Z" } },
      { "key": "tasks/task-fs-011", "value": { "id": "task-fs-011", "title": "Batch write B", "done": true,  "priority": 4, "createdAt": "2026-06-23T13:01:00Z" } }
    ])
    Then the FakeFirestore commit count is 1
    And the FakeFirestore contains "tasks/task-fs-010" and "tasks/task-fs-011"
    And both subscribers are notified

  Scenario: collection query returns all documents under the prefix
    Given the FakeFirestore contains:
      | document key      | title           |
      | tasks/task-fs-020 | Collection A    |
      | tasks/task-fs-021 | Collection B    |
      | other/doc-001     | Unrelated       |
    When I call adapter.list("tasks/")
    Then the result contains "tasks/task-fs-020" and "tasks/task-fs-021"
    And the result does not contain "other/doc-001"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: subscriber is not re-notified when Firestore emits the same value on reconnect
    Given a subscriber is attached to "tasks/task-fs-030" with current value title "Stable"
    When the FakeFirestore emits the same document again (e.g. after reconnect)
    Then the subscriber is not called a second time
    And the adapter subscriber call count for "tasks/task-fs-030" is 1

  Scenario: unsubscribing releases the Firestore onSnapshot listener
    Given a subscriber is attached to "tasks/task-fs-040"
    When I call the unsubscribe function
    Then the FakeFirestore listener count for "tasks/task-fs-040" is 0
    And subsequent writes to "tasks/task-fs-040" do not call the subscriber

  Scenario: write failure propagates the Firestore error to the caller
    Given the FakeFirestore is configured to reject writes with "PERMISSION_DENIED"
    When I call adapter.write("tasks/task-fs-050", { "id": "task-fs-050", "title": "Should fail", "done": false, "priority": 1, "createdAt": "2026-06-23T14:00:00Z" })
    Then the write rejects with error containing "PERMISSION_DENIED"
    And the adapter does not update its internal cache
