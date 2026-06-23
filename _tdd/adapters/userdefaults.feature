Feature: NSUserDefaultsAdapter — key-value adapter with notification-based subscribe (Swift)

  NSUserDefaultsAdapter wraps UserDefaults. Reads and writes are synchronous.
  Subscribe listens on UserDefaults.didChangeNotification and delivers the
  current value on each change. App Group support allows the widget extension
  to share data with the host app via a named suite.

  Background:
    Given a UserDefaults in-memory suite named "test.fiskal.pure"
    And a NSUserDefaultsAdapter constructed with that suite

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: write stores a Codable value and read retrieves it immediately
    When I call adapter.write("tasks/task-ud-001", Task(id: "task-ud-001", title: "UserDefaults task", done: false, priority: 1, createdAt: Date(iso: "2026-06-23T20:00:00Z")))
    And I call adapter.read("tasks/task-ud-001")
    Then the result equals Task(id: "task-ud-001", title: "UserDefaults task", done: false, priority: 1, createdAt: Date(iso: "2026-06-23T20:00:00Z"))

  Scenario: subscribe delivers the current value on attach if key already exists
    Given the suite contains "tasks/task-ud-002" with title "Existing"
    When I subscribe to "tasks/task-ud-002" via the adapter
    Then the subscriber receives Task with title "Existing" immediately

  Scenario: subscriber is called after write via UserDefaults.didChangeNotification
    Given a subscriber is attached to "tasks/task-ud-003"
    When I call adapter.write("tasks/task-ud-003", Task(id: "task-ud-003", title: "Notified", done: true, priority: 2, createdAt: Date(iso: "2026-06-23T20:10:00Z")))
    Then UserDefaults.didChangeNotification fires
    And the subscriber receives Task with title "Notified"

  Scenario: overwriting a key delivers the updated value to the subscriber
    Given the suite contains "tasks/task-ud-010" with title "First"
    And a subscriber is attached to "tasks/task-ud-010"
    When I call adapter.write("tasks/task-ud-010", Task(id: "task-ud-010", title: "Second", done: false, priority: 1, createdAt: Date(iso: "2026-06-23T20:15:00Z")))
    Then the subscriber receives Task with title "Second"
    And the subscriber call count is 1 (only the new value, not re-delivered on attach)

  Scenario: listing keys by prefix returns only matching keys
    Given the suite contains:
      | key                | title         |
      | tasks/task-ud-020  | List A        |
      | tasks/task-ud-021  | List B        |
      | settings/theme     | dark          |
    When I call adapter.list("tasks/")
    Then the result contains "tasks/task-ud-020" and "tasks/task-ud-021"
    And the result does not contain "settings/theme"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: two adapters on different suites are isolated
    Given a second NSUserDefaultsAdapter on suite "test.fiskal.widget"
    When I write "tasks/task-ud-030" with title "Suite A" to the first adapter
    Then reading "tasks/task-ud-030" from the second adapter returns nil
    And no notification fires in the second suite

  Scenario: adapter constructed with a nil suite name fails fast with a descriptive error
    When I construct a NSUserDefaultsAdapter with suite name nil
    Then an error is thrown containing "NSUserDefaultsAdapter requires a non-nil suite name"
    And no UserDefaults suite is created

  Scenario: reading an absent key returns nil without throwing
    When I call adapter.read("tasks/does-not-exist-ud")
    Then the result is nil
    And no error is thrown

  Scenario: write then read round-trip for all supported field types
    When I write a Task with:
      | field     | type      | value                        |
      | id        | String    | task-ud-types                |
      | title     | String    | Type round-trip              |
      | done      | Bool      | true                         |
      | priority  | Int       | 5                            |
      | createdAt | Date(ISO) | 2026-06-23T21:00:00Z        |
    Then reading "tasks/task-ud-types" returns the same values for all fields
