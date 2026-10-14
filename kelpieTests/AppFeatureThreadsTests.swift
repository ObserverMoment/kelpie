import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct AppFeatureThreadsTests {
  private static let root = URL(fileURLWithPath: "/tmp/threads-app")

  private static func makeWorktree(_ id: String) -> Worktree {
    Worktree(
      id: WorktreeID(id), name: URL(fileURLWithPath: id).lastPathComponent, detail: "",
      workingDirectory: URL(fileURLWithPath: id), repositoryRootURL: root)
  }

  private static func makeStore(
    worktree: Worktree, others: [Worktree] = [], layouts: IdentifiedArrayOf<LayoutFeature.State> = [],
    liveAgentSurfaceIDs: [UUID] = [], pods: IdentifiedArrayOf<Pod> = [],
    speak: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(
        id: RepositoryID(root.path), rootURL: root, name: "threads-app",
        worktrees: IdentifiedArray(uniqueElements: [worktree] + others))
    ])
    repositories.isInitialLoadComplete = true
    repositories.selection = .worktree(worktree.id)
    repositories.recomputeSidebarStructureIfChanged()
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = layouts
    state.pods.pods = pods
    for surfaceID in liveAgentSurfaceIDs {
      state.agentPresence.bySurface[surfaceID] = [.claude]
    }
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0[SpeechClient.self] = SpeechClient(speak: speak)
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

  private static func deliver(_ store: TestStoreOf<AppFeature>, worktree: Worktree, surfaceID: UUID, _ body: String)
    async
  {
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: body)))
    await store.receive(\.threads.received)
  }

  @Test(.dependencies) func toggleThreadsShowsAndHidesTheOverlay() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)

    await store.send(.fleetView(.toggleThreads))
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .threads)

    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.mode == .fleet)

    await store.send(.fleetView(.toggleThreads))
    #expect(store.state.fleetView.mode == .threads)
    await store.send(.fleetView(.toggleThreads))
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func mailEventLandsInTheThreads() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()

    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "done")))
    await store.receive(\.threads.received)
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.body) == ["done"])
    #expect(store.state.threads.unreadCount == 1)
  }

  @Test(.dependencies) func hookEventsRouteToTheThreads() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "done")))
    await store.receive(\.threads.received)

    let ended = AgentHookEvent(agent: "claude", event: "session_end", surfaceID: surfaceID, pid: nil, data: nil)
    await store.send(.terminalEvent(.agentHookEventReceived(ended)))
    await store.receive(\.threads.sessionEnded)
    #expect(store.state.threads.file.boxes.isEmpty)
  }

  @Test(.dependencies) func lastMessageRequestOpensTheFocusedPanesNewestMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "old")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "new")
    #expect(store.state.focusedSurfaceHasMail)

    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.fleetView.toggleThreads)
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .threads)
    #expect(store.state.threads.openMessage?.body == "new")
    #expect(store.state.threads.viewerReturnsToPane)
  }

  @Test(.dependencies) func readAloudReadsTheFocusedPanesNewestMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.threads.readAloudToggled)
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["hi"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheOpenViewerMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")
    let first = store.state.threads.file.boxes[id: surfaceID]!.messages[1].id

    await store.send(.fleetView(.toggleThreads))
    await store.send(.threads(.messageOpened(first)))
    #expect(store.state.isShowingMailViewer)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["first"])
  }

  @Test(.dependencies) func readAloudButtonReadsItsPanesNewestMessageOverTheOpenViewer() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")
    let first = store.state.threads.file.boxes[id: surfaceID]!.messages[1].id

    await store.send(.fleetView(.toggleThreads))
    await store.send(.threads(.messageOpened(first)))
    await store.send(.readLastAgentMessageAloud(surfaceID: surfaceID))
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["second"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheFocusedInboxMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")

    await store.send(.fleetView(.toggleThreads))
    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.threads.moveFocus)
    await store.send(.fleetView(.moveFocus(.up)))
    await store.receive(\.threads.moveFocus)
    #expect(store.state.threads.focusedMessageID == store.state.threads.file.boxes[id: surfaceID]!.messages[1].id)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["first"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheSelectedSessionOverTheFocusedPane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let paneSurfaceID = UUID()
    let otherSurfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: paneSurfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: paneSurfaceID, "pane")
    await Self.deliver(store, worktree: worktree, surfaceID: otherSurfaceID, "other")

    await store.send(.fleetView(.toggleThreads))
    // Opening the Threads may select either row first; step to the other one.
    let rows = store.state.threads.structure.sessions.map(\.id)
    let selectedIndex = rows.firstIndex { ThreadID.session($0) == store.state.threads.selectedThreadID }!
    let otherIndex = rows.firstIndex(of: otherSurfaceID)!
    let direction: FleetViewNavigation.Direction = otherIndex > selectedIndex ? .down : .up
    for _ in 0..<abs(otherIndex - selectedIndex) {
      await store.send(.fleetView(.moveFocus(direction)))
      await store.receive(\.threads.moveFocus)
    }
    #expect(store.state.threads.selectedThreadID == .session(otherSurfaceID))
    #expect(store.state.threads.focusedMessageID == nil)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["other"])
  }

  @Test(.dependencies) func anInboxMessageLeftOpenIsNotShownOrReadOutsideTheThreads() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")
    let first = store.state.threads.file.boxes[id: surfaceID]!.messages[1].id

    await store.send(.fleetView(.toggleThreads))
    await store.send(.threads(.messageOpened(first)))
    await store.send(.fleetView(.modeChanged(.fleet)))
    #expect(!store.state.isShowingMailViewer)

    await store.send(.fleetView(.dismiss))
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.threads.readAloudFinished)
    #expect(spoken.value == ["second"])
  }

  @Test(.dependencies) func viewerReplyIsDeliveredThenAppendedAsTheUsersMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      liveAgentSurfaceIDs: [surfaceID])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    let delivered = LockIsolated<[String]>([])
    store.dependencies.terminalClient.deliverPrompt = { target, text in
      delivered.withValue { $0.append(text) }
      return target == surfaceID
    }

    await store.send(.threads(.replySent(id, text: "ok")))
    await store.receive(\.threads.replyDelivered)
    #expect(delivered.value == ["ok"])
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.author) == [.user, .agent])
  }

  @Test(.dependencies) func replyToAnExitedAgentIsNotDelivered() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    let delivered = LockIsolated(false)
    store.dependencies.terminalClient.deliverPrompt = { _, _ in
      delivered.setValue(true)
      return true
    }

    await store.send(.threads(.replySent(id, text: "ok")))
    await store.receive(\.threads.delegate.sendReply)
    #expect(!delivered.value)
    #expect(store.state.alert != nil)
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.id) == [id])
  }

  @Test(.dependencies) func failedReplyKeepsTheMessageAndAlerts() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      liveAgentSurfaceIDs: [surfaceID])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    store.dependencies.terminalClient.deliverPrompt = { _, _ in false }

    await store.send(.threads(.replySent(id, text: "ok")))
    await store.receive(\.replyDeliveryFailed)
    #expect(store.state.alert != nil)
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.id) == [id])
  }

  @Test(.dependencies) func lastMessageRequestIsANoOpWithoutMail() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: UUID(), tabID: TabID())])
    #expect(!store.state.focusedSurfaceHasMail)

    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.finish()
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func lastMessageRequestSwitchesModeOrKeepsTheThreadsOpen() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.fleetView(.toggle))
    await store.send(.showLastAgentMessage(surfaceID: surfaceID))
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .threads)

    // Already showing the Threads: the toggle would close it, so none is sent.
    await store.send(.showLastAgentMessage(surfaceID: surfaceID))
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.threads.viewerReturnsToPane)
  }

  @Test(.dependencies) func closingAPaneViewerReturnsToThePane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.threads.lastMessageOpened)

    await store.send(.threads(.viewerClosed))
    await store.receive(\.threads.delegate.closedToPane)
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.threads.openMessageID == nil)
    #expect(
      sent.value.contains(
        .focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func escapeFromAPaneViewerReturnsToThePane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.threads.lastMessageOpened)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    await store.receive(\.fleetView.delegate.dismissed)
    await store.receive(\.threads.overlayDismissed)
    await store.receive(\.threads.delegate.closedToPane)
    await store.finish()

    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.threads.openMessageID == nil)
    #expect(
      sent.value.contains(
        .focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func lastMessageDeeplinkOpensTheTabsMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    store.dependencies.terminalClient.send = { _ in }
    store.dependencies.terminalClient.tabExists = { worktreeID, candidate in
      worktreeID == worktree.id && candidate == tabID
    }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabLastMessage(tabID: tabID.rawValue))))
    await store.receive(\.showLastAgentMessage)
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.threads.openMessage?.body == "hi")
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func lastMessageDeeplinkRefusalLeavesTheSelection() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let other = Self.makeWorktree("/tmp/threads-app/other")
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, others: [other], layouts: [Self.layout(worktree: other, surfaceID: UUID(), tabID: tabID)])
    store.dependencies.terminalClient.send = { _ in }
    store.dependencies.terminalClient.tabExists = { worktreeID, candidate in
      worktreeID == other.id && candidate == tabID
    }

    // A tab with no mail.
    await store.send(.deeplink(.worktree(id: other.id, action: .tabLastMessage(tabID: tabID.rawValue))))
    await store.finish()
    #expect(store.state.alert != nil)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
    #expect(!store.state.fleetView.isPresented)

    // An unknown tab.
    await store.send(.alert(.dismiss))
    await store.send(.deeplink(.worktree(id: other.id, action: .tabLastMessage(tabID: UUID()))))
    await store.finish()
    #expect(store.state.alert != nil)
    #expect(store.state.repositories.selectedWorktreeID == worktree.id)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func lastMessageDeeplinkRefusesAWindowedPane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    var layout = Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)
    layout.windowedPaneIDs = [layout.layout.panes[0].id]
    let store = Self.makeStore(worktree: worktree, layouts: [layout])
    store.dependencies.terminalClient.send = { _ in }
    store.dependencies.terminalClient.tabExists = { worktreeID, candidate in
      worktreeID == worktree.id && candidate == tabID
    }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.deeplink(.worktree(id: worktree.id, action: .tabLastMessage(tabID: tabID.rawValue))))
    #expect(store.state.alert != nil)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies, arguments: [false, true])
  func closingAfterMovingToAnotherWorktreeStaysThere(viaEscape: Bool) async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let other = Self.makeWorktree("/tmp/threads-app/other")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, others: [other],
      layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.threads.lastMessageOpened)

    // A jump or slot hotkey under the overlay lands in another worktree.
    await store.send(.repositories(.selectWorktree(other.id)))
    await store.send(viaEscape ? .fleetView(.dismiss) : .threads(.viewerClosed))
    await store.receive(\.threads.delegate.closedToPane)
    await store.receive(\.repositories.sidebarItems)
    #expect(store.state.repositories.sidebarItems[id: other.id]?.shouldFocusTerminal == true)
    await store.finish()

    #expect(store.state.repositories.selectedWorktreeID == other.id)
    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.threads.openMessageID == nil)
    #expect(!sent.value.contains { if case .focusSurface = $0 { true } else { false } })
  }

  @Test(.dependencies) func lastMessageDeeplinkToAnotherWorktreeClosesToThatTab() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let other = Self.makeWorktree("/tmp/threads-app/other")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, others: [other],
      layouts: [Self.layout(worktree: other, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    store.dependencies.terminalClient.tabExists = { worktreeID, candidate in
      worktreeID == other.id && candidate == tabID
    }
    await Self.deliver(store, worktree: other, surfaceID: surfaceID, "hi")

    await store.send(.deeplink(.worktree(id: other.id, action: .tabLastMessage(tabID: tabID.rawValue))))
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.repositories.selectedWorktreeID == other.id)

    await store.send(.fleetView(.dismiss))
    await store.receive(\.threads.delegate.closedToPane)
    await store.finish()
    #expect(
      sent.value.contains(
        .focusSurface(other, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func lastMessageRequestIgnoresAWindowedFocusedPane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    var layout = Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())
    layout.windowedPaneIDs = [layout.layout.panes[0].id]
    let store = Self.makeStore(worktree: worktree, layouts: [layout])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    #expect(!store.state.focusedSurfaceHasMail)

    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.finish()
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func launchingFromFleetDropsAPaneViewer() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    store.dependencies.terminalClient.send = { _ in }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.threads.lastMessageOpened)

    await store.send(.fleetView(.delegate(.launch(worktreeID: worktree.id, command: "claude"))))
    #expect(store.state.threads.openMessageID == nil)
    #expect(!store.state.threads.viewerReturnsToPane)
  }

  @Test(.dependencies) func paletteEntryOpensTheFocusedPanesMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.commandPalette(.delegate(.layoutCommand(.showLastAgentMessage))))
    await store.receive(\.showLastAgentMessage)
    await store.receive(\.threads.lastMessageOpened)
    #expect(store.state.threads.openMessage?.body == "hi")
  }

  @Test(.dependencies) func openingAFleetCardDropsAPaneViewer() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    store.dependencies.terminalClient.send = { _ in }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.threads.lastMessageOpened)

    await store.send(
      .fleetView(.delegate(.openSession(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))))
    #expect(store.state.threads.openMessageID == nil)
    #expect(!store.state.threads.viewerReturnsToPane)
  }

  @Test(.dependencies) func mailChromeTracksTheBoxAndIsRewrittenOnWake() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let runtime = ContentRuntime()
    let content = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(content, at: .fallback))
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    store.dependencies.contentRuntime = runtime
    store.dependencies.terminalClient.send = { _ in }

    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    #expect(content.terminalChrome.hasMail)
    #expect(content.terminalChrome.unreadMail == 1)

    // A relaunch or reattach rebuilds the content with blank chrome.
    runtime.remove(ContentID(rawValue: surfaceID), tombstone: false)
    let rebuilt = ChromeTabContent(id: ContentID(rawValue: surfaceID))
    #expect(runtime.provision(rebuilt, at: .fallback))
    await store.send(.terminals(.layouts(.element(id: worktree.id, action: .wakeTab(id: tabID)))))
    #expect(rebuilt.terminalChrome.hasMail)
    // The test content has no builder wiring, so no dead button shows.
    #expect(rebuilt.terminalChrome.stripActions.isEmpty)
    #expect(rebuilt.terminalChrome.unreadMail == 1)

    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.threads(.markDone(id)))
    #expect(!rebuilt.terminalChrome.hasMail)
    #expect(rebuilt.terminalChrome.unreadMail == 0)
  }

  @Test(.dependencies) func anAgentThatExitsWithoutAHookTakesItsMailWithIt() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let exited = UUID()
    let running = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: exited, "gone")
    await Self.deliver(store, worktree: worktree, surfaceID: running, "here")

    await store.send(.agentPresence(.delegate(.agentsExited([exited]))))
    await store.receive(\.threads.sessionEnded)
    #expect(Array(store.state.threads.file.boxes.ids) == [running])
  }

  @Test(.dependencies) func closedSurfacesDropTheirBoxes() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "x")))
    await store.receive(\.threads.received)

    await store.send(.terminalEvent(.surfacesClosed(worktreeID: worktree.id, [surfaceID])))
    await store.receive(\.threads.surfacesClosed)
    #expect(store.state.threads.file.boxes.isEmpty)
  }
}

extension AppFeatureThreadsTests {
  @Test(.dependencies) func arrowKeysWalkTheSessionsThenTheInboxInThreadsMode() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    await Self.deliver(store, worktree: worktree, surfaceID: UUID(), "a")
    await Self.deliver(store, worktree: worktree, surfaceID: UUID(), "b")
    await store.send(.fleetView(.toggleThreads))
    let rows = store.state.threads.structure.sessions.map(\.id)
    #expect(rows.count == 2)

    await store.send(.fleetView(.moveFocus(.up)))
    await store.receive(\.threads.moveFocus)
    #expect(store.state.threads.selectedThreadID == .session(rows[0]))
    await store.send(.fleetView(.moveFocus(.down)))
    await store.receive(\.threads.moveFocus)
    #expect(store.state.threads.selectedThreadID == .session(rows[1]))

    let message = store.state.threads.file.boxes[id: rows[1]]!.messages[0].id
    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.threads.moveFocus)
    #expect(store.state.threads.focusedMessageID == message)
    await store.send(.fleetView(.activateFocusedCard))
    await store.receive(\.threads.activateFocused)
    #expect(store.state.threads.openMessageID == message)
    #expect(store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func escapeStepsBackFromAnInboxMessageThenCloses() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleThreads))
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.threads(.messageOpened(id)))

    await store.send(.overlayEscapePressed)
    await store.receive(\.threads.viewerClosed)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.threads.openMessageID == nil)
    #expect(store.state.threads.focusedMessageID == id)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies, arguments: [false, true])
  func onlyALiveSessionsReplyBoxTakesTheKeysFromTheMonitor(isLive: Bool) async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(worktree: worktree, liveAgentSurfaceIDs: isLive ? [surfaceID] : [])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleThreads))

    await store.send(.threads(.messageOpened(store.state.threads.file.boxes[id: surfaceID]!.messages[0].id)))
    #expect(store.state.isShowingMailViewer)
    #expect(store.state.mailViewerTakesKeys == isLive)
  }

  @Test(.dependencies) func optionCommandReturnMarksTheFocusedInboxMessageDone() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "a")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "b")
    await store.send(.fleetView(.toggleThreads))
    let ids = store.state.threads.file.boxes[id: surfaceID]!.messages.map(\.id)

    // On the session list no message has the keys.
    await store.send(.fleetView(.markFocusedDone))
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.count == 2)

    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.threads.moveFocus)
    await store.send(.fleetView(.markFocusedDone))
    await store.receive(\.threads.markDone)
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.id) == [ids[1]])
    #expect(store.state.threads.focusedMessageID == ids[1])
  }

  @Test(.dependencies) func optionCommandReturnInFleetModeLeavesTheInboxAlone() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "a")
    await store.send(.fleetView(.toggleThreads))
    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.threads.moveFocus)
    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.mode == .fleet)
    #expect(store.state.threads.focusedMessageID != nil)

    await store.send(.fleetView(.markFocusedDone))
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.count == 1)
  }

  @Test(.dependencies) func escapeInFleetModeClosesTheOverlayDespiteAnOpenInboxMessage() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleThreads))
    await store.send(.threads(.messageOpened(store.state.threads.file.boxes[id: surfaceID]!.messages[0].id)))
    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.mode == .fleet)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func showThreadOpensThreadsOnThePanesTile() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    // No thread yet: nothing happens.
    await store.send(.showThread(surfaceID: surfaceID))
    #expect(!store.state.fleetView.isPresented)

    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showThread(surfaceID: nil))
    await store.receive(\.threads.threadSelected)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .threads)
    #expect(store.state.threads.selectedThreadID == .session(surfaceID))
    #expect(store.state.focusedSurfaceThreadUnreadCount == 1)
  }

  @Test(.dependencies) func aPoddedDeliveryRollsThePodSummaryUntilThePodIsRemoved() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let podID = PodID(rawValue: UUID())
    let pod = Pod(
      id: podID, name: "Crew", description: "",
      members: [PodMember(id: surfaceID, worktreeID: worktree.id, name: "Alpha", description: "")], sentRoster: nil)
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      pods: [pod])
    // The pod's post-reduce pass materialises its members' tab content.
    store.dependencies[LayoutContentFactory.self] = LayoutContentFactory { request in
      InertTabContent(id: request.contentID, state: request.content)
    }
    store.dependencies.terminalClient.deliverPrompt = { _, _ in true }
    store.dependencies.terminalClient.reassertSurfaceActivity = {}
    await store.send(
      .terminalEvent(.agentMailReceived(worktreeID: worktree.id, surfaceID: surfaceID, agent: .claude, body: "hi")))
    await store.receive(\.threads.received)
    #expect(store.state.threads.summariesInFlight.contains(.pod(podID)))

    await store.send(.pods(.delegate(.podRemoved(podID))))
    await store.receive(\.threads.podRemoved)
    #expect(!store.state.threads.summariesInFlight.contains(.pod(podID)))
  }

  @Test(.dependencies) func spaceOnATileLeavesTheOverlayForThatPane() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleThreads))
    await store.send(.fleetView(.jumpToFocused))
    await store.receive(\.threads.jumpToFocused)
    await store.receive(\.threads.delegate.jumpToSession)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func thePanelReplyBoxTakesTheKeysFromTheOverlayMonitor() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleThreads))
    #expect(!store.state.mailViewerTakesKeys)
    await store.send(.threads(.panelReplyFocusChanged(true)))
    #expect(store.state.mailViewerTakesKeys)
    await store.send(.threads(.panelReplyFocusChanged(false)))
    #expect(!store.state.mailViewerTakesKeys)

    // The box vanishes under the viewer, and under a dismissed overlay, without reporting.
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.threads(.panelReplyFocusChanged(true)))
    await store.send(.threads(.messageOpened(id)))
    #expect(!store.state.threads.isPanelReplyFocused)
    await store.send(.threads(.viewerClosed))
    await store.send(.threads(.panelReplyFocusChanged(true)))
    await store.send(.fleetView(.dismiss))
    await store.receive(\.threads.overlayDismissed)
    #expect(!store.state.mailViewerTakesKeys)
    #expect(!store.state.threads.isPanelReplyFocused)
  }

  @Test(.dependencies) func aThreadWithOnlyTheUsersReplyHasNoMailToShow() async {
    let worktree = Self.makeWorktree("/tmp/threads-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.threads.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.threads(.replyDelivered(surfaceID: surfaceID, text: "ok")))
    await store.send(.threads(.markDone(id)))
    #expect(store.state.threads.file.boxes[id: surfaceID]?.messages.map(\.author) == [.user])
    #expect(!store.state.focusedSurfaceHasMail)
    #expect(store.state.readAloudMessageID == nil)

    await store.send(.showLastAgentMessage(surfaceID: surfaceID))
    #expect(!store.state.fleetView.isPresented)
  }
}
