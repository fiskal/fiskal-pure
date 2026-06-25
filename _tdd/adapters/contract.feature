# ---------------------------------------------------------------------------
# Adapter Contract — the canonical behaviour EVERY adapter must satisfy.
#
# Per-adapter feature files (memory, firestore, gun, cloudkit, userdefaults)
# cover transport-specific detail. THIS file is the shared contract: the same
# observable behaviour, asserted identically across all adapters on both
# platforms, so a write logged on one adapter round-trips on any other.
#
# Each Scenario Outline runs against every adapter in its Examples table.
# Tags mark legitimate divergence:
#   @sync      delivers synchronously on attach / write (Memory)
#   @async     delivers eventually (Firestore, CloudKit, Gun, UserDefaults push)
#   @eventual  last-write-wins / convergent, not linearizable (Gun P2P)
#   @swift @ts platform-scoped
#   @[MANUAL]  requires a live backing service / device
#
# Adapter identifiers used in Examples:
#   memory-ts | firestore-ts | gun-ts | memory-swift | cloudkit-swift | userdefaults-swift
# ---------------------------------------------------------------------------

Feature: Adapter contract — all adapters present the same behaviour

  # -------------------------------------------------------------------------
  # 1. Subscribe delivery contract
  # -------------------------------------------------------------------------

  Scenario Outline: subscribe delivers the current state as a Doc list on attach
    Given a "<adapter>" seeded with document "tasks/task-1"
    When a subscriber attaches to query path "tasks"
    Then the subscriber receives a list containing "tasks/task-1"
    And the delivered value is always an array, never null and never a bare document

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |
      | gun-ts             |

  Scenario Outline: subscribe to an absent single document delivers not-found, not loading
    Given a "<adapter>" with no document at "tasks/missing"
    When a subscriber attaches to query id "tasks/missing"
    Then the subscriber receives the not-found state (TS null / Swift .missing), distinct from the loading state

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  # -------------------------------------------------------------------------
  # 2. Write + notify contract
  # -------------------------------------------------------------------------

  Scenario Outline: write stores the value and notifies the subscriber
    Given a "<adapter>" with a subscriber on path "tasks"
    When the descriptor { path: "tasks", id: "tasks/task-9", fields: { title: "New" } } is written
    Then the subscriber is notified with a list containing "tasks/task-9"

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |
      | gun-ts             |

  Scenario Outline: omitting merge patches existing fields (preserves untouched ones)
    Given a "<adapter>" holding { id: "tasks/task-1", title: "Deploy", status: "active" }
    When the descriptor { path: "tasks", id: "tasks/task-1", fields: { status: "archived" } } is written with no merge flag
    Then the stored document is { id: "tasks/task-1", title: "Deploy", status: "archived" }

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  Scenario Outline: merge false fully replaces the document
    Given a "<adapter>" holding { id: "tasks/task-1", title: "Deploy", status: "active" }
    When the descriptor { path: "tasks", id: "tasks/task-1", fields: { title: "Deploy" }, merge: false } is written
    Then the stored document is { id: "tasks/task-1", title: "Deploy" } with status dropped

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |

  Scenario Outline: delete removes the document and notifies the subscriber
    Given a "<adapter>" holding "tasks/task-1" with a subscriber on path "tasks"
    When the descriptor { path: "tasks", id: "tasks/task-1", delete: true } is written
    Then "tasks/task-1" is absent and the subscriber is notified with a list that excludes it

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  # -------------------------------------------------------------------------
  # 3. Atomic transaction contract
  # -------------------------------------------------------------------------

  Scenario Outline: an array of descriptors applies all-or-none
    Given a "<adapter>" with documents "accounts/a" and "accounts/b"
    When a two-write transaction debits "accounts/a" and credits "accounts/b"
    And the second write is forced to fail
    Then neither balance changed (the whole transaction rolled back)

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |

  # -------------------------------------------------------------------------
  # 4. Atomic field operations — identical results across adapters
  # -------------------------------------------------------------------------

  Scenario Outline: increment accumulates whether the counter is stored int or float
    Given a "<adapter>" holding { id: "posts/p1", views: 41 }
    When the descriptor { path: "posts", id: "posts/p1", fields: { views: ::increment(1) } } is written
    Then "posts/p1".views equals 42 and never resets to the delta

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  Scenario Outline: a multi-value arrayUnion is a single op (cross-platform replay parity)
    Given a "<adapter>" holding { id: "tasks/task-1", tags: ["a"] }
    When the descriptor { path: "tasks", id: "tasks/task-1", fields: { tags: ::arrayUnion("b", "c") } } is written
    Then "tasks/task-1".tags equals ["a", "b", "c"]
    And the operation is recorded as ONE descriptor (not three), matching the other platform byte-for-byte in the log

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |

  Scenario Outline: serverTimestamp is stored as one comparable, orderable value
    Given a "<adapter>"
    When two documents are written one after another with field updatedAt: ::serverTimestamp()
    Then both updatedAt values are the same comparable type and the later write sorts after the earlier

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | userdefaults-swift |

  # -------------------------------------------------------------------------
  # 5. Isolation, scoping, and listing
  # -------------------------------------------------------------------------

  Scenario Outline: two independent instances/suites do not share state
    Given two "<adapter>" instances on different roots
    When a document is written to the first
    Then the second instance does not observe it

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | userdefaults-swift |

  Scenario Outline: listing by path prefix returns only matching documents
    Given a "<adapter>" holding "tasks/task-1", "tasks/task-2", and "sprints/s1"
    When the path "tasks" is queried
    Then exactly "tasks/task-1" and "tasks/task-2" are returned

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  # -------------------------------------------------------------------------
  # 6. Subscription hygiene — no leaks, no over-fire (memory-safety contract)
  # -------------------------------------------------------------------------

  Scenario Outline: a write to an unrelated path does not wake a scoped subscriber
    Given a "<adapter>" with a subscriber scoped to path "tasks"
    When a document is written to path "sprints"
    Then the "tasks" subscriber is not notified

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |

  Scenario Outline: unsubscribing releases the underlying listener
    Given a "<adapter>" with an attached subscriber
    When the returned unsubscribe handle is called
    Then no further writes notify that subscriber and the underlying listener is released

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |
      | firestore-ts       |
      | cloudkit-swift     |
      | userdefaults-swift |
      | gun-ts             |

  Scenario Outline: dropping the cancel handle without calling it does not leak the subscriber
    Given a "<adapter>" where a subscription is created and its cancel handle is discarded
    When the owning scope is torn down (view unmount / task cancellation)
    Then the subscriber is deregistered and stops receiving notifications

    Examples:
      | adapter            |
      | memory-swift       |
      | userdefaults-swift |
      | cloudkit-swift     |

  Scenario Outline: subscriber count returns to steady state after repeated attach/detach
    Given a "<adapter>" with zero subscribers
    When a subscriber attaches and detaches 10 times in a row
    Then the active subscriber count for the query is exactly zero at the end
    And never exceeds one at any point for a single logical consumer

    Examples:
      | adapter            |
      | memory-ts          |
      | memory-swift       |

  # -------------------------------------------------------------------------
  # 7. Failure surfaces — nothing vanishes silently
  # -------------------------------------------------------------------------

  Scenario Outline: a write whose value is not representable surfaces an error instead of vanishing
    Given a "<adapter>"
    When a write carries a value the backing store cannot represent
    Then the write raises a descriptive error and is recorded in the errors collection
    And the document is not partially or silently persisted

    Examples:
      | adapter            |
      | memory-ts          |
      | userdefaults-swift |
      | firestore-ts       |

  Scenario Outline: remote write failure reverts optimistic state to the adapter source of truth
    Given a "<adapter>" with document "tasks/task-1" optimistically updated in the in-memory cache
    When the remote write is rejected
    Then an error is raised and recorded in the errors collection
    And the in-memory document is reverted to the value the adapter reports as authoritative

    Examples:
      | adapter            |
      | firestore-ts       |
      | cloudkit-swift     |

  # -------------------------------------------------------------------------
  # 8. Documented divergences — asserted, not hidden
  # -------------------------------------------------------------------------

  @eventual @ts
  Scenario: Gun is last-write-wins and convergent, not linearizable
    Given two Gun peers writing the same field concurrently
    When both writes converge
    Then both peers settle on the same value by Gun's CRDT rule
    But intermediate ordering is not guaranteed, unlike the transactional adapters

  @async @[MANUAL]
  Scenario: async adapters deliver the initial value within the documented latency budget
    Given a live Firestore or CloudKit backing store
    When a subscriber attaches
    Then the initial value is delivered within the adapter's stated budget, not synchronously
