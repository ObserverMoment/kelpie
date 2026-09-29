import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct AppFeatureFleetViewTests {
  private static let root = URL(fileURLWithPath: "/tmp/fleet-app")

  private static func makeWorktree(_ id: String) -> Worktree {
    Worktree(
      id: WorktreeID(id), name: URL(fileURLWithPath: id).lastPathComponent, detail: "",
      workingDirectory: URL(fileURLWithPath: id), repositoryRootURL: root)
  }

  private static func makeStore(
    worktree: Worktree, layouts: IdentifiedArrayOf<LayoutFeature.State> = [], selected: Bool = true
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(id: RepositoryID(root.path), rootURL: root, name: "fleet-app", worktrees: [worktree])
    ])
    repositories.isInitialLoadComplete = true
    if selected { repositories.selection = .worktree(worktree.id) }
    repositories.recomputeSidebarStructureIfChanged()
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = layouts
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    return store
  }

  /// One pane whose tabs' content ids double as the surface ids, the way the manager reports them.
  private static func layout(worktree: Worktree, surfaceIDs: [UUID]) -> LayoutFeature.State {
    let paneID = PaneID()
    let tabs = surfaceIDs.map { surfaceID in
      TabItem(
        id: TabID(), title: "One",
        content: ContentSnapshot(
          id: ContentID(rawValue: surfaceID),
          state: .terminal(TerminalContentState(workingDirectory: nil))))
    }
    let layout = PaneLayout(
      tree: SplitTree(view: paneID),
      panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: tabs))])
    return LayoutFeature.State(id: worktree.id, layout: layout)
  }

  @Test(.dependencies) func openSessionSelectsWorktreeAndFocusesSurface() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    let tabID = TabID()
    let surfaceID = UUID()

    let open = FleetViewFeature.Delegate.openSession(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID)
    await store.send(.fleetView(.delegate(open)))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(sent.value.contains(.focusSurface(worktree, tabID: tabID, surfaceID: surfaceID)))
  }

  @Test(.dependencies) func launchCreatesTabWithInputAndSelectsWorktree() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }

    await store.send(.fleetView(.delegate(.launch(worktreeID: worktree.id, command: "claude"))))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "claude", runSetupScriptIfNew: false, focusing: true)))
  }

  @Test(.dependencies) func launchIntoPendingWorktreeRunsItsSetupScript() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await store.send(.repositories(.sidebarItems(.element(id: worktree.id, action: .lifecycleChanged(.pending)))))

    await store.send(.fleetView(.delegate(.launch(worktreeID: worktree.id, command: "claude"))))
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(
      sent.value.contains(
        .createTabWithInput(worktree, input: "claude", runSetupScriptIfNew: true, focusing: true)))
  }

  @Test(.dependencies) func dismissRefocusesTheSelectedTerminal() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree)

    await store.send(.fleetView(.toggle))
    await store.send(.fleetView(.dismiss))
    await store.receive(\.fleetView.delegate.dismissed)
    await store.receive(\.repositories.sidebarItems)
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.shouldFocusTerminal == true)
  }

  @Test(.dependencies) func dismissWithoutASelectionRefocusesNothing() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree, selected: false)

    await store.send(.fleetView(.toggle))
    await store.send(.fleetView(.dismiss))
    await store.receive(\.fleetView.delegate.dismissed)
    await store.finish()
    #expect(store.state.repositories.sidebarItems[id: worktree.id]?.shouldFocusTerminal == false)
  }

  @Test(.dependencies) func reopeningAfterASessionEndedFocusesASurvivingCard() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let first = UUID()
    let second = UUID()
    let store = Self.makeStore(
      worktree: worktree,
      layouts: [Self.layout(worktree: worktree, surfaceIDs: [first, second])])
    await store.send(
      .repositories(
        .sidebarItems(
          .element(
            id: worktree.id,
            action: .terminalProjectionChanged(
              WorktreeRowProjection(
                surfaceIDs: [first, second], isProgressBusy: false, hasUnseenNotifications: false,
                notifications: []))))))
    for surfaceID in [first, second] {
      await store.send(
        .agentPresence(
          .hookEventReceived(AgentHookEvent(agent: "claude", event: "session_start", surfaceID: surfaceID))))
    }

    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.focusedCardID == FleetCardID(surfaceID: first, agent: .claude))
    await store.send(.fleetView(.dismiss))
    await store.send(
      .agentPresence(.hookEventReceived(AgentHookEvent(agent: "claude", event: "session_end", surfaceID: first))))
    await store.send(.fleetView(.toggle))

    #expect(store.state.fleetView.structure.allCards.map(\.surfaceID) == [second])
    #expect(store.state.fleetView.focusedCardID == FleetCardID(surfaceID: second, agent: .claude))
  }

  @Test(.dependencies) func unknownWorktreeIsIgnored() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }

    let missing = Worktree.ID("/nope")
    await store.send(.fleetView(.delegate(.launch(worktreeID: missing, command: "claude")))).finish()
    let open = FleetViewFeature.Delegate.openSession(worktreeID: missing, tabID: TabID(), surfaceID: UUID())
    await store.send(.fleetView(.delegate(open))).finish()

    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func structureIsRecomputedWhilePresented() async {
    let worktree = Self.makeWorktree("/tmp/fleet-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceIDs: [surfaceID])])

    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.launcherWorktreeID == worktree.id)
    #expect(store.state.fleetView.structure.launcherRows.map(\.id) == [worktree.id])
    #expect(store.state.fleetView.structure.sections.isEmpty)

    // The row learns its surface and an agent arrives: the post-reduce step builds the card.
    await store.send(
      .repositories(
        .sidebarItems(
          .element(
            id: worktree.id,
            action: .terminalProjectionChanged(
              WorktreeRowProjection(
                surfaceIDs: [surfaceID], isProgressBusy: false, hasUnseenNotifications: false,
                notifications: []))))))
    await store.send(
      .agentPresence(
        .hookEventReceived(AgentHookEvent(agent: "claude", event: "session_start", surfaceID: surfaceID))))
    #expect(store.state.fleetView.structure.allCards.map(\.surfaceID) == [surfaceID])
    #expect(store.state.fleetView.focusedCardID == FleetCardID(surfaceID: surfaceID, agent: .claude))

    await store.send(
      .agentPresence(.hookEventReceived(AgentHookEvent(agent: "claude", event: "busy", surfaceID: surfaceID))))
    #expect(store.state.fleetView.structure.allCards.first?.activity == .busy)

    // Closed: no recompute happens, the last structure stays as it was.
    await store.send(.fleetView(.dismiss))
    await store.send(
      .agentPresence(.hookEventReceived(AgentHookEvent(agent: "claude", event: "idle", surfaceID: surfaceID))))
    #expect(store.state.fleetView.structure.allCards.first?.activity == .busy)
  }
}
