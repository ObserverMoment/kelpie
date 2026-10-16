import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

/// ⌘F routing in `AppFeature` and the per-feature filter derivations.
@MainActor
struct SearchFilterRoutingTests {
  private static let root = URL(fileURLWithPath: "/tmp/search-app")
  private static let worktree = Worktree(
    id: WorktreeID("/tmp/search-app/feature"), name: "feature", detail: "",
    workingDirectory: URL(fileURLWithPath: "/tmp/search-app/feature"), repositoryRootURL: root)

  private static func makeAppStore(selected: Bool, configure: (inout AppFeature.State) -> Void = { _ in })
    -> TestStoreOf<AppFeature>
  {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(id: RepositoryID(root.path), rootURL: root, name: "search-app", worktrees: [worktree])
    ])
    repositories.isInitialLoadComplete = true
    if selected { repositories.selection = .worktree(worktree.id) }
    repositories.applyCacheRecomputes(.allSidebar)
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    configure(&state)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return store
  }

  // MARK: - AppFeature routing

  @Test(.dependencies) func commandFOpensTheShownOverlayPagesFilter() async {
    let store = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .fleet
    }
    await store.send(.startSearch)
    await store.receive(\.fleetView.search.requested)
    #expect(store.state.fleetView.search.isPresented)

    await store.send(.fleetView(.modeChanged(.pods)))
    await store.send(.startSearch)
    await store.receive(\.pods.search.requested)
    #expect(store.state.pods.search.isPresented)
  }

  @Test(.dependencies) func commandFInThreadsGoesToTilesThenToAShownMessageFilter() async {
    let surface = UUID()
    let row = ThreadsStructure.Row(
      id: surface, worktreeID: Self.worktree.id, tab: nil, worktreeName: "wt", repositoryName: "search-app",
      agent: .claude, unreadCount: 0, messageCount: 1, isStale: false, summary: nil, memberName: nil, branchName: nil)
    var box = MessageThread(surfaceID: surface, worktreeID: Self.worktree.id, agent: .claude)
    box.messages = [MailMessage(id: UUID(), body: "hello", createdAt: Date(timeIntervalSince1970: 1))]
    let store = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .threads
      $0.threads.$file.withLock { $0.boxes.append(box) }
      $0.threads.applyStructure(ThreadsStructure(tiles: [.session(row)]))
    }
    #expect(store.state.threads.displayedThreadID == .session(surface))
    await store.send(.startSearch)
    await store.receive(\.threads.tileSearch.requested)

    // The keys on a message: ⌘F targets the message filter, and again while it is shown.
    await store.send(.threads(.moveFocus(.right)))
    #expect(store.state.threads.focusedMessageID != nil)
    await store.send(.startSearch)
    await store.receive(\.threads.messageSearch.requested)
    await store.send(.startSearch)
    await store.receive(\.threads.messageSearch.requested)
    #expect(store.state.threads.messageSearch.focusRequestCount == 2)

    // With no thread shown the message field is not mounted, so ⌘F goes to the tiles.
    let empty = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .threads
      $0.threads.messageSearch.query = ""
    }
    await empty.send(.startSearch)
    await empty.receive(\.threads.tileSearch.requested)
  }

  @Test(.dependencies) func commandFIsANoOpInThePodWorkspaceAndTheOpenMessage() async {
    let podID = PodID(rawValue: UUID())
    let store = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .podWorkspace(podID)
    }
    await store.send(.startSearch)
    #expect(!store.state.fleetView.search.isPresented)

    let viewer = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .threads
      $0.threads.openMessageID = UUID()
    }
    await viewer.send(.startSearch)
    #expect(!viewer.state.threads.tileSearch.isPresented)
    #expect(!viewer.state.threads.messageSearch.isPresented)
  }

  @Test(.dependencies) func commandFWithNoWorktreeOpenFiltersTheSidebar() async {
    let store = Self.makeAppStore(selected: false)
    await store.send(.startSearch)
    await store.receive(\.repositories.search.requested)
    #expect(store.state.repositories.search.isPresented)
  }

  @Test(.dependencies) func closingTheOverlayClearsEveryOverlayFilter() async {
    let store = Self.makeAppStore(selected: true) {
      $0.fleetView.isPresented = true
      $0.fleetView.mode = .threads
      $0.pods.search.query = "pod"
      $0.threads.tileSearch.query = "tile"
      $0.threads.messageSearch.query = "message"
    }
    await store.send(.fleetView(.dismiss))
    await store.receive(\.pods.overlayDismissed)
    await store.receive(\.threads.overlayDismissed)
    #expect(!store.state.pods.search.isPresented)
    #expect(!store.state.threads.tileSearch.isPresented)
    #expect(!store.state.threads.messageSearch.isPresented)
  }

  @Test func searchFieldTakesKeysIsModeGated() {
    var state = AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    state.fleetView.search.isFocused = true
    #expect(!state.searchFieldTakesKeys)
    state.fleetView.isPresented = true
    #expect(state.searchFieldTakesKeys)
    state.fleetView.mode = .pods
    #expect(!state.searchFieldTakesKeys)
    state.pods.search.isFocused = true
    #expect(state.searchFieldTakesKeys)
    state.fleetView.mode = .threads
    #expect(!state.searchFieldTakesKeys)
    state.threads.messageSearch.isFocused = true
    #expect(state.searchFieldTakesKeys)
  }

  @Test func filterKeystrokesSkipTheDerivedStructureRecomputes() {
    let typing = AppFeature.Action.repositories(.search(.queryChanged("k")))
    #expect(!typing.affectsFleetViewStructure)
    #expect(!typing.affectsWorktreeMenuSnapshot)
    #expect(RepositoriesFeature.Action.search(.queryChanged("k")).cacheInvalidations == .visibleSidebarStructure)
    for action in [
      AppFeature.Action.fleetView(.search(.queryChanged("k"))), .pods(.search(.queryChanged("k"))),
      .threads(.tileSearch(.queryChanged("k"))), .threads(.messageSearch(.queryChanged("k"))),
    ] {
      #expect(!action.affectsFleetViewStructure)
      #expect(!action.affectsWorktreeMenuSnapshot)
    }
  }

  // MARK: - Sidebar

  @Test func sidebarFilterPrunesTheVisibleStructureOnly() {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(
        id: RepositoryID(Self.root.path), rootURL: Self.root, name: "search-app",
        worktrees: [
          Self.worktree,
          Worktree(
            id: WorktreeID("/tmp/search-app/other"), name: "other", detail: "",
            workingDirectory: URL(fileURLWithPath: "/tmp/search-app/other"), repositoryRootURL: Self.root),
        ])
    ])
    repositories.isInitialLoadComplete = true
    repositories.applyCacheRecomputes(.allSidebar)
    let full = repositories.sidebarStructure
    #expect(repositories.visibleSidebarStructure == full)

    repositories.search.query = "feat"
    repositories.applyCacheRecomputes(.visibleSidebarStructure)
    #expect(repositories.sidebarStructure == full)
    let visibleRows = repositories.visibleSidebarStructure.navigationStops
    #expect(visibleRows == [.worktree(Self.worktree.id)])

    repositories.search.query = "search-app"
    repositories.applyCacheRecomputes(.visibleSidebarStructure)
    #expect(repositories.visibleSidebarStructure.sections == full.sections)

    // Rows inside a collapsed repository are drawn, and are stops, under a filter.
    repositories.search.query = "feat"
    let repositoryID = RepositoryID(Self.root.path)
    repositories.$sidebar.withLock { $0.sections[repositoryID, default: .init()].collapsed = true }
    repositories.applyCacheRecomputes(.allSidebar)
    #expect(!repositories.expandedRepositoryIDs.contains(repositoryID))
    #expect(repositories.sidebarStructure.navigationStops.isEmpty)
    #expect(repositories.sidebarNavigationStop(byOffset: 1) == .worktree(Self.worktree.id))

    // A selection the filter hid enters the visible run at its end.
    repositories.$sidebar.withLock { $0.sections[repositoryID, default: .init()].collapsed = false }
    repositories.search.query = "other"
    repositories.applyCacheRecomputes(.allSidebar)
    repositories.selection = .worktree(Self.worktree.id)
    let other = WorktreeID("/tmp/search-app/other")
    #expect(repositories.sidebarNavigationStop(byOffset: 1) == .worktree(other))
    #expect(repositories.sidebarNavigationStop(byOffset: -1) == .worktree(other))

    repositories.search = SearchFilterFeature.State()
    repositories.applyCacheRecomputes(.visibleSidebarStructure)
    #expect(repositories.visibleSidebarStructure == full)

    // A row whose text changes is refiltered on the structure bit even when
    // the structure itself (row ids only) does not change.
    repositories.search.query = "zzz"
    repositories.applyCacheRecomputes(.visibleSidebarStructure)
    #expect(repositories.visibleSidebarStructure.navigationStops.isEmpty)
    repositories.sidebarItems[id: Self.worktree.id]?.subtitle = "zzz-path"
    repositories.applyCacheRecomputes(.sidebarStructure)
    #expect(repositories.visibleSidebarStructure.navigationStops == [.worktree(Self.worktree.id)])
  }

  @Test(.dependencies) func sidebarFilterKeepsAMatchedRepositorysPinnedRowInItsHighlightSection() async {
    @Shared(.sidebarGroupPinnedRows) var groupPinnedRows: Bool
    $groupPinnedRows.withLock { $0 = true }
    let other = WorktreeID("/tmp/search-app/other")
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(
        id: RepositoryID(Self.root.path), rootURL: Self.root, name: "search-app",
        worktrees: [
          Self.worktree,
          Worktree(
            id: other, name: "other", detail: "", workingDirectory: URL(fileURLWithPath: other.rawValue),
            repositoryRootURL: Self.root),
        ])
    ])
    repositories.isInitialLoadComplete = true
    let store = TestStore(initialState: repositories) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.pinWorktree(Self.worktree.id))
    #expect(store.state.sidebarStructure.hoistedRowIDs == [Self.worktree.id])

    // The repository name matches: its pinned row stays hoisted in Pinned.
    await store.send(.search(.requested))
    await store.send(.search(.queryChanged("search-app")))
    #expect(
      store.state.visibleSidebarStructure.leadingSections == [.highlight(kind: .pinned, rowIDs: [Self.worktree.id])])

    // Only the other row matches: the Pinned section empties and drops out.
    await store.send(.search(.queryChanged("other")))
    #expect(store.state.visibleSidebarStructure.leadingSections.isEmpty)
    #expect(store.state.visibleSidebarStructure.navigationStops == [.worktree(other)])
  }

  @Test func readAloudUnderAMessageFilterPicksTheNewestVisibleAgentMessage() {
    let surface = UUID()
    var box = MessageThread(surfaceID: surface, worktreeID: Self.worktree.id, agent: .claude)
    let older = MailMessage(id: UUID(), body: "alpha done", createdAt: Date(timeIntervalSince1970: 1))
    let newer = MailMessage(id: UUID(), body: "beta done", createdAt: Date(timeIntervalSince1970: 2))
    box.messages = [newer, older]
    var state = AppFeature.State(repositories: RepositoriesFeature.State(), settings: SettingsFeature.State())
    state.threads.$file.withLock { $0.boxes.append(box) }
    state.threads.applyStructure(
      ThreadsStructure(tiles: [
        .session(
          ThreadsStructure.Row(
            id: surface, worktreeID: Self.worktree.id, tab: nil, worktreeName: "wt", repositoryName: "search-app",
            agent: .claude, unreadCount: 2, messageCount: 2, isStale: false, summary: nil, memberName: nil,
            branchName: nil))
      ]))
    state.fleetView.isPresented = true
    state.fleetView.mode = .threads
    #expect(state.readAloudMessageID == newer.id)

    state.threads.messageSearch.query = "alpha"
    #expect(state.readAloudMessageID == older.id)
  }

  @Test(.dependencies) func everyRepositoryIsOpenWhileFilteringAndChevronsDoNotRewriteStoredState() async {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(id: RepositoryID(Self.root.path), rootURL: Self.root, name: "search-app", worktrees: [Self.worktree])
    ])
    repositories.isInitialLoadComplete = true
    let repositoryID = RepositoryID(Self.root.path)
    let storedBefore = repositories.isRepositoryExpanded(repositoryID)
    let store = TestStore(initialState: repositories) { RepositoriesFeature() }
    store.exhaustivity = .off
    await store.send(.search(.requested))
    await store.send(.search(.queryChanged("feat")))
    #expect(store.state.isSidebarFiltering)
    #expect(store.state.isRepositoryExpanded(repositoryID))

    await store.send(.repositoryExpansionChanged(repositoryID, isExpanded: !storedBefore))
    let prefixesBefore = store.state.sidebar.sections[repositoryID]?.buckets[.unpinned]?.collapsedBranchPrefixes
    await store.send(
      .branchNestExpansionChanged(repositoryID: repositoryID, bucketID: .unpinned, prefix: "feature", isExpanded: false)
    )
    #expect(store.state.sidebar.sections[repositoryID]?.buckets[.unpinned]?.collapsedBranchPrefixes == prefixesBefore)
    await store.send(.search(.dismissed))
    #expect(!store.state.isSidebarFiltering)
    #expect(store.state.isRepositoryExpanded(repositoryID) == storedBefore)
  }

  // MARK: - Fleet

  private static func card(_ repository: String) -> FleetViewStructure.Card {
    let surfaceID = UUID()
    return FleetViewStructure.Card(
      id: FleetCardID(surfaceID: surfaceID, agent: .claude), worktreeID: worktree.id, repositoryID: "/tmp/search-app",
      tab: TabItem(
        id: TabID(), title: "Tab",
        content: ContentSnapshot(
          id: ContentID(rawValue: surfaceID), state: .terminal(TerminalContentState(workingDirectory: nil)))),
      activity: .idle, repositoryName: repository, worktreeName: "wt", branchName: "main",
      workingDirectoryPath: "/tmp/search-app/wt", isFolder: false, model: nil, effort: nil, lastMessage: nil)
  }

  @Test(.dependencies) func fleetFilterNarrowsTheGridTheArrowsWalk() async {
    let kelpie = Self.card("kelpie")
    let zig = Self.card("zig")
    var state = FleetViewFeature.State(isPresented: true)
    state.applyStructure(
      FleetViewStructure(sections: [.init(id: .ungrouped, title: nil, cards: [kelpie, zig])], launcherRows: []))
    let store = TestStore(initialState: state) { FleetViewFeature() }
    store.exhaustivity = .off

    await store.send(.search(.requested))
    await store.send(.search(.queryChanged("zig")))
    #expect(store.state.visibleStructure.allCards.map(\.id) == [zig.id])
    #expect(store.state.focusedCardID == zig.id)
    #expect(store.state.filteredQuery == "zig")
    await store.send(.moveFocus(.left))
    #expect(store.state.focusedCardID == zig.id)

    await store.send(.search(.dismissed))
    #expect(store.state.visibleStructure == store.state.structure)
    await store.send(.dismiss) {
      $0.isPresented = false
    }
    #expect(!store.state.search.isPresented)
  }

  @Test(.dependencies) func fleetFilterKeepsTheNearestNeighbourOnTheFirstKeystroke() async {
    let cards = (0..<4).map { Self.card($0 == 2 ? "hidden" : "kelpie-\($0)") }
    var state = FleetViewFeature.State(isPresented: true)
    state.applyStructure(
      FleetViewStructure(sections: [.init(id: .ungrouped, title: nil, cards: cards)], launcherRows: []))
    state.focusedCardID = cards[2].id
    let store = TestStore(initialState: state) { FleetViewFeature() }
    store.exhaustivity = .off

    await store.send(.search(.requested))
    await store.send(.search(.queryChanged("kelpie")))
    // The hidden card's neighbour, not the first visible card.
    #expect(store.state.focusedCardID == cards[3].id)
  }

  @Test func fleetStructureRefreshRefiltersWithTheLiveQuery() {
    let kelpie = Self.card("kelpie")
    let zig = Self.card("zig")
    let other = Self.card("zig-two")
    var state = FleetViewFeature.State(isPresented: true)
    state.applyStructure(
      FleetViewStructure(sections: [.init(id: .ungrouped, title: nil, cards: [kelpie, zig])], launcherRows: []))
    state.search.query = "zig"
    state.refilterStructure()
    #expect(state.visibleStructure.allCards.map(\.id) == [zig.id])

    state.applyStructure(
      FleetViewStructure(sections: [.init(id: .ungrouped, title: nil, cards: [kelpie, zig, other])], launcherRows: []))
    #expect(state.visibleStructure.allCards.map(\.id) == [zig.id, other.id])
    #expect(state.focusedCardID == zig.id)
  }

  // MARK: - Pods

  @Test(.dependencies) func podFilterNarrowsTheMemberTilesTheArrowsWalk() async {
    let podID = PodID(rawValue: UUID())
    let alpha = UUID()
    let beta = UUID()
    let member = { (id: UUID, name: String) in
      PodStructure.MemberCard(
        id: id, worktreeID: Self.worktree.id, name: name, description: "", registration: .pending, activity: nil,
        worktreeName: nil)
    }
    var state = PodsFeature.State()
    state.applyStructure(
      PodStructure(
        pods: [
          .init(id: podID, name: "Crew", description: "", members: [member(alpha, "Alpha"), member(beta, "Beta")])
        ],
        candidates: []))
    state.focusedMemberID = alpha
    let store = TestStore(initialState: state) {
      PodsFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    await store.send(.search(.requested))
    await store.send(.search(.queryChanged("beta")))
    #expect(store.state.memberIDsByPod == [[beta]])
    #expect(store.state.focusedMemberID == beta)
    await store.send(.search(.dismissed))
    #expect(store.state.memberIDsByPod == [[alpha, beta]])
  }

  // MARK: - Threads

  @Test(.dependencies) func messageFilterNarrowsTheTimelineAndReleasesAHiddenFocus() async {
    let store = TestStore(initialState: ThreadsFeature.State()) {
      ThreadsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
    }
    store.exhaustivity = .off
    let surface = UUID()
    await store.send(.received(surfaceID: surface, worktreeID: Self.worktree.id, agent: .claude, body: "alpha done"))
    await store.send(.received(surfaceID: surface, worktreeID: Self.worktree.id, agent: .claude, body: "beta done"))
    let ids = store.state.selectedMessageIDs
    #expect(ids.count == 2)
    await store.send(.moveFocus(.right))
    #expect(store.state.focusedMessageID == ids.last)

    await store.send(.messageSearch(.requested))
    await store.send(.messageSearch(.queryChanged("ALPHA")))
    #expect(store.state.visibleTimeline.map(\.message.body) == ["alpha done"])
    #expect(store.state.selectedMessageIDs == [ids.first])
    #expect(store.state.focusedMessageID == nil)

    await store.send(.messageSearch(.queryChanged("done")))
    #expect(store.state.selectedMessageIDs == ids)
  }

  @Test(.dependencies) func tileFilterNarrowsTheTilesTheArrowsWalkAndDismissalClearsIt() async {
    let first = UUID()
    let second = UUID()
    let row = { (id: UUID, repository: String) in
      ThreadsStructure.Row(
        id: id, worktreeID: Self.worktree.id, tab: nil, worktreeName: "wt", repositoryName: repository,
        agent: .claude, unreadCount: 0, messageCount: 1, isStale: false, summary: nil, memberName: nil, branchName: nil)
    }
    var state = ThreadsFeature.State()
    state.applyStructure(ThreadsStructure(tiles: [.session(row(first, "kelpie")), .session(row(second, "zig"))]))
    let store = TestStore(initialState: state) {
      ThreadsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
    }
    store.exhaustivity = .off
    await store.send(.tileSearch(.requested))
    #expect(store.state.selectedThreadID == .session(first))
    await store.send(.tileSearch(.queryChanged("zig")))
    #expect(store.state.visibleStructure.tiles.map(\.id) == [.session(second)])
    #expect(store.state.structure.tiles.count == 2)
    // The hidden selection moved to the first visible tile.
    #expect(store.state.selectedThreadID == .session(second))

    await store.send(.tileSearch(.queryChanged("nothing")))
    #expect(store.state.visibleStructure.tiles.isEmpty)
    #expect(store.state.selectedThreadID == .session(second))
    await store.send(.tileSearch(.queryChanged("zig")))
    await store.send(.moveFocus(.down))
    #expect(store.state.selectedThreadID == .session(second))

    await store.send(.overlayDismissed)
    #expect(!store.state.tileSearch.isPresented)
    #expect(store.state.visibleStructure == store.state.structure)
  }
}
