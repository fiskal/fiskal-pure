Feature: Model enrichment — compute getters and computer methods (ADR-0007)

  A Model registered with createStore provides two kinds of compute:
  - Getters: derived from own fields, accessed as plain values (no call)
  - Computers: methods taking a sibling document argument, called as doc.method(sibling)

  Enrichment is applied via Object.defineProperties so getter descriptors are live.
  Enrichment is transparent — components never know the difference between raw and enriched docs.

  Background:
    Given a TaskModel with:
      | compute    | type     | implementation                                      |
      | titleUpper | getter   | return this.title.toUpperCase()                     |
      | isOwnedBy  | computer | (userId) => return this.ownerId === userId           |
    And a store created with models: { tasks: TaskModel }
    And seed data:
      """
      { "id": "tasks/task-1", "title": "deploy to production", "ownerId": "user-42" }
      """

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: getter is available as a plain value on enriched doc
    When wireView delivers the document "tasks/task-1" to a component
    Then the component receives task.titleUpper = "DEPLOY TO PRODUCTION"
    And the component does NOT need to call titleUpper() — it is a plain string

  Scenario: getter reflects the current field value (not a snapshot)
    Given the store enriches task-1 with the TaskModel
    When titleUpper is accessed
    Then it returns the uppercased version of the current task.title field

  Scenario: computer method is callable on the enriched doc with a sibling argument
    Given the store enriches task-1 with the TaskModel
    When the component calls task.isOwnedBy("user-42")
    Then it returns true
    When the component calls task.isOwnedBy("user-99")
    Then it returns false

  Scenario: store.enrich is identity when no model is registered for the collection
    Given a store with no models registered
    When I call store.enrich("other", { "id": "other/x", "title": "no-op" })
    Then the returned doc is the exact same reference as the input doc

  Scenario: store.enrich is identity when model has no compute object
    Given a store with a model for "tasks" that has only a schema and no compute
    When I call store.enrich("tasks", { "id": "tasks/x", "title": "schema-only" })
    Then the returned doc is the exact same reference as the input doc

  Scenario: correct model is applied per collection
    Given a store with models: { tasks: TaskModel, sprints: SprintModel }
    And SprintModel has a getter shortName that returns name.slice(0, 3).toUpperCase()
    When I enrich a tasks doc
    Then it has titleUpper but NOT shortName
    When I enrich a sprints doc with name "alpha sprint"
    Then sprint.shortName = "ALP"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: getter handles missing field gracefully (no throw)
    Given the store enriches a doc that is missing the "title" field
    When the component reads task.titleUpper
    Then it returns an empty string or a safe default — it does not throw

  Scenario: computer method called as standalone function loses this (documented footgun)
    Given the store enriches task-1 with the TaskModel
    When a developer destructures: const { isOwnedBy } = task
    And calls isOwnedBy("user-42")
    Then this === undefined in strict mode and the call throws or returns wrong result
    And [MANUAL] the README and EDGE-CASES.md must document this constraint

  Scenario: enrichment does not mutate the original raw doc
    Given a raw doc object
    When store.enrich is called
    Then the original raw doc object is unchanged
    And the enriched doc is a new object with compute properties added

  Scenario: enriched docs from multiple collections share no compute descriptors
    Given a tasks doc enriched with TaskModel
    And a sprints doc enriched with SprintModel
    Then tasks doc does NOT have SprintModel compute descriptors
    And sprints doc does NOT have TaskModel compute descriptors
