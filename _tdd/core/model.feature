Feature: Model enrichment — compute closures (ADR-0007)

  A Model registered with createStore provides two kinds of compute, both
  expressed as CLOSURES that take the document as their first argument:
  - Simple:    (doc) => value             — derived from own fields, read as a plain value
  - Dependent: (doc) => (sibling) => value — returns a function the view calls with a sibling

  Enrichment runs at read time (store.enrich): each closure is invoked and its result
  is assigned as a plain property on a NEW doc object. Because results are plain
  properties (not getters bound to `this`), they are safe to destructure with no
  `this` footgun. Enrichment is transparent — components never know the difference
  between raw and enriched docs.

  Background:
    Given a TaskModel with:
      | compute    | type      | implementation                                       |
      | titleUpper | simple    | (doc) => doc.title.toUpperCase()                     |
      | isOwnedBy  | dependent | (doc) => (userId) => doc.ownerId === userId          |
    And a store created with models: { tasks: TaskModel }
    And seed data:
      """
      { "id": "tasks/task-1", "title": "deploy to production", "ownerId": "user-42" }
      """

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: simple compute is available as a plain value on enriched doc
    When wireView delivers the document "tasks/task-1" to a component
    Then the component receives task.titleUpper = "DEPLOY TO PRODUCTION"
    And the component does NOT need to call titleUpper() — it is a plain string

  Scenario: simple compute reflects the field value at enrichment time
    Given the store enriches task-1 with the TaskModel
    When titleUpper is read off the enriched doc
    Then it equals the uppercased version of the task.title field at the time of enrichment

  Scenario: dependent compute is callable on the enriched doc with a sibling argument
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
    And SprintModel has a simple compute shortName: (doc) => doc.name.slice(0, 3).toUpperCase()
    When I enrich a tasks doc
    Then it has titleUpper but NOT shortName
    When I enrich a sprints doc with name "alpha sprint"
    Then sprint.shortName = "ALP"

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: dependent compute is safe to destructure — no this footgun
    # CORRECTED BEHAVIOUR: compute is now a closure (doc) => (sibling) => value,
    # eagerly assigned as a plain property. It closes over doc, not `this`, so
    # destructuring it off the doc and calling it standalone still works.
    Given the store enriches task-1 with the TaskModel
    When a developer destructures: const { isOwnedBy } = task
    And calls isOwnedBy("user-42") with no receiver
    Then it returns true (the closure captured doc — there is no `this` to lose)
    And the call does not throw

  Scenario: useRead and wireView enrich identically — same compute properties on both read paths
    # F-07: both public read paths must run store.enrich so an identical query
    # yields docs WITH compute properties through either useRead or wireView.
    Given a component reading task-1 via useRead(store, { type: "doc", key: "tasks/task-1" })
    And a component reading task-1 via wireView wiring { task: { id: "tasks/task-1" } }
    Then both receive task.titleUpper = "DEPLOY TO PRODUCTION"
    And both receive task.isOwnedBy as a callable function
    And neither read path returns a doc with compute properties missing or undefined

  Scenario: a compute closure that throws on one doc does not crash the whole list render
    # F-22: enrichment must isolate a throwing user closure so one malformed doc
    # does not take down every other doc in the collection.
    Given a model whose compute closure does doc.title.toUpperCase() with no guard
    And a collection containing task-1 (has title) and task-bad (missing title)
    When the collection is enriched and delivered to a list component
    Then task-1 is delivered with its computed titleUpper value
    And task-bad is delivered without crashing the enrichment of the other docs
    And the failure is surfaced as a value (e.g. an ErrorDoc or a safe default), not a thrown render

  Scenario: enriched docs are immutable snapshots that do not alias caller state
    # F-22: the enriched doc and any embedded payload must be a fresh copy so a
    # later mutation of the source object cannot rewrite an already-enriched/logged doc.
    Given a raw doc is enriched into an enriched doc
    When the original raw doc's fields are later mutated
    Then the previously enriched doc's fields are unchanged
    And no field of the enriched doc shares a mutable reference with the raw doc

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
