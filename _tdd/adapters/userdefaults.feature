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

  # ---------------------------------------------------------------------------
  # Tier 2 — numeric and timestamp value-model correctness (F-13)
  # ---------------------------------------------------------------------------

  Scenario: incrementing a counter seeded as an Int does not reset to the delta
    # F-13: an Int boxed in Any does not `as? Double`-bridge in Swift, so the cast
    # fails and the counter resets. An increment must accumulate regardless of whether
    # the stored value was written as an Int or a Double.
    Given the suite contains "counters/c-1" with count = 5 (written as an integer)
    When I apply ::increment of 3 to "counters/c-1".count
    Then "counters/c-1".count = 8 (not 3)
    And the increment does not silently reset the counter to the delta

  Scenario: a serverTimestamp value is stored and read back as a comparable, orderable value
    # F-13: serverTimestamp is stored as three different runtime types across adapters,
    # breaking cross-adapter orderBy. The stored form must be comparable for ordering.
    Given two docs written with ::serverTimestamp values one second apart
    When I read the collection ordered by that timestamp field
    Then the two docs sort in chronological order
    And the timestamp comparison does not silently drop or mis-sort across adapters

  Scenario: a write whose value is not JSON-serialisable does not silently vanish
    # F-13: JSONSerialization via try? swallows non-encodable values, dropping the
    # whole write with no error. A non-serialisable field must surface an error.
    Given a write to "tasks/task-ud-nonjson" carrying a field value that cannot be JSON-encoded
    When the adapter attempts the write
    Then the write does not silently disappear
    And either the value is normalised to a serialisable form OR an error is surfaced to the caller

  # ---------------------------------------------------------------------------
  # Tier 2 — subscriber scoping and lifecycle (F-16)
  # ---------------------------------------------------------------------------

  Scenario: an unrelated key write does not wake a subscriber scoped to a different key
    # F-16 over-fire: the suite-wide didChangeNotification must not re-fire every
    # subscriber. A subscriber on tasks/A must not be called when settings/theme changes.
    Given a subscriber is attached to "tasks/task-ud-050"
    When I write an unrelated key "settings/theme" with value "dark"
    Then the subscriber for "tasks/task-ud-050" is NOT called
    And its call count remains 0

  Scenario: dropping a subscription's cancel handle without calling it does not leak the subscriber
    # F-16 leak: a (query, onChange) registration must be cleaned up on teardown so a
    # dropped cancel handle does not retain the subscriber forever.
    Given a subscriber is attached to "tasks/task-ud-060" and its cancel handle is dropped
    When the subscriber's owner is deallocated
    Then the adapter no longer retains the dropped subscriber
    And subsequent writes do not invoke the leaked callback
