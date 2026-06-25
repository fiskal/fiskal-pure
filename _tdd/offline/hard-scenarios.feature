Feature: Hard offline-first scenarios
  # The cases that break Redux, Zustand, Jotai, and Swift state management in practice.
  # Sourced from real blog post complaints, GitHub issue trackers, and postmortems.
  # Each scenario is [SKIP] at planning time — unskip one at a time when implementing.
  #
  # Organised by failure class:
  #   1. Optimistic update divergence
  #   2. Offline write queue
  #   3. Cross-client conflict
  #   4. Dependent writes
  #   5. Entity lifecycle
  #   6. Multi-step transaction rollback
  #   7. Pagination + local mutation
  #   8. Derived / computed state staleness
  #   9. Subscription lifecycle
  #  10. Schema migration
  #  11. UI state / domain state boundary

  Background:
    Given a store with MemoryAdapter seeded with:
      | id     | path    | title                | status  | assignee | balance | version |
      | item-1 | tasks   | Deploy to production | active  | alice    |         |         |
      | item-2 | tasks   | Write release notes  | active  | bob      |         |         |
      | acct-1 | accounts| Alice checking       |         |          | 500.00  | 1       |
      | acct-2 | accounts| Bob checking         |         |          | 200.00  | 1       |
    And the network is initially online

  # ---------------------------------------------------------------------------
  # 1. Optimistic update divergence
  #    Redux blog: "our optimistic reducer assumed the write would succeed — the
  #    server returned different data and we had to reconcile manually"
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Server returns enriched data that differs from the optimistic write
    # The classic Redux pain point: write id: item-1 status: done,
    # server also sets completedAt and updatedBy fields the client didn't know about.
    # Without automatic reconciliation, the UI shows the optimistic (wrong) version.
    Given the user fires "completeTask" with id: "item-1"
    And the cache immediately shows item-1.status = "done"
    When the server responds with:
      """
      { "id": "item-1", "status": "done", "completedAt": 1750000060, "updatedBy": "system" }
      """
    Then item-1.completedAt = 1750000060 in the cache
    And item-1.updatedBy = "system" in the cache
    And any component subscribed to item-1 re-renders exactly once with the reconciled data

  @[SKIP]
  Scenario: Server rejects the write and rolls back the optimistic state
    # Jotai blog: "derived atoms didn't update after rollback because the original atom
    # was reset but derived atoms cached the stale computed value"
    Given the user fires "archiveTask" with id: "item-1"
    And the cache immediately shows item-1.status = "archived"
    And a derived query for active tasks no longer includes item-1
    When the server responds with 403 Forbidden
    Then item-1.status = "active" in the cache
    And a derived query for active tasks includes item-1 again
    And no toast or error state is left orphaned in the UI

  @[SKIP]
  Scenario: Optimistic write succeeds but a concurrent background refresh overwrites it
    # Zustand blog: "background polling reset the store while the user was mid-edit —
    # stale server data silently overwrote the in-progress optimistic state"
    Given the user fires "updateTaskTitle" with id: "item-1" title: "UPDATED"
    And the cache shows item-1.title = "UPDATED"
    When a background subscribe push arrives with item-1.title = "Deploy to production"
    Then the optimistic value "UPDATED" is preserved
    And the background push is not applied while the write is in-flight

  # ---------------------------------------------------------------------------
  # 2. Offline write queue
  #    The cases that break simple "retry the last request" implementations.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Multiple writes queue while offline and replay in the correct order
    # The most common offline-first bug: writes replayed in network-arrival order
    # rather than user-action order, producing a different final state.
    Given the device goes offline
    When the user fires "archiveTask" with id: "item-1"
    And the user fires "unarchiveTask" with id: "item-1"
    And the user fires "archiveTask" with id: "item-1" again
    And the device comes back online
    Then the server receives exactly 3 writes in order: archive → unarchive → archive
    And item-1.status = "archived" after sync

  @[SKIP]
  Scenario: Offline queue fails halfway through and the UI recovers gracefully
    # Redux thunk / saga blogs: "we had no way to partially roll back a multi-write
    # queue — the UI was stuck in an indeterminate state after a partial flush"
    Given the device goes offline
    When the user fires "archiveTask" with id: "item-1"
    And the user fires "archiveTask" with id: "item-2"
    And the device comes back online
    And the first write succeeds
    And the second write fails with 500
    Then item-1.status = "archived" in the cache
    And item-2.status = "active" in the cache (rolled back)
    And the failed write descriptor is available in store.history.log()
    And the UI can surface "Write failed — tap to retry" for item-2 only

  @[SKIP]
  Scenario: Very long offline session — 50+ queued writes — reconnects without data loss
    # Observed in field: apps with simple retry logic silently dropped writes when
    # the queue exceeded an undocumented size limit in the networking layer.
    Given the device goes offline
    When the user creates 52 tasks in sequence
    And the device comes back online
    Then all 52 writes are flushed to the server in order
    And the cache contains all 52 tasks with server-confirmed ids

  @[SKIP]
  Scenario: App is backgrounded mid-queue and killed by the OS
    # iOS: app suspended, queue in memory is lost. Android: process killed.
    # The UI must recover to a consistent state on next launch.
    Given the device goes offline
    And the user fires 3 writes that queue successfully
    When the OS kills the app while the queue is pending
    And the user re-launches the app
    Then the 3 queued writes are re-hydrated from durable storage
    And the cache reflects the optimistic state from the queued writes
    And on reconnect all 3 writes are flushed successfully

  # ---------------------------------------------------------------------------
  # 3. Cross-client conflict
  #    CloudKit, Firestore, GunJS — all surface this differently.
  #    Swift blogs: "we didn't handle CKRecord serverChangeToken correctly"
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Last-write-wins conflict — same field, two clients, both offline
    # The baseline: two clients both change task.status. Last write wins.
    # The loser's write must be rolled back cleanly in the losing client.
    Given client A and client B both go offline with item-1.status = "active"
    When client A fires "completeTask" on item-1 (status → "done")
    And client B fires "archiveTask" on item-1 (status → "archived")
    And both clients come back online
    And the server applies last-write-wins with client B winning
    Then client A's cache shows item-1.status = "archived"
    And client A's optimistic "done" is rolled back
    And the write that lost is recorded in store.history.log() on client A

  @[SKIP]
  Scenario: Merge conflict — two clients modify different fields of the same entity
    # Non-overlapping field edits should both survive.
    # Redux blog: "our reducer replaced the whole object — the second client's
    # write silently dropped the first client's field change"
    Given client A and client B both go offline with item-1 as:
      | title        | status | assignee |
      | Deploy       | active | alice    |
    When client A changes item-1.title = "Deploy v2"
    And client B changes item-1.assignee = "carol"
    And both clients sync to the server
    Then the final server state is:
      | title     | status | assignee |
      | Deploy v2 | active | carol    |
    And both clients eventually converge to that state

  @[SKIP]
  Scenario: Delete on one client, edit on another, both offline
    # The hardest conflict: client A deletes an entity while client B is editing it.
    # The editing client must be told the entity no longer exists.
    Given client A and client B both go offline with item-1 present
    When client A fires "deleteTask" on item-1
    And client B fires "updateTaskTitle" on item-1 title: "New title"
    And both clients come back online
    And the server applies client A's delete first
    Then client B receives a "not found" response for its update
    And client B's cache removes item-1
    And any component on client B rendering item-1 receives null and renders "Not found"

  # ---------------------------------------------------------------------------
  # 4. Dependent writes
  #    The case Redux-saga was partially invented to solve. Still hard.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Write B depends on a server-generated ID from write A
    # A task is created (server assigns id "srv-99"), then a comment is
    # immediately created on it. The comment's taskId must be the server id,
    # not the client-generated placeholder.
    Given the user creates a new task with client-id "tmp-1" and title "New task"
    And the cache optimistically stores the task under "tmp-1"
    And the user immediately adds a comment: "First comment" on task "tmp-1"
    When the server confirms the task with id "srv-99"
    Then the cache replaces "tmp-1" with "srv-99"
    And the comment write is updated to reference taskId: "srv-99" before being sent
    And the server receives both writes with the correct server id

  @[SKIP]
  Scenario: Read-then-write race — two clients both compute from stale state
    # The "lost update" problem. Canonical example: both clients read balance 500,
    # both add 100, both write 600. Final balance is 600, not 700.
    # Needs atomic increment, not a read-then-write pattern.
    Given acct-1.balance = 500.00
    And client A and client B both read acct-1.balance as 500.00
    When client A fires a write: acct-1.balance = 600.00 (added $100)
    And client B fires a write: acct-1.balance = 600.00 (added $100)
    Then the server final balance must be 700.00
    And the adapter used an atomic increment operation, not a field set

  @[SKIP]
  Scenario: Transaction spanning two entities must be atomic
    # Transfer $50 from acct-1 to acct-2. Either both writes happen or neither does.
    # The partial-write case (debit succeeds, credit fails) must be handled.
    Given acct-1.balance = 500.00 and acct-2.balance = 200.00
    When the user fires "transfer" with amount: 50 from: "acct-1" to: "acct-2"
    And the server debit of acct-1 succeeds
    And the server credit of acct-2 fails
    Then acct-1.balance is rolled back to 500.00
    And acct-2.balance remains 200.00
    And store.history.log() shows the failed transaction with both write descriptors

  # ---------------------------------------------------------------------------
  # 5. Entity lifecycle
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Entity is deleted remotely while the user is viewing its detail screen
    # One of the most common "blank screen" bugs. The component renders, the entity
    # disappears from the store, the component crashes on null access.
    Given the user is viewing the detail screen for item-1
    When a remote push arrives deleting item-1
    Then the cache no longer contains item-1
    And the detail screen renders a "Not found" state (not a crash)
    And navigating back returns to a list that also no longer includes item-1

  @[SKIP]
  Scenario: Deep link opens a screen for an entity not in the local cache
    # Jotai blog: "async atom threw during suspense when the id wasn't in cache yet —
    # the error boundary caught it but the loading state was never shown"
    Given the local cache contains only items: ["item-1"]
    When the user opens a deep link to item-2's detail screen
    Then the screen renders a loading state while item-2 is fetched
    And once item-2 arrives it renders correctly without a second loading flash
    And the back navigation still works if the fetch fails (item-2 not found)

  @[SKIP]
  Scenario: Entity reappears after deletion (undelete / soft delete undo)
    # Undo a delete — the entity must be reinstated in all live queries.
    Given item-1 is deleted (removed from cache)
    And the active-task query no longer includes item-1
    When the user fires "undeleteTask" on item-1
    Then item-1 reappears in the cache with its original fields
    And the active-task query includes item-1 again
    And all components subscribed to that query re-render with item-1

  # ---------------------------------------------------------------------------
  # 6. Multi-step transaction rollback
  #    Redux saga saga sagas. Wizard forms. The "partial save" problem.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Multi-step form — user completes step 3 of 4, network drops, must roll back
    # The user has filled in 3 screens of data. We wrote steps 1–3 optimistically.
    # The network drops before step 4 finalises. Pressing "Cancel" must undo all 3.
    Given the user starts a "Create project" wizard
    And completes step 1: writes project-draft with title "Alpha"
    And completes step 2: writes sprint-draft linked to project-draft
    And completes step 3: writes 3 task-drafts linked to sprint-draft
    When the device goes offline before step 4 is submitted
    And the user taps "Cancel"
    Then all 5 writes (project + sprint + 3 tasks) are rolled back in the cache
    And store.history.back() steps to before the wizard started
    And no orphaned draft records exist in the cache or on the server

  @[SKIP]
  Scenario: Undo a complex action that touched multiple entities
    # Redux blog: "time travel only worked on single-reducer state slices —
    # cross-slice undo required custom saga logic that we never finished"
    # F-14: store.history.back() must actually REVERT the live cache, not just
    # move a cursor. The CacheSnapshot/restore plumbing must be wired to history nav.
    Given item-1 is in sprint-A and item-2 is in sprint-B
    When the user fires "moveTask" moving item-1 from sprint-A to sprint-B
    Then the cache shows:
      | item-1.sprintId = "sprint-B"                     |
      | sprint-A.taskIds does not include "item-1"       |
      | sprint-B.taskIds includes "item-1"               |
    When the user fires store.history.back()
    Then the cache reverts to:
      | item-1.sprintId = "sprint-A"                     |
      | sprint-A.taskIds includes "item-1"               |
      | sprint-B.taskIds does not include "item-1"       |

  @[SKIP]
  Scenario: Time-travel back then forward restores the post-action cache (redo)
    # F-14: history must support both directions, each re-applying the corresponding
    # cache state. back() reverts; forward() re-applies. Cursor-only movement fails this.
    Given the user fires "completeTask" on item-1 (status active → done)
    And the cache shows item-1.status = "done"
    When the user fires store.history.back()
    Then the cache shows item-1.status = "active" (reverted)
    When the user fires store.history.forward()
    Then the cache shows item-1.status = "done" again (re-applied)
    And subscribers on item-1 are notified on each navigation with the corresponding value

  @[SKIP]
  Scenario: store.history exists and is callable on both platforms
    # F-14: the time-travel API is a documented core selling point but is currently
    # absent on TS and non-functional on Swift. This is the cross-platform contract.
    Given a freshly created store on either platform
    When I call store.history.log()
    Then it returns an array of confirmed write entries (it does not throw "history is undefined")
    And store.history exposes back(), forward(), goto(index), and current

  # ---------------------------------------------------------------------------
  # 7. Pagination + local mutation
  #    Impossible to do cleanly in Redux without significant boilerplate.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: User creates a new item that belongs on page 1 while viewing page 3
    # Pagination + local mutation. The new item must appear in the right position
    # after re-sort, not just appended to the visible page.
    Given the task list is paginated: 10 per page, user is on page 3 (items 21–30)
    And items are sorted by createdAt descending
    When the user creates a new task with createdAt = now (highest timestamp)
    Then the new task appears at position 1 when the user navigates to page 1
    And it is not duplicated or missing on any page

  @[SKIP]
  Scenario: Infinite scroll list receives an insert at the top while the user is mid-scroll
    # The scroll anchor is UI state — it lives in ui/scrollList/view.anchorId.
    # The store owns both the sorted data and the anchor; the component is a pure
    # function of both. No imperative scrollTop manipulation needed.
    Given an infinite-scroll task list with taskIds sorted by createdAt desc
    And ui/scrollList/view.anchorId = "item-38"
    When a new task "item-new" with the latest createdAt is inserted (position 0)
    Then taskIds[0] = "item-new" and "item-38" is now at index 38 (was 37)
    And ui/scrollList/view.anchorId is still "item-38" (unchanged by the insert)
    And the TaskList component renders from anchorId "item-38" in both before and after states
    And no visual jump occurs because the component renders from the anchor, not from scrollTop

  @[SKIP]
  Scenario: User deletes an item from page 2 while viewing page 3
    # The "phantom item" bug: deleting from an earlier page leaves a gap in pagination
    # that causes page 3 to show the last item of page 2 and skip the first of page 4.
    Given 30 tasks exist, 10 per page, user is viewing page 3 (items 21–30)
    When item-15 (page 2) is deleted by a remote push
    Then page 3 now shows items 21–29 plus the first item of what was page 4
    And no item appears twice and no item is skipped

  # ---------------------------------------------------------------------------
  # 8. Derived / computed state staleness
  #    The most-blogged-about Jotai and Reselect failure mode.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: A derived query returns stale data after its source entity is updated
    # Jotai: "derived atom cached result — source atom updated but derived atom
    # didn't re-run because the reference equality check passed on the old shape"
    Given a query Q1 returns tasks where status = "active" — currently ["item-1", "item-2"]
    And a derived query Q2 counts Q1 — currently 2
    When item-2 is archived (status → "archived")
    Then Q1 returns only ["item-1"]
    And Q2 returns 1 without requiring an explicit invalidation call

  @[SKIP]
  Scenario: A compute getter accesses a sibling field that changes independently
    # Zustand stale-closure bug: the getter closes over a stale version of `this`.
    Given item-1 has dueDate = tomorrow and status = "active"
    And item-1.compute.isOverdue uses both dueDate and the current time
    When the system clock passes item-1.dueDate
    Then item-1.isOverdue = true without requiring a write to item-1
    And any component reading item-1.isOverdue re-renders with the new value

  @[SKIP]
  Scenario: Formatted compute getter updates when a sibling raw field changes
    # The date formatting case from PRINCIPLES.md compute section.
    # Ensures compute getters are live, not memoized to construction time.
    Given item-1.createdAt = 1750000000 (some past timestamp)
    And item-1.compute.createdAtDisplay = "Jun 15, 2025"
    When a write updates item-1.createdAt = 1760000000
    Then item-1.compute.createdAtDisplay = "Oct 9, 2025" (new formatted date)
    And no explicit "invalidate computed cache" call is needed

  # ---------------------------------------------------------------------------
  # 9. Subscription lifecycle — memory leaks and double-fire
  #    React + hooks blogs: "we had thousands of orphaned subscriptions after
  #    navigating between screens 20 times in a user session"
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Navigating away and back does not accumulate duplicate subscriptions
    # The most common React subscription leak. Each mount adds a subscriber;
    # unmount doesn't clean up. After 10 navigate-away/back cycles, 10 callbacks fire.
    Given a component wired to the task collection subscribes on mount
    When the user navigates away (component unmounts) 5 times
    And navigates back (component re-mounts) 5 times
    Then exactly 1 subscriber is active for the task collection
    And each write to the task collection triggers exactly 1 callback

  @[SKIP]
  Scenario: Rapid prop change does not create a subscription leak
    # The `taskId` prop changes 10 times quickly (e.g. user clicks through a list).
    # Each change should unsub from the old id and sub to the new id.
    Given a WiredTaskItem component receiving taskId prop
    When the taskId prop changes from "item-1" to "item-2" to "item-3" rapidly
    Then exactly 1 subscription is active (for the current taskId)
    And subscriptions for "item-1" and "item-2" are cancelled

  @[SKIP]
  Scenario: Component subscribes in StrictMode and does not double-fire
    # React StrictMode mounts, unmounts, and re-mounts every component in dev.
    # A naive subscribeEffect fires twice, producing duplicate callbacks.
    Given the app runs in React StrictMode
    When a wired component mounts
    Then the subscribe callback is called exactly once per state change
    And the unsubscribe is called once on final unmount

  @[SKIP] @[SWIFT]
  Scenario: A wired SwiftUI view cancels its subscription Task when it disappears
    # F-17: WiredView spawns the cache subscription inside a nested unstructured Task,
    # which escapes the .task modifier's cancellation. On disappear the loop must stop.
    Given a wired SwiftUI view subscribed to the task collection appears on screen
    When the view disappears (is removed from the hierarchy)
    Then its subscription loop terminates (no further cache reads occur for that view)
    And the cache subscribe continuation it held is released
    And it no longer writes into its @State after disappearing

  @[SKIP] @[SWIFT]
  Scenario: Query property wrapper does not re-subscribe on an unrelated parent re-render
    # F-18: the SwiftUI @Query wrapper's update() must not tear down and rebuild its
    # subscription on every graph evaluation — only when the resolved query identity changes.
    Given a SwiftUI view hosts a @Query for "tasks/item-1"
    And the parent view re-renders for a reason unrelated to that query
    Then the @Query does NOT cancel and recreate its subscription
    And no flicker or transient empty value is emitted as a result of the parent re-render
    When the query's resolved id actually changes to "tasks/item-2"
    Then the @Query cancels the old subscription and creates exactly one new subscription

  # ---------------------------------------------------------------------------
  # 10. Schema migration
  #     Swift blogs: "we changed a CloudKit field type from String to Int and
  #     every user with cached data got a crash on startup after the update"
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: App ships a new field; old cached data is missing the field
    # The most common crash-on-update scenario. The UI reads task.priority
    # which didn't exist in v1 — gets undefined, crashes.
    Given the local cache contains v1 tasks without a "priority" field
    When the app updates to v2 which adds priority: "medium" as a required default
    Then reading item-1.priority returns "medium" (the default)
    And no crash or undefined access occurs
    And a write of item-1 without priority does not strip the default

  @[SKIP]
  Scenario: App ships a renamed field; old reads and new writes must coexist during rollout
    # The "rolling deployment" problem. Some clients are v1 (field: dueDate),
    # some are v2 (field: due_at). The adapter must serve both.
    Given v1 clients write tasks with dueDate: 1750000000
    And v2 clients write tasks with due_at: 1750000000
    When a v1 client reads a task written by a v2 client
    Then item-1.dueDate is populated (rolled-forward from due_at)
    And when a v2 client reads a task written by a v1 client
    Then item-1.due_at is populated (rolled-forward from dueDate)

  @[SKIP]
  Scenario: Migration rollback — v3 ships, breaks in production, rolls back to v2
    # Swift CloudKit blog: "we had to ship a hotfix and the schema downgrade caused
    # v3 clients to fail to read their own previously-written records"
    Given some users have tasks written by the v3 schema (has "metadata" field)
    When the app is rolled back to v2 (no "metadata" field)
    Then reading a v3-written task from a v2 client does not crash
    And the "metadata" field is gracefully ignored
    And any writes from the v2 client do not permanently destroy the "metadata" field

  # ---------------------------------------------------------------------------
  # 11. UI state / domain state boundary
  #     Zustand blog: "we stored modal open/closed in the same slice as domain
  #     data — the modal state was persisted to the server on every save"
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: UI state (sidebar open) never persists to the remote adapter
    # ui/ paths must be local-only. A write to ui/sidebar/global must never
    # reach the Firestore or CloudKit adapter.
    Given the store has a FirestoreAdapter for "tasks" and local-only for "ui/"
    When the user fires "toggleSidebar" writing to path "ui/sidebar" id "global"
    Then the Firestore adapter receives 0 write operations
    And the in-memory cache shows ui.sidebar.global.isOpen = true
    And a page refresh resets ui.sidebar.global.isOpen to false (not persisted)

  @[SKIP]
  Scenario: UI state from one user session does not leak into another
    # A shared device: user A logs out, user B logs in. User A's UI state
    # (expanded rows, selected items, draft form data) must be cleared.
    Given user A is logged in with ui/taskList/view.selectedId = "item-1"
    When user A logs out and user B logs in
    Then ui/taskList/view.selectedId is null or absent for user B
    And user B cannot read any of user A's ui/ state

  @[SKIP]
  Scenario: Ephemeral draft state is not committed if the user cancels
    # The form-draft problem. Redux-form famously polluted the store with
    # in-progress form data that was never cleaned up after cancel.
    Given the user opens a "New task" form which writes to ui/taskForm/draft
    And the draft contains title: "Half-finished task"
    When the user taps "Cancel"
    Then ui/taskForm/draft is cleared from the cache
    And no "half-finished task" record exists in the tasks collection
    And store.history.log() shows no AddTask write descriptor
