Feature: Errors as a root-level collection (ADR-0008)

  When a write fails (network, permission, validation, adapter rejection),
  the store writes a plain ErrorDoc to the "errors" collection.
  Any component can subscribe to the errors collection using the standard query system.
  The three-state wireView contract (undefined / null / Doc) is unchanged.

  Background:
    Given a store backed by a FailingAdapter that rejects all writes with "Network unavailable"
    And the store has the following docs in cache:
      | key             | value                                                |
      | tasks/task-alpha | { "id": "task-alpha", "status": "active" }          |

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: write failure writes ErrorDoc to errors collection
    Given a mutate named "ArchiveTask" that writes to "tasks/task-alpha"
    When I call ArchiveTask and it fails
    Then the errors collection contains exactly one document
    And the error document has:
      | field    | value                     |
      | action   | "ArchiveTask"             |
      | kind     | "network"                 |
      | resolved | false                     |
      | message  | "Network unavailable"     |

  Scenario: optimistic cache update is rolled back when write fails
    Given a mutate that sets status = "archived" on "tasks/task-alpha"
    When the mutate fails
    Then "tasks/task-alpha" status is still "active" in the cache

  Scenario: any component can subscribe to all unresolved errors
    Given a wireView wiring { errors: { path: "errors", where: { resolved: false } } }
    When a write fails
    Then the wired component receives the error document in its errors prop

  Scenario: action-scoped error subscription receives only matching errors
    Given a WiredArchiveButton wired with:
      """
      { error: { path: "errors", where: { action: "ArchiveTask", resolved: false } } }
      """
    When ArchiveTask fails
    Then the WiredArchiveButton receives the error in its error prop
    When a different action "DeleteTask" fails
    Then the WiredArchiveButton does NOT receive DeleteTask's error

  Scenario: error kind "permission" is set for permission-denied errors
    Given a FailingAdapter that rejects with "Missing or insufficient permissions"
    When a mutate fails
    Then the ErrorDoc has kind = "permission"

  Scenario: error kind "conflict" is set for conflict errors
    Given a FailingAdapter that rejects with "conflict: document was modified"
    When a mutate fails
    Then the ErrorDoc has kind = "conflict"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: successful write does not create any ErrorDoc
    Given a store backed by a working MemoryAdapter
    And a mutate that writes to "tasks"
    When the mutate succeeds
    Then the errors collection is empty

  Scenario: multiple failures accumulate independent ErrorDocs
    When ArchiveTask fails twice with different task IDs
    Then the errors collection contains exactly two documents
    And each ErrorDoc has a unique id

  Scenario: errors collection is never synced to the remote adapter
    When a write fails and an ErrorDoc is written
    Then the FailingAdapter.write is NOT called with the ErrorDoc
    And the ErrorDoc exists only in the local in-memory cache

  Scenario: resolved errors are excluded from { where: { resolved: false } } queries
    Given the errors collection contains one error with resolved = false
    When dismissError sets resolved = true on that error
    Then a query { path: "errors", where: { resolved: false } } returns empty

  Scenario: the errors collection does NOT appear in store.history.log()
    Given a mutate that fails
    When I read store.history.log()
    Then the returned entries do NOT include the failed action or the ErrorDoc write

  Scenario: store.history.log() only records confirmed writes
    Given a mutate that succeeds
    When I read store.history.log()
    Then the entry for that action appears in the log

  Scenario: error doc records the payload that caused the failure
    Given a mutate "ArchiveTask" called with payload { "id": "tasks/task-alpha" }
    When the mutate fails
    Then the ErrorDoc has payload.id = "tasks/task-alpha"

  # ---------------------------------------------------------------------------
  # Tier 2 — unknown / unregistered action is observable, not a silent no-op (F-19)
  # The replay premise requires every dispatched action to be accounted for.
  # ---------------------------------------------------------------------------

  Scenario: dispatching an action name that is not registered does not silently succeed
    # F-19: a typo'd or unregistered action currently no-ops with no history entry
    # and no error. It must be surfaced (ErrorDoc kind "unknown-action") so the
    # replay log is never silently incomplete.
    Given no mutate is registered under the name "ArchiveTaks" (a typo of "ArchiveTask")
    When a wired component dispatches "ArchiveTaks"
    Then the dispatch does not silently succeed
    And an ErrorDoc is recorded identifying the unknown action "ArchiveTaks"
    And no phantom history entry is recorded for the unknown action

  Scenario: a successfully dispatched, registered action always produces a history entry
    # F-19 inverse: a valid action must always be logged, so the replay log is complete.
    Given a mutate is registered under the name "ArchiveTask"
    And the store is backed by a working MemoryAdapter
    When a wired component dispatches "ArchiveTask" and it succeeds
    Then exactly one history entry is recorded for "ArchiveTask"

  Scenario: an action registered under the same name in two configs is not silently shadowed
    # F-19 secondary: the same action name across two BackingStoreConfigs must not
    # have only the first config fire while the second is silently dropped.
    Given the action "SyncTask" is registered in both config "primary" and config "mirror"
    When "SyncTask" is dispatched
    Then both registrations run (the second is not silently shadowed by the first)
