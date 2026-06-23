Feature: GunAdapter — GunJS-backed P2P adapter

  GunAdapter wraps GunJS. Subscribe opens a gun.get(key).on() listener;
  write calls gun.get(key).put(). A FakeGun is injected for unit tests.
  Physical multi-device P2P relay scenarios are tagged [MANUAL].

  Background:
    Given a FakeGun instance
    And a GunAdapter constructed with the FakeGun

  # ---------------------------------------------------------------------------
  # Tier 1 — happy path
  # ---------------------------------------------------------------------------

  Scenario: subscribe receives the current value when the key exists in the Gun graph
    Given the FakeGun graph contains key "tasks/task-gun-001":
      """
      { "id": "task-gun-001", "title": "Sync across devices", "done": false, "priority": 1, "createdAt": "2026-06-23T15:00:00Z" }
      """
    When I subscribe to "tasks/task-gun-001" via the adapter
    Then the subscriber receives:
      """
      { "id": "task-gun-001", "title": "Sync across devices", "done": false, "priority": 1, "createdAt": "2026-06-23T15:00:00Z" }
      """

  Scenario: write calls gun.put and the subscriber receives the update
    Given a subscriber is attached to "tasks/task-gun-002"
    When I call adapter.write("tasks/task-gun-002", { "id": "task-gun-002", "title": "Local-first write", "done": false, "priority": 2, "createdAt": "2026-06-23T15:10:00Z" })
    Then the FakeGun graph contains "tasks/task-gun-002" with title "Local-first write"
    And the subscriber is called with title "Local-first write"

  Scenario: configure relay peers at construction time
    Given a GunAdapter constructed with peers ["https://relay.fiskal.app/gun"]
    When the adapter is initialised
    Then the FakeGun peers list contains "https://relay.fiskal.app/gun"

  Scenario: subscriber continues receiving updates after initial value delivery
    Given a subscriber is attached to "tasks/task-gun-003"
    And the FakeGun emits the initial value with done = false
    When the FakeGun emits a second update with done = true
    Then the subscriber is called twice in total
    And the second call has done = true

  # ---------------------------------------------------------------------------
  # Tier 2 — edge cases
  # ---------------------------------------------------------------------------

  Scenario: GunJS soul metadata (_._) is stripped from the delivered value
    Given the FakeGun emits a raw Gun node at "tasks/task-gun-010":
      """
      {
        "id": "task-gun-010",
        "title": "Strip meta",
        "done": false,
        "priority": 1,
        "createdAt": "2026-06-23T15:30:00Z",
        "_": { "#": "tasks/task-gun-010", ">": { "id": 1719151800000 } }
      }
      """
    When the adapter delivers the value to its subscriber
    Then the delivered value does not contain the "_" key
    And the delivered value equals:
      """
      { "id": "task-gun-010", "title": "Strip meta", "done": false, "priority": 1, "createdAt": "2026-06-23T15:30:00Z" }
      """

  Scenario: adapter reconnects subscription after peer disconnect and re-delivers updates
    Given a subscriber is attached to "tasks/task-gun-020"
    And the FakeGun simulates a peer disconnect
    When the FakeGun simulates peer reconnect and emits a new value with done = true
    Then the subscriber receives the new value with done = true
    And the subscription is re-established without caller intervention

  # ---------------------------------------------------------------------------
  # [MANUAL] — requires physical multi-device relay
  # ---------------------------------------------------------------------------

  Scenario: [MANUAL] peer A writes a task and peer B receives it within 3 seconds
    Given two physical devices both connected to relay "https://relay.fiskal.app/gun"
    And peer A has a GunAdapter subscribed to "tasks/task-gun-live"
    When peer B writes { "id": "task-gun-live", "title": "Cross-device", "done": false, "priority": 1, "createdAt": "2026-06-23T16:00:00Z" }
    Then peer A's subscriber receives the value within 3 seconds

  Scenario: [MANUAL] Gun graph survives relay restart and re-delivers pending writes on reconnect
    Given peer A wrote a value to the relay 30 seconds ago
    And the relay was restarted 10 seconds ago
    When peer B comes online and subscribes to the key
    Then peer B receives peer A's value from the relay
