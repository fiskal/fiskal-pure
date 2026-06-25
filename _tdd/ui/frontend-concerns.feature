Feature: Frontend engineer concerns — React and SwiftUI patterns
  # The patterns frontend engineers reach for because of how state is typically managed.
  # Each one is a symptom. The root cause is usually the same: state that should be
  # in the store is in the component, or callbacks that should be stable are recreated.
  #
  # Categories:
  #   1.  React portals — why they exist and when they're not needed
  #   2.  useCallback overuse — stable action references
  #   3.  useMemo overuse — derived values without memoization
  #   4.  React.memo — preventing cascading re-renders
  #   5.  Context API / prop drilling
  #   6.  useEffect chains for subscriptions
  #   7.  Conditional render states (loading / empty / error / data)
  #   8.  SwiftUI @EnvironmentObject re-render storm
  #   9.  SwiftUI @State for derived values
  #  10.  SwiftUI @Binding prop drilling
  #  11.  SwiftUI sheet / overlay placement
  #  12.  Event handler identity and reconciliation

  Background:
    Given a store with MemoryAdapter seeded with tasks and ui/ state

  # ---------------------------------------------------------------------------
  # 1. React portals
  #    Developers reach for portals when a modal, dropdown, or tooltip is
  #    visually trapped inside a parent's overflow:hidden or z-index context.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Modal triggers from inside a scrollable card but must render above everything
    # The query is a value that setModal writes to ui/modal/active.
    # WiredModalShell at the root reads that value and uses it as its live query.
    # No portal — the modal IS at the root. No context — setModal is an injected action.
    # Works for any collection: tasks, sprints, accounts — same modal, same action.
    Given a TaskCard inside a scrollable list with overflow:hidden
    And WiredTaskCard has action 'setModal' injected by wireView
    And WiredModalShell is at the app root, above all overflow:hidden containers
    # id is always the full path. task.id = 'tasks/task-1' — no collection juggling.
    When the user clicks "Delete" on the TaskCard
    Then TaskCard calls: setModal({ id: 'tasks/task-1' })
    And ui/modal/active = { id: 'tasks/task-1' } is written to the store
    And WiredModalShell re-renders with active.id = 'tasks/task-1'
    And WiredModalDetail query becomes { id: 'tasks/task-1' } → store parses collection from prefix
    And the modal fetches tasks/task-1 and renders above all content
    And no ReactDOM.createPortal is used
    And no React.createContext or useContext is used anywhere

  @[SKIP]
  Scenario: Two different list types open the same modal — id carries the collection
    # task.id = 'tasks/task-1', sprint.id = 'sprints/sprint-A'.
    # setModal just passes the id through. The modal query uses { id } alone.
    # No collection field, no type registry, no switch statement.
    Given WiredTaskRow wired with action 'setModal', query: { task: { id: taskId } }
    And WiredSprintRow wired with action 'setModal', query: { sprint: { id: sprintId } }
    And WiredModalShell at the root, WiredModalDetail with query ({ activeId }) => ({ item: { id: activeId } })
    When the user clicks a TaskRow (task.id = 'tasks/task-1')
    Then setModal writes { id: 'tasks/task-1' } to ui/modal/active
    And WiredModalDetail query: { id: 'tasks/task-1' } → fetches from tasks collection
    When the user closes and clicks a SprintRow (sprint.id = 'sprints/sprint-A')
    Then setModal writes { id: 'sprints/sprint-A' } to ui/modal/active
    And WiredModalDetail query: { id: 'sprints/sprint-A' } → fetches from sprints collection
    And the same WiredModalShell handled both with zero type-switching logic

  @[SKIP]
  Scenario: Dropdown menu overflows a parent container with overflow:hidden
    # Same root cause as the modal. The dropdown is rendered inside its trigger,
    # so it is clipped. Portal "fixes" it by rendering in document.body.
    Given a TaskRow inside a table with overflow:hidden
    And the TaskRow has an "Options" dropdown (actions: Edit, Archive, Delete)
    When the user opens the dropdown
    Then the dropdown renders outside the table's overflow:hidden bounds
    And the dropdown position is correct (anchored to the trigger button)
    And no portal is used

    # How: "Options" button writes to ui/dropdown/active:
    #   { triggerId: 'task-row-1', anchorRect: { top, left, width, height } }
    # A WiredDropdown at the app root reads ui/dropdown/active and renders
    # at the correct position using the anchorRect as coordinates.
    # Closing writes ui/dropdown/active = null.

  @[SKIP]
  Scenario: Toast notification renders above modals, drawers, and popovers
    # Toasts are typically implemented with portals because they need to float
    # above everything. With ui/ state, the toast renderer lives at the root.
    Given any component can fire "showToast" with a message
    When the user fires archiveTask and it fails
    Then a toast "Write failed — tap to retry" renders above the current modal
    And the toast auto-dismisses after 4 seconds
    And no component used ReactDOM.createPortal to render the toast

  # ---------------------------------------------------------------------------
  # 2. useCallback overuse
  #    The mental model: "every inline function in JSX causes a re-render."
  #    The reality: the problem is usually unstable props, not unstable callbacks.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Action function passed to a child does not cause the child to re-render
    # The developer writes:
    #   <TaskItem onArchive={useCallback(() => archiveTask(task.id), [task.id])} />
    # because they believe the callback reference changes on every parent render.
    #
    # With wireView, TaskItem receives archiveTask as a stable function from the
    # store — not an inline arrow created in the parent's render.
    Given WiredTaskItem is wired with action: 'archiveTask'
    When WiredTaskList re-renders because a different task was updated
    Then WiredTaskItem does NOT re-render
    And the archiveTask reference received by TaskItem is the same object reference
    And no useCallback is present in any component file

  @[SKIP]
  Scenario: A form's submit handler does not require useCallback wrapping
    # Developers wrap submit handlers in useCallback to avoid re-creating them
    # on every keystroke as the form field state changes.
    #
    # With wireView, the form writes to ui/taskForm/draft on each keystroke.
    # The submit handler is the addTask action from the store — always stable.
    Given AddTask component has a controlled text input
    When the user types 10 characters in the title input
    Then the addTask function reference passed to AddTask does not change
    And AddTask re-renders only because the draft field value changed
    And the re-render count equals the number of keystrokes (no extra renders)

  # ---------------------------------------------------------------------------
  # 3. useMemo overuse
  #    Developers memoize everything because they don't trust their own renders.
  #    The real problem is usually fan-out: one state change triggers many
  #    components to re-render even though they don't need the new data.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Filtered list does not require useMemo to avoid recomputing on every render
    # Developer writes:
    #   const activeTasks = useMemo(() => tasks.filter(t => t.status === 'active'), [tasks])
    # because filtering 1000 items on every render feels wasteful.
    #
    # With wireView, the filter is in the query — run once in the store on cache update,
    # not on every render of every component that needs the filtered list.
    Given 1000 tasks in the cache, 200 with status 'active'
    When a task unrelated to the active filter is updated
    Then the WiredTaskList component does NOT re-render
    And no useMemo is present in TaskList
    And the active task filter runs exactly once per cache update (in the store, not in the component)

  @[SKIP]
  Scenario: Expensive formatted value does not require useMemo
    # Developer writes:
    #   const display = useMemo(() => new Date(task.createdAt).toLocaleDateString(), [task.createdAt])
    # because date formatting feels expensive.
    #
    # With the model compute getter, the formatting runs at read time.
    # The component receives task.createdAtDisplay as a pre-formatted string.
    # It never calls new Date() itself.
    Given TaskItem receives a task prop with createdAtDisplay already formatted
    When TaskItem renders
    Then no date formatting code appears in TaskItem
    And no useMemo appears in TaskItem
    And task.createdAtDisplay is a plain string: "Jun 23, 2026"

  # ---------------------------------------------------------------------------
  # 3b. Model computers — cross-entity computed values without selectors
  #     Redux: selectors carry the full state shape; createSelector is a patch.
  #     Here: the model owns a function, the view calls it with the sibling it
  #     already holds as a wired prop. Plain objects in, plain value out.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Cross-entity computed value uses a model computer, not a selector
    # In Redux: a selector computes task completion relative to sprint total.
    # It must know the state shape (state.tasks.items, state.sprints.items)
    # and be memoized with createSelector to avoid unnecessary re-renders.
    # RTK's createSelector is a patch on the problem, not a rethink of it.
    #
    # With a model computer: TaskModel.compute.completionPercent(sprint)
    # The view wires both task and sprint, destructures completionPercent,
    # and calls it. No selector. No memoization. No state shape knowledge.
    Given TaskModel.compute includes: completionPercent(sprint) => number
    And WiredTaskItem is wired with queries: { task: tasks/id, sprint: sprints/sprintId }
    When TaskItem renders
    Then TaskItem destructures: { title, completionPercent, sprint } from props
    And calls completionPercent(sprint) directly to get the display value
    And no createSelector or useMemo is used
    And completionPercent is a plain function: (sprint) => Math.round(this.done / sprint.total * 100)

  @[SKIP]
  Scenario: Model getter formats own fields; computer takes a sibling argument
    # Two distinct compute patterns:
    # - Getter: derives from own fields only. "get createdAtDisplay()" reads this.createdAt.
    # - Computer: takes another document as argument. Called by the view.
    # Both live on the model. Neither touches the store.
    Given TaskModel has:
      | compute type | name              | depends on        |
      | getter       | createdAtDisplay  | this.createdAt    |
      | computer     | completionPercent | sprint (argument) |
    When the component destructures both from the task prop
    Then createdAtDisplay is read as a plain string value (getter already resolved)
    And completionPercent is destructured as a function reference
    And the view calls completionPercent(sprint) with the wired sprint prop
    And both are testable with plain object arguments — no store, no mock

  @[SKIP]
  Scenario: Model computer is testable without the store
    # Because a computer is a plain function on a plain object,
    # it can be tested by calling it directly with fixture data.
    Given a task object: { id: "t1", completedItems: 3, ...TaskModel.compute }
    And a sprint object: { id: "s1", totalItems: 10 }
    When completionPercent(sprint) is called
    Then it returns 30
    And no store instance, no wireView, no adapter is involved in the test

  @[SKIP]
  Scenario: Accuracy by default; optimised by narrowing the fields query
    # By default: the sprint query returns the full sprint document.
    # Any change to any sprint field (even sprint.description) triggers a re-render.
    # The re-render is always accurate — just potentially unnecessary.
    #
    # To optimise: add fields: ['totalItems'] to the sprint query.
    # Now only changes to the fields the computer actually reads trigger a re-render.
    # The component does not change — only the wireView query narrows.
    Given WiredTaskItem with default query: { sprint: { path: 'sprints', id: sprintId } }
    When sprint.description changes (not used by completionPercent)
    Then WiredTaskItem re-renders (full sprint document subscribed — accurate but not optimal)
    And the rendered output is correct (completionPercent result unchanged)

    Given WiredTaskItem with narrowed query: { sprint: { path: 'sprints', id: sprintId, fields: ['totalItems'] } }
    When sprint.description changes (not in fields list)
    Then WiredTaskItem does NOT re-render
    And when sprint.totalItems changes, WiredTaskItem re-renders with the updated completionPercent

    # Rule: start without fields narrowing (accurate, simple).
    # Add fields only when profiling shows the re-render cost is real.
    # The component is unchanged in both cases — the query is the only edit.

  # ---------------------------------------------------------------------------
  # 4. React.memo — preventing cascading re-renders
  #    Two rules replace it entirely: query by id + destructure what you use.
  #    No React.memo, no useCallback, no createSelector. Just clean components.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: TaskItem does not re-render when a sibling task is updated
    # Redux: updating task-2 replaces the tasks slice reference. Every connected
    # component re-evaluates its selector. Developers add React.memo + createSelector.
    #
    # Rule 1: query by id. Each WiredTaskItem subscribes to one document.
    # A sibling update fires only the sibling's subscriber.
    Given WiredTaskItem queries: { task: { path: 'tasks', id: taskId } }
    And WiredTaskList renders 10 WiredTaskItem children
    When task-2.status changes to "archived"
    Then only WiredTaskItem for task-2 re-renders
    And WiredTaskItems for task-1, task-3..task-10 do NOT re-render
    And no React.memo wraps any component
    And no createSelector exists anywhere in the codebase

  @[SKIP]
  Scenario: Component destructures only the fields it renders — no extra re-renders
    # Rule 2: destructure what you use. The component declares its dependencies
    # explicitly. If only title and status are destructured and used, a change to
    # createdAt does not cause a visible difference in the output.
    # When combined with fields: ['title', 'status'] in the query, the subscriber
    # only fires when those specific fields change.
    Given WiredTaskItem queries: { task: { path: 'tasks', id: taskId, fields: ['title', 'status'] } }
    And TaskItem is: ({ title, status }) => <li className={status}>{title}</li>
    When task-1.createdAt is updated (title and status unchanged)
    Then WiredTaskItem for task-1 does NOT re-render
    And no React.memo, useCallback, or useMemo is present

  @[SKIP]
  Scenario: Adding a new task does not re-render existing TaskItem components
    # WiredTaskList re-renders (collection changed), but passes a taskId string
    # to each child. Strings are primitively equal. React skips unchanged children.
    Given WiredTaskList renders TaskItems for task-1 and task-2
    When addTask creates task-3
    Then WiredTaskList re-renders (taskIds grew from 2 to 3)
    And WiredTaskItem for task-1 does NOT re-render (prop "task-1" === "task-1")
    And WiredTaskItem for task-2 does NOT re-render (prop "task-2" === "task-2")
    And WiredTaskItem for task-3 renders for the first time

  # ---------------------------------------------------------------------------
  # 5. Context API and prop drilling
  #    Context: one value change re-renders all consumers.
  #    Prop drilling: threading props through 4 intermediate components.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: A deeply nested component reads store data without prop drilling
    # Tree: App → Dashboard → SprintBoard → Column → TaskCard → TaskMenu → ArchiveButton
    # Without the library: archiveTask is drilled through 6 levels or put in Context.
    # With wireView: ArchiveButton is wired directly wherever it sits.
    Given a component tree 6 levels deep
    And ArchiveButton is at level 6
    When ArchiveButton is wired with action: 'archiveTask'
    Then archiveTask is called correctly when the button is pressed
    And none of the 5 intermediate components receive or pass archiveTask as a prop
    And no React Context is used for archiveTask

  @[SKIP]
  Scenario: Updating the current user does not re-render unrelated components
    # Context pitfall: UserContext holds the current user. Any component
    # consuming UserContext re-renders when the user object changes, even if
    # that component only cares about user.id (which didn't change).
    Given a UserBadge component that reads user.displayName
    And a TaskCount component that reads the active task count
    And both are wired to the store independently
    When user.lastLoginAt is updated (a field neither component reads)
    Then UserBadge does NOT re-render
    And TaskCount does NOT re-render
    And no Context.Provider re-render cascade occurs

  # ---------------------------------------------------------------------------
  # 6. useEffect chains for subscriptions
  #    The "subscription lifecycle" problem. Developers write useEffect to
  #    subscribe, then write cleanup, then realise the deps array is wrong.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: A wired component has zero useEffect calls for data concerns
    # The standard pattern without the library:
    #   useEffect(() => { const unsub = store.subscribe(...); return unsub }, [id])
    # With wireView, this is generated. The component file has no useEffect.
    Given a TaskDetail component wired to task by id
    When the component file is inspected
    Then TaskDetail contains zero useEffect calls
    And TaskDetail contains zero useState calls
    And TaskDetail contains zero useRef calls
    And TaskDetail is a plain function: (props) => JSX

  @[SKIP]
  Scenario: A component with local animation state uses useEffect only for animation
    # The only legitimate useEffect in a component file is for truly local,
    # non-data concerns: animations, focus, timers, scroll behaviour.
    Given a TaskItem with a "just archived" fade-out animation
    And TaskItem has one useEffect for the animation timer
    When TaskItem is inspected
    Then the useEffect is for animation timing only (e.g. setTimeout for CSS class)
    And there is no useEffect for reading data, subscribing, or fetching
    And the animation state lives in local useState (not the store)
    And archiveTask is still a prop — not called from inside useEffect

  # ---------------------------------------------------------------------------
  # 7. Conditional render states — loading / empty / error / data
  #    The "boolean soup" problem. Components accumulate isLoading, isError,
  #    isEmpty, hasData flags and the combinations get impossible to reason about.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Component handles all data states without boolean flags
    # The typical pattern:
    #   const [tasks, setTasks] = useState(null)
    #   const [isLoading, setIsLoading] = useState(true)
    #   const [error, setError] = useState(null)
    # With wireView, the three-state contract replaces all booleans.
    Given WiredTaskList is mounted
    Then during initial load: taskIds = undefined → render loading skeleton
    And after load with results: taskIds = [Doc, ...] → render list
    And after load with no results: taskIds = [] → render empty state
    And if the query fails: taskIds = null → render error state
    And TaskList has no isLoading, isError, or isEmpty props
    And TaskList has no boolean flags — only the taskIds value itself signals the state

  @[SKIP]
  Scenario: Error state does not require a separate error boundary for data fetch failures
    # Developers often reach for error boundaries to catch async data fetch errors.
    # With the three-state contract, errors are values — not exceptions.
    Given WiredTaskDetail is mounted for an id that does not exist
    When the adapter returns "not found"
    Then task = null (not undefined, not an exception)
    And TaskDetail renders its "not found" branch
    And no Error Boundary is needed to catch a thrown error
    And the rest of the app continues functioning normally

  # ---------------------------------------------------------------------------
  # 8. SwiftUI — @EnvironmentObject re-render storm
  #    A single @Published change triggers every view that holds a reference
  #    to the ObservableObject, even if the view reads a different property.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Updating one task does not re-render views reading other tasks
    # The @EnvironmentObject pattern: one AppStore holds all tasks.
    # Any @Published change (e.g. task-2.status) triggers every view that
    # accesses AppStore, including views that only read task-1.
    #
    # With wireView, each WiredTaskItem subscribes only to its own task id.
    Given WiredTaskItem for task-1 is rendered on screen
    And WiredTaskItem for task-2 is rendered on screen
    When task-2.status changes to "archived"
    Then WiredTaskItem for task-2 body recomputes
    And WiredTaskItem for task-1 body does NOT recompute
    And no @EnvironmentObject or @ObservedObject is used in either TaskItem

  @[SKIP]
  Scenario: Updating ui/ state does not re-render domain views
    # A sidebar opens (ui/sidebar/global.isOpen = true).
    # In a monolithic ObservableObject, this triggers every consumer to re-render.
    Given WiredTaskList is rendered alongside WiredSidebar
    When toggleSidebar writes to ui/sidebar/global
    Then WiredSidebar body recomputes (it subscribes to ui/sidebar)
    And WiredTaskList body does NOT recompute (it does not subscribe to ui/sidebar)
    And task data is not re-fetched or re-filtered as a result of the sidebar toggle

  # ---------------------------------------------------------------------------
  # 9. SwiftUI — @State for derived values
  #    Developers use @State to cache a derived value (formatted date, filtered list).
  #    The @State goes stale when the source changes — a second source of truth.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Formatted display value is not stored in @State
    # Developer writes:
    #   @State private var displayDate = ""
    #   .onAppear { displayDate = task.createdAt.formatted() }
    # The @State never updates if task.createdAt changes after appear.
    #
    # With the model compute getter, displayDate is read from the doc directly.
    Given TaskItem receives a task doc with createdAt = 1750000000
    When task.createdAt is updated to 1760000000 by a write
    Then TaskItem re-renders and reads task.createdAtDisplay fresh from the model getter
    And the displayed date updates correctly
    And no @State holds a cached copy of the formatted date
    And no .onAppear or .onChange is needed to keep the display in sync

  @[SKIP]
  Scenario: A filtered sublist is not stored in @State
    # Developer writes:
    #   @State private var activeTasks: [Task] = []
    #   .onReceive(store.$tasks) { activeTasks = $0.filter { $0.status == .active } }
    # The filter is a second copy of truth that can drift from the real collection.
    Given WiredTaskList subscribes to tasks where status == "active"
    When a task's status changes from "archived" to "active"
    Then WiredTaskList receives the updated taskIds immediately from the store query
    And no @State holds a filtered copy of the task list
    And no .onReceive chain recomputes the filter

  # ---------------------------------------------------------------------------
  # 10. SwiftUI — @Binding prop drilling
  #     @Binding is SwiftUI's mechanism for two-way state sharing. It works for
  #     one level. Threading it 4 levels deep is fragile and error-prone.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: A deeply nested toggle writes to ui/ state without @Binding chains
    # Tree: ContentView → TaskList → TaskRow → TaskMenu → ArchiveConfirmToggle
    # Without the library: isConfirming: Binding<Bool> drilled through 4 levels.
    # With wireView: ArchiveConfirmToggle reads and writes ui/confirmToggle directly.
    Given a ArchiveConfirmToggle 4 levels deep in the view hierarchy
    When the toggle is set to true
    Then ui/confirmToggle/task-1.isConfirming = true in the store
    And the toggle's wired parent re-renders with the updated value
    And no @Binding is passed from ContentView down to ArchiveConfirmToggle
    And no intermediate view declares a @State or @Binding for this value

  @[SKIP]
  Scenario: Sheet presentation is controlled by ui/ state, not @State + @Binding
    # The standard SwiftUI pattern:
    #   @State private var isShowingDetail = false
    #   .sheet(isPresented: $isShowingDetail) { ... }
    # @State lives in the presenting view; @Binding threads to child views that need to dismiss.
    Given a TaskList with a "New Task" sheet
    When the user taps "New Task"
    Then ui/sheet/newTask.isPresented = true is written to the store
    And the Sheet view at the app root renders the new task form
    And any child view inside the sheet can dismiss by writing isPresented = false
    And no @State isShowingDetail exists in any view
    And no @Binding is passed to the sheet's content view for dismiss control

  # ---------------------------------------------------------------------------
  # 11. SwiftUI — sheet, fullScreenCover, and overlay placement
  #     The portal problem in SwiftUI. .sheet() attached to a leaf view sometimes
  #     behaves unexpectedly (z-ordering, presentation context, animation conflicts).
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Modal sheet is attached at the app root, triggered from anywhere
    # .sheet() attached to a List row can be captured by the List's scroll
    # container on some iOS versions, causing presentation glitches.
    # The fix is to attach .sheet() at the NavigationStack or WindowGroup level.
    Given a TaskRow at the bottom of a long scrollable list
    When the user taps "Edit" on the TaskRow
    Then ui/sheet/editTask.taskId = "task-1" is written to the store
    And the EditTask sheet is presented from the NavigationStack root (not the row)
    And the sheet animates correctly with no clipping or scroll interference
    And TaskRow itself has no .sheet() modifier

  @[SKIP]
  Scenario: Multiple overlays do not conflict when triggered from different places
    # Having multiple .sheet() / .alert() / .confirmationDialog() modifiers
    # on the same view or sibling views can cause "only one presented at a time" bugs.
    Given the app root has one WiredSheet and one WiredAlert
    And both read from different ui/ paths
    When the user triggers an alert while a sheet is open
    Then ui/alert/active is set while ui/sheet/active remains set
    And the alert presents on top of the sheet correctly
    And dismissing the alert does not dismiss the sheet
    And there are no "attempt to present while already presenting" warnings

  # ---------------------------------------------------------------------------
  # 12. Event handler identity and reconciliation
  #     React: inline arrow functions create new references every render.
  #     SwiftUI: closures captured in Button actions can capture stale state.
  # ---------------------------------------------------------------------------

  @[SKIP]
  Scenario: Button action in a list row does not capture stale closure state
    # SwiftUI bug: a Button's action closure captures task.id at creation time.
    # If the row is recycled and task changes, the closure still fires with the old id.
    Given a TaskRow rendered for task-1, then recycled and rendered for task-3
    When the user taps "Archive" on the task-3 row
    Then archiveTask fires with id: "task-3"
    And archiveTask does NOT fire with id: "task-1" (stale closure)
    And the wired action closure is always bound to the current taskId prop

  @[SKIP]
  Scenario: React list row button does not capture a stale closure over the tasks array
    # React bug: event handler closes over the tasks array at render time.
    # The array reference is stale after an async update — the handler operates
    # on the old array.
    Given WiredTaskItem renders with task = { id: "task-1", status: "active" }
    When task-1.status is updated to "archived" by a remote push
    And the user immediately clicks Archive on what is now the updated row
    Then archiveTask fires with the current task-1.id
    And the handler does not reference the stale pre-update task object
    And no useRef is needed to keep the latest task in sync with the handler
