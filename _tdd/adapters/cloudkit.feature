Feature: CloudKitAdapter — CloudKit-backed adapter (Swift)

  CloudKitAdapter wraps CKDatabase and CKSubscription. Subscribe registers a
  server-side subscription and receives updates via push notifications.
  Write uses CKModifyRecordsOperation. A FakeCKDatabase is injected for
  unit tests. Physical push delivery scenarios are tagged [MANUAL].

  Background:
    Given a FakeCKDatabase for the private zone "fiskal.tasks"
    And a CloudKitAdapter constructed with the FakeCKDatabase

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: subscribe fetches the initial record and registers a CKQuerySubscription
    Given the FakeCKDatabase contains record "task-ck-001" in zone "fiskal.tasks":
      """
      { "id": "task-ck-001", "title": "iCloud task", "done": 0, "priority": 1, "createdAt": "2026-06-23T17:00:00Z" }
      """
    When I subscribe to key "tasks/task-ck-001" via the adapter
    Then the subscriber receives a Task with title "iCloud task"
    And a CKQuerySubscription is registered on the FakeCKDatabase for zone "fiskal.tasks"

  Scenario: write saves the record using CKModifyRecordsOperation
    When I call adapter.write("tasks/task-ck-002", Task(id: "task-ck-002", title: "CloudKit write", done: false, priority: 2, createdAt: Date(iso: "2026-06-23T17:10:00Z")))
    Then the FakeCKDatabase contains record "task-ck-002" with title "CloudKit write"
    And the FakeCKDatabase modify operation count is 1

  Scenario: atomic batch write uses a single CKModifyRecordsOperation with multiple records
    When I call adapter.writeBatch([
      Task(id: "task-ck-010", title: "Batch CK A", done: false, priority: 3, createdAt: Date(iso: "2026-06-23T18:00:00Z")),
      Task(id: "task-ck-011", title: "Batch CK B", done: true,  priority: 4, createdAt: Date(iso: "2026-06-23T18:01:00Z"))
    ])
    Then the FakeCKDatabase contains "task-ck-010" and "task-ck-011"
    And the FakeCKDatabase modify operation count is 1 (single batch)

  Scenario: query predicate filters records server-side before delivery
    Given the FakeCKDatabase contains:
      | record id    | done |
      | task-ck-020  | 0    |
      | task-ck-021  | 1    |
      | task-ck-022  | 0    |
    When I call adapter.list(prefix: "tasks/", predicate: NSPredicate(format: "done == 0"))
    Then the result contains "task-ck-020" and "task-ck-022"
    And the result does not contain "task-ck-021"

  Scenario: subscriber is notified via FakeCKDatabase push delivery simulation
    Given a subscriber is attached to "tasks/task-ck-030"
    When the FakeCKDatabase simulates a push notification indicating task-ck-030 changed with done = 1
    Then the adapter fetches the updated record
    And the subscriber receives the updated Task with done = true

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: write with a record conflict (server version wins) delivers server record to subscriber
    Given the FakeCKDatabase is configured to return a server-record error for "task-ck-040" with server title "Server wins"
    When I call adapter.write("tasks/task-ck-040", Task(id: "task-ck-040", title: "Client version", done: false, priority: 1, createdAt: Date(iso: "2026-06-23T19:00:00Z")))
    Then the write resolves using the server record
    And the subscriber for "tasks/task-ck-040" receives title "Server wins"

  Scenario: adapter initialises in the shared zone for App Group widget sharing
    Given a CloudKitAdapter constructed with zone "fiskal.shared"
    When I call adapter.write("widget/badge", WidgetBadgeRecord(daily: 42.50))
    Then the FakeCKDatabase record is saved in zone "fiskal.shared"

  Scenario: CKError.networkUnavailable causes write to queue locally and retry on next sync
    Given the FakeCKDatabase is configured to throw CKError.networkUnavailable
    When I call adapter.write("tasks/task-ck-050", Task(id: "task-ck-050", title: "Queued", done: false, priority: 1, createdAt: Date(iso: "2026-06-23T19:30:00Z")))
    Then the write is added to the local retry queue
    And no error is propagated to the caller
    And when network becomes available, the adapter retries the write

  # ---------------------------------------------------------------------------
  # [MANUAL] — requires device + production CloudKit
  # ---------------------------------------------------------------------------

  Scenario: [MANUAL] server-side CKQuerySubscription delivers push to device within 5 seconds
    Given a real iOS device subscribed to zone "fiskal.tasks"
    When a record is written to the production CKDatabase from a second device
    Then the first device receives a push notification within 5 seconds
    And the subscriber is called with the updated record
