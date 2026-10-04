import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct AppFeatureMailboxTests {
  private static let root = URL(fileURLWithPath: "/tmp/mailbox-app")

  private static func makeWorktree(_ id: String) -> Worktree {
    Worktree(
      id: WorktreeID(id), name: URL(fileURLWithPath: id).lastPathComponent, detail: "",
      workingDirectory: URL(fileURLWithPath: id), repositoryRootURL: root)
  }

  private static func makeStore(
    worktree: Worktree, layouts: IdentifiedArrayOf<LayoutFeature.State> = []
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(id: RepositoryID(root.path), rootURL: root, name: "mailbox-app", worktrees: [worktree])
    ])
    repositories.isInitialLoadComplete = true
    repositories.selection = .worktree(worktree.id)
    repositories.recomputeSidebarStructureIfChanged()
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = layouts
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
    }
    store.exhaustivity = .off
    return store
  }

  private static func layout(worktree: Worktree, surfaceID: UUID, tabID: TabID) -> LayoutFeature.State {
    let paneID = PaneID()
    let tab = TabItem(
      id: tabID, title: "One",
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID), state: .terminal(TerminalContentState(workingDirectory: nil))))
    let layout = PaneLayout(
      tree: SplitTree(view: paneID), panes: [Pane(id: paneID, tabs: IdentifiedArray(uniqueElements: [tab]))])
    return LayoutFeature.State(id: worktree.id, layout: layout)
  }

  @Test(.dependencies) func toggleMailboxShowsAndHidesTheOverlay() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)

    await store.send(.fleetView(.toggleMailbox))
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .mailbox)

    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.mode == .fleet)

    await store.send(.fleetView(.toggleMailbox))
    #expect(store.state.fleetView.mode == .mailbox)
    await store.send(.fleetView(.toggleMailbox))
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func mailEventLandsInTheMailbox() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()

    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "done")))
    await store.receive(\.mailbox.received)
    #expect(store.state.mailbox.file.boxes[id: surfaceID]?.messages.map(\.body) == ["done"])
    #expect(store.state.mailbox.unreadCount == 1)
  }

  @Test(.dependencies) func hookEventsRouteToTheMailbox() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "done")))
    await store.receive(\.mailbox.received)

    let submitted = AgentHookEvent(
      agent: "claude", event: "prompt_submitted", surfaceID: surfaceID, pid: nil, data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(submitted)))
    await store.receive(\.mailbox.promptSubmitted)

    let ended = AgentHookEvent(agent: "claude", event: "session_end", surfaceID: surfaceID, pid: nil, data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(ended)))
    await store.receive(\.mailbox.sessionEnded)
    #expect(store.state.mailbox.file.boxes.isEmpty)
  }

  @Test(.dependencies) func replyOpensThePaneWithoutSubmitting() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await store.send(.fleetView(.toggleMailbox))

    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "hi")))
    await store.receive(\.mailbox.received)
    let messageID = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id

    await store.send(.mailbox(.replyTapped(messageID)))
    await store.receive(\.mailbox.delegate.reply)
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(!store.state.fleetView.isPresented)
    #expect(
      sent.value.contains(
        .focusSurface(
          worktree, tabID: tabID, surfaceID: surfaceID,
          input: "<replying-to>\nhi\n</replying-to>\n\n", submitsInput: false)))
  }

  @Test(.dependencies) func closedSurfacesDropTheirBoxes() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "x")))
    await store.receive(\.mailbox.received)

    await store.send(.terminalEvent(.surfacesClosed(worktreeID: worktree.id, [surfaceID])))
    await store.receive(\.mailbox.surfacesClosed)
    #expect(store.state.mailbox.file.boxes.isEmpty)
  }
}
