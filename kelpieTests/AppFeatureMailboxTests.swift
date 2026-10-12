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
    worktree: Worktree, others: [Worktree] = [], layouts: IdentifiedArrayOf<LayoutFeature.State> = [],
    liveAgentSurfaceIDs: [UUID] = [],
    speak: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
  ) -> TestStoreOf<AppFeature> {
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(
        id: RepositoryID(root.path), rootURL: root, name: "mailbox-app",
        worktrees: IdentifiedArray(uniqueElements: [worktree] + others))
    ])
    repositories.isInitialLoadComplete = true
    repositories.selection = .worktree(worktree.id)
    repositories.recomputeSidebarStructureIfChanged()
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.terminals.layouts = layouts
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
    await store.receive(\.mailbox.received)
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

  @Test(.dependencies) func lastMessageRequestOpensTheFocusedPanesNewestMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "old")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "new")
    #expect(store.state.focusedSurfaceHasMail)

    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.fleetView.toggleMailbox)
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .mailbox)
    #expect(store.state.mailbox.openMessage?.body == "new")
    #expect(store.state.mailbox.viewerReturnsToPane)
  }

  @Test(.dependencies) func readAloudReadsTheFocusedPanesNewestMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.mailbox.readAloudToggled)
    await store.receive(\.mailbox.readAloudFinished)
    #expect(spoken.value == ["hi"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheOpenViewerMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")
    let first = store.state.mailbox.file.boxes[id: surfaceID]!.messages[1].id

    await store.send(.fleetView(.toggleMailbox))
    await store.send(.mailbox(.messageOpened(first)))
    #expect(store.state.isShowingMailViewer)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.mailbox.readAloudFinished)
    #expect(spoken.value == ["first"])
  }

  @Test(.dependencies) func readAloudButtonReadsItsPanesNewestMessageOverTheOpenViewer() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")
    let first = store.state.mailbox.file.boxes[id: surfaceID]!.messages[1].id

    await store.send(.fleetView(.toggleMailbox))
    await store.send(.mailbox(.messageOpened(first)))
    await store.send(.readLastAgentMessageAloud(surfaceID: surfaceID))
    await store.receive(\.mailbox.readAloudFinished)
    #expect(spoken.value == ["second"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheFocusedInboxMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "first")
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "second")

    await store.send(.fleetView(.toggleMailbox))
    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.mailbox.moveFocus)
    await store.send(.fleetView(.moveFocus(.down)))
    await store.receive(\.mailbox.moveFocus)
    #expect(store.state.mailbox.focusedMessageID == store.state.mailbox.file.boxes[id: surfaceID]!.messages[1].id)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.mailbox.readAloudFinished)
    #expect(spoken.value == ["first"])
  }

  @Test(.dependencies) func readAloudHotkeyReadsTheSelectedSessionOverTheFocusedPane() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let paneSurfaceID = UUID()
    let otherSurfaceID = UUID()
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: paneSurfaceID, tabID: TabID())],
      speak: { text in spoken.withValue { $0.append(text) } })
    await Self.deliver(store, worktree: worktree, surfaceID: paneSurfaceID, "pane")
    await Self.deliver(store, worktree: worktree, surfaceID: otherSurfaceID, "other")

    await store.send(.fleetView(.toggleMailbox))
    // Opening the Mailbox may select either row first; step to the other one.
    let rows = store.state.mailbox.structure.rows.map(\.id)
    let selectedIndex = rows.firstIndex(of: store.state.mailbox.selectedSurfaceID!)!
    let otherIndex = rows.firstIndex(of: otherSurfaceID)!
    let direction: FleetViewNavigation.Direction = otherIndex > selectedIndex ? .down : .up
    for _ in 0..<abs(otherIndex - selectedIndex) {
      await store.send(.fleetView(.moveFocus(direction)))
      await store.receive(\.mailbox.moveFocus)
    }
    #expect(store.state.mailbox.selectedSurfaceID == otherSurfaceID)
    #expect(store.state.mailbox.focusedMessageID == nil)
    await store.send(.readLastAgentMessageAloud(surfaceID: nil))
    await store.receive(\.mailbox.readAloudFinished)
    #expect(spoken.value == ["other"])
  }

  @Test(.dependencies) func viewerReplyIsDeliveredThenTheMessageIsDone() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      liveAgentSurfaceIDs: [surfaceID])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id
    let delivered = LockIsolated<[String]>([])
    store.dependencies.terminalClient.deliverPrompt = { target, text in
      delivered.withValue { $0.append(text) }
      return target == surfaceID
    }

    await store.send(.mailbox(.replySent(id, text: "ok")))
    await store.receive(\.mailbox.markDone)
    #expect(delivered.value == [MailboxFeature.replyQuote(for: "hi") + "ok"])
    #expect(store.state.mailbox.file.boxes[id: surfaceID]?.messages.isEmpty != false)
  }

  @Test(.dependencies) func replyToAnExitedAgentIsNotDelivered() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id
    let delivered = LockIsolated(false)
    store.dependencies.terminalClient.deliverPrompt = { _, _ in
      delivered.setValue(true)
      return true
    }

    await store.send(.mailbox(.replySent(id, text: "ok")))
    await store.receive(\.mailbox.delegate.sendReply)
    #expect(!delivered.value)
    #expect(store.state.alert != nil)
    #expect(store.state.mailbox.file.boxes[id: surfaceID]?.messages.map(\.id) == [id])
  }

  @Test(.dependencies) func failedReplyKeepsTheMessageAndAlerts() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())],
      liveAgentSurfaceIDs: [surfaceID])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    let id = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id
    store.dependencies.terminalClient.deliverPrompt = { _, _ in false }

    await store.send(.mailbox(.replySent(id, text: "ok")))
    await store.receive(\.replyDeliveryFailed)
    #expect(store.state.alert != nil)
    #expect(store.state.mailbox.file.boxes[id: surfaceID]?.messages.map(\.id) == [id])
  }

  @Test(.dependencies) func lastMessageRequestIsANoOpWithoutMail() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: UUID(), tabID: TabID())])
    #expect(!store.state.focusedSurfaceHasMail)

    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.finish()
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func lastMessageRequestSwitchesModeOrKeepsTheMailboxOpen() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.fleetView(.toggle))
    await store.send(.showLastAgentMessage(surfaceID: surfaceID))
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.fleetView.mode == .mailbox)

    // Already showing the Mailbox: the toggle would close it, so none is sent.
    await store.send(.showLastAgentMessage(surfaceID: surfaceID))
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.mailbox.viewerReturnsToPane)
  }

  @Test(.dependencies) func closingAPaneViewerReturnsToThePane() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    await store.send(.mailbox(.viewerClosed))
    await store.receive(\.mailbox.delegate.closedToPane)
    await store.receive(\.repositories.selectWorktree)
    await store.finish()

    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(
      sent.value.contains(
        .focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func escapeFromAPaneViewerReturnsToThePane() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    await store.receive(\.fleetView.delegate.dismissed)
    await store.receive(\.mailbox.overlayDismissed)
    await store.receive(\.mailbox.delegate.closedToPane)
    await store.finish()

    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(
      sent.value.contains(
        .focusSurface(worktree, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func lastMessageDeeplinkOpensTheTabsMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
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
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.mailbox.openMessage?.body == "hi")
    #expect(store.state.alert == nil)
  }

  @Test(.dependencies) func lastMessageDeeplinkRefusalLeavesTheSelection() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let other = Self.makeWorktree("/tmp/mailbox-app/other")
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
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
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
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let other = Self.makeWorktree("/tmp/mailbox-app/other")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, others: [other],
      layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    // A jump or slot hotkey under the overlay lands in another worktree.
    await store.send(.repositories(.selectWorktree(other.id)))
    await store.send(viaEscape ? .fleetView(.dismiss) : .mailbox(.viewerClosed))
    await store.receive(\.mailbox.delegate.closedToPane)
    await store.receive(\.repositories.sidebarItems)
    #expect(store.state.repositories.sidebarItems[id: other.id]?.shouldFocusTerminal == true)
    await store.finish()

    #expect(store.state.repositories.selectedWorktreeID == other.id)
    #expect(!store.state.fleetView.isPresented)
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(!sent.value.contains { if case .focusSurface = $0 { true } else { false } })
  }

  @Test(.dependencies) func lastMessageDeeplinkToAnotherWorktreeClosesToThatTab() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let other = Self.makeWorktree("/tmp/mailbox-app/other")
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
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.repositories.selectedWorktreeID == other.id)

    await store.send(.fleetView(.dismiss))
    await store.receive(\.mailbox.delegate.closedToPane)
    await store.finish()
    #expect(
      sent.value.contains(
        .focusSurface(other, tabID: tabID, surfaceID: surfaceID, input: nil, submitsInput: false)))
  }

  @Test(.dependencies) func lastMessageRequestIgnoresAWindowedFocusedPane() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
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

  @Test(.dependencies) func replyFromAPaneViewerFocusesThePaneOnce() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    let sent = LockIsolated<[TerminalClient.Command]>([])
    store.dependencies.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    await store.send(.mailbox(.replyTapped(store.state.mailbox.openMessageID!)))
    await store.receive(\.mailbox.delegate.reply)
    await store.finish()

    let focuses = sent.value.filter { if case .focusSurface = $0 { true } else { false } }
    #expect(focuses.count == 1)
    #expect(!store.state.mailbox.viewerReturnsToPane)
    #expect(store.state.mailbox.openMessageID == nil)
  }

  @Test(.dependencies) func launchingFromFleetDropsAPaneViewer() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    store.dependencies.terminalClient.send = { _ in }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    await store.send(.fleetView(.delegate(.launch(worktreeID: worktree.id, command: "claude"))))
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(!store.state.mailbox.viewerReturnsToPane)
  }

  @Test(.dependencies) func paletteEntryOpensTheFocusedPanesMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: TabID())])
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")

    await store.send(.commandPalette(.delegate(.layoutCommand(.showLastAgentMessage))))
    await store.receive(\.showLastAgentMessage)
    await store.receive(\.mailbox.lastMessageOpened)
    #expect(store.state.mailbox.openMessage?.body == "hi")
  }

  @Test(.dependencies) func openingAFleetCardDropsAPaneViewer() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let surfaceID = UUID()
    let tabID = TabID()
    let store = Self.makeStore(
      worktree: worktree, layouts: [Self.layout(worktree: worktree, surfaceID: surfaceID, tabID: tabID)])
    store.dependencies.terminalClient.send = { _ in }
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.showLastAgentMessage(surfaceID: nil))
    await store.receive(\.mailbox.lastMessageOpened)

    await store.send(
      .fleetView(.delegate(.openSession(worktreeID: worktree.id, tabID: tabID, surfaceID: surfaceID))))
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(!store.state.mailbox.viewerReturnsToPane)
  }

  @Test(.dependencies) func mailChromeTracksTheBoxAndIsRewrittenOnWake() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
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

    let id = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.mailbox(.markDone(id)))
    #expect(!rebuilt.terminalChrome.hasMail)
    #expect(rebuilt.terminalChrome.unreadMail == 0)
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

extension AppFeatureMailboxTests {
  @Test(.dependencies) func arrowKeysWalkTheSessionsThenTheInboxInMailboxMode() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    await Self.deliver(store, worktree: worktree, surfaceID: UUID(), "a")
    await Self.deliver(store, worktree: worktree, surfaceID: UUID(), "b")
    await store.send(.fleetView(.toggleMailbox))
    let rows = store.state.mailbox.structure.rows.map(\.id)
    #expect(rows.count == 2)

    await store.send(.fleetView(.moveFocus(.up)))
    await store.receive(\.mailbox.moveFocus)
    #expect(store.state.mailbox.selectedSurfaceID == rows[0])
    await store.send(.fleetView(.moveFocus(.down)))
    await store.receive(\.mailbox.moveFocus)
    #expect(store.state.mailbox.selectedSurfaceID == rows[1])

    let message = store.state.mailbox.file.boxes[id: rows[1]]!.messages[0].id
    await store.send(.fleetView(.moveFocus(.right)))
    await store.receive(\.mailbox.moveFocus)
    #expect(store.state.mailbox.focusedMessageID == message)
    await store.send(.fleetView(.activateFocusedCard))
    await store.receive(\.mailbox.activateFocused)
    #expect(store.state.mailbox.openMessageID == message)
    #expect(store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func escapeStepsBackFromAnInboxMessageThenCloses() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleMailbox))
    let id = store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id
    await store.send(.mailbox(.messageOpened(id)))

    await store.send(.overlayEscapePressed)
    await store.receive(\.mailbox.viewerClosed)
    #expect(store.state.fleetView.isPresented)
    #expect(store.state.mailbox.openMessageID == nil)
    #expect(store.state.mailbox.focusedMessageID == id)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }

  @Test(.dependencies) func escapeInFleetModeClosesTheOverlayDespiteAnOpenInboxMessage() async {
    let worktree = Self.makeWorktree("/tmp/mailbox-app/wt")
    let store = Self.makeStore(worktree: worktree)
    let surfaceID = UUID()
    await Self.deliver(store, worktree: worktree, surfaceID: surfaceID, "hi")
    await store.send(.fleetView(.toggleMailbox))
    await store.send(.mailbox(.messageOpened(store.state.mailbox.file.boxes[id: surfaceID]!.messages[0].id)))
    await store.send(.fleetView(.toggle))
    #expect(store.state.fleetView.mode == .fleet)

    await store.send(.overlayEscapePressed)
    await store.receive(\.fleetView.dismiss)
    #expect(!store.state.fleetView.isPresented)
  }
}
