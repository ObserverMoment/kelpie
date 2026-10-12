import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct MailboxFeatureTests {
  private static let worktreeID = WorktreeID("/tmp/mailbox/wt")

  private static func makeStore(
    speak: @escaping @MainActor @Sendable (String) async -> Void = { _ in }
  ) -> TestStoreOf<MailboxFeature> {
    let store = TestStore(initialState: MailboxFeature.State()) {
      MailboxFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0[SpeechClient.self] = SpeechClient(speak: speak)
    }
    store.exhaustivity = .off
    return store
  }

  private static func deliver(_ store: TestStoreOf<MailboxFeature>, surface: UUID, _ body: String) async {
    await store.send(.received(surfaceID: surface, worktreeID: worktreeID, agent: .claude, body: body))
  }

  @Test(.dependencies) func deliveryCreatesBoxAndCountsUnread() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "first")
    await Self.deliver(store, surface: surface, "second")

    let box = store.state.file.boxes[id: surface]
    #expect(box?.worktreeID == Self.worktreeID)
    #expect(box?.agent == .claude)
    #expect(box?.messages.map(\.body) == ["second", "first"])
    #expect(box?.unreadCount == 2)
    #expect(store.state.unreadCount == 2)
    #expect(store.state.selectedSurfaceID == surface)
  }

  @Test(.dependencies) func openingMarksReadAndShowsMessage() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    let id = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.messageOpened(id))
    #expect(store.state.openMessageID == id)
    #expect(store.state.openMessage?.isRead == true)
    #expect(store.state.unreadCount == 0)

    await store.send(.viewerClosed)
    #expect(store.state.openMessageID == nil)
  }

  @Test(.dependencies) func doneRemovesMessageAndClosesViewer() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "a")
    await Self.deliver(store, surface: surface, "b")
    let idB = store.state.file.boxes[id: surface]!.messages[0].id
    await store.send(.messageOpened(idB))

    await store.send(.markDone(idB))
    #expect(store.state.openMessageID == nil)
    #expect(store.state.file.boxes[id: surface]?.messages.map(\.body) == ["a"])
  }

  @Test(.dependencies) func latestMessageOpensNewestAndClosesToThePane() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: UUID(), "elsewhere")
    await Self.deliver(store, surface: surface, "old")
    await Self.deliver(store, surface: surface, "new")
    let newest = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.lastMessageOpened(surfaceID: surface))
    #expect(store.state.selectedSurfaceID == surface)
    #expect(store.state.openMessageID == newest)
    #expect(store.state.openMessage?.isRead == true)
    #expect(store.state.file.boxes[id: surface]?.unreadCount == 1)
    #expect(store.state.viewerReturnsToPane)

    await store.send(.viewerClosed)
    await store.receive(.delegate(.closedToPane(worktreeID: Self.worktreeID, surfaceID: surface)))
    #expect(store.state.openMessageID == nil)
    #expect(!store.state.viewerReturnsToPane)
    // Closing keeps the mail: only the opened message turned read.
    #expect(store.state.file.boxes[id: surface]?.messages.map(\.body) == ["new", "old"])
    #expect(store.state.file.boxes[id: surface]?.messages.map(\.isRead) == [true, false])
  }

  @Test(.dependencies) func latestMessageIsANoOpWithoutMail() async {
    let store = Self.makeStore()
    let surface = UUID()
    await store.send(.lastMessageOpened(surfaceID: surface))
    #expect(store.state.openMessageID == nil)

    await Self.deliver(store, surface: surface, "only")
    let id = store.state.file.boxes[id: surface]!.messages[0].id
    await store.send(.markDone(id))
    await store.send(.lastMessageOpened(surfaceID: surface))
    #expect(store.state.openMessageID == nil)
    #expect(!store.state.viewerReturnsToPane)
  }

  @Test(.dependencies) func doneInAPaneViewerReturnsToThePane() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "a")
    await Self.deliver(store, surface: surface, "b")
    await store.send(.lastMessageOpened(surfaceID: surface))
    let newest = store.state.openMessageID!

    await store.send(.markDone(newest))
    await store.receive(.delegate(.closedToPane(worktreeID: Self.worktreeID, surfaceID: surface)))
    #expect(store.state.file.boxes[id: surface]?.messages.map(\.body) == ["a"])
    #expect(!store.state.viewerReturnsToPane)
  }

  @Test(.dependencies) func openingFromTheInboxClosesToTheInbox() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    await store.send(.lastMessageOpened(surfaceID: surface))
    let id = store.state.openMessageID!

    await store.send(.messageOpened(id))
    #expect(!store.state.viewerReturnsToPane)
    store.exhaustivity = .on
    await store.send(.viewerClosed) { $0.openMessageID = nil }
  }

  @Test(.dependencies) func overlayDismissClosesOnlyAPaneViewer() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    let id = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.lastMessageOpened(surfaceID: surface))
    await store.send(.overlayDismissed)
    await store.receive(.delegate(.closedToPane(worktreeID: Self.worktreeID, surfaceID: surface)))
    #expect(store.state.openMessageID == nil)
    #expect(store.state.file.boxes[id: surface]?.messages.count == 1)
    #expect(!store.state.viewerReturnsToPane)

    await store.send(.messageOpened(id))
    await store.send(.overlayDismissed)
    #expect(store.state.openMessageID == id)
  }

  @Test(.dependencies) func replyFlagsMessageAndDelegatesQuote() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "Line one\nmiddle\nLine three")
    let id = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.replyTapped(id))
    await store.receive(
      .delegate(
        .reply(
          worktreeID: Self.worktreeID, surfaceID: surface,
          text: "<replying-to>\nLine one\n…\nLine three\n</replying-to>\n\n")))
    let message = store.state.file.boxes[id: surface]!.messages[0]
    #expect(message.isReplying)
    #expect(message.isRead)

    // The prompt submit from that pane completes the reply; other panes don't.
    await store.send(.promptSubmitted(surfaceID: UUID()))
    #expect(store.state.file.boxes[id: surface]?.messages.count == 1)
    await store.send(.promptSubmitted(surfaceID: surface))
    #expect(store.state.file.boxes[id: surface]?.messages.isEmpty == true)
  }

  @Test(.dependencies) func sessionEndAndPaneCloseDropTheBox() async {
    let store = Self.makeStore()
    let first = UUID()
    let second = UUID()
    await Self.deliver(store, surface: first, "a")
    await Self.deliver(store, surface: second, "b")

    await store.send(.sessionEnded(surfaceID: first))
    #expect(Array(store.state.file.boxes.ids) == [second])
    #expect(store.state.selectedSurfaceID == second)

    await store.send(.surfacesClosed([second]))
    #expect(store.state.file.boxes.isEmpty)
    #expect(store.state.selectedSurfaceID == nil)
  }

  @Test(.dependencies) func closeStaleMailboxDropsOnlyThatBox() async {
    let store = Self.makeStore()
    let stale = UUID()
    let live = UUID()
    await Self.deliver(store, surface: stale, "old")
    await Self.deliver(store, surface: live, "new")

    await store.send(.closeStaleMailbox(stale))
    #expect(Array(store.state.file.boxes.ids) == [live])
  }

  @Test(.dependencies) func readAloudSpeaksTheGivenMessageAsPlainText() async {
    let spoken = LockIsolated<[String]>([])
    let store = Self.makeStore(speak: { text in spoken.withValue { $0.append(text) } })
    let surface = UUID()
    await Self.deliver(store, surface: surface, "**All** done")
    await Self.deliver(store, surface: surface, "newer")
    let older = store.state.file.boxes[id: surface]!.messages[1].id

    await store.send(.readAloudToggled(older))
    #expect(store.state.isReadingAloud)
    await store.receive(\.readAloudFinished)
    #expect(!store.state.isReadingAloud)
    #expect(spoken.value == ["All done"])
  }

  @Test(.dependencies) func readAloudPressedAgainStopsFromAnyPane() async {
    let store = Self.makeStore(speak: { _ in try? await Task.never() })
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")

    await store.send(.readAloudToggled(store.state.file.boxes[id: surface]!.messages[0].id))
    #expect(store.state.isReadingAloud)

    // No focused pane (or one without mail) still stops it.
    await store.send(.readAloudToggled(nil))
    #expect(!store.state.isReadingAloud)
    await store.finish()
  }

  @Test(.dependencies) func removingTheMessageBeingReadStillLetsThePressStopIt() async {
    let store = Self.makeStore(speak: { _ in try? await Task.never() })
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    let messageID = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.readAloudToggled(messageID))
    await store.send(.markDone(messageID))
    #expect(store.state.isReadingAloud)

    await store.send(.readAloudToggled(nil))
    #expect(!store.state.isReadingAloud)
    await store.finish()
  }

  @Test(.dependencies) func readAloudIsANoOpWithoutMail() async {
    let store = Self.makeStore()
    await store.send(.readAloudToggled(UUID()))
    await store.send(.readAloudToggled(nil))
    #expect(!store.state.isReadingAloud)
  }

  @Test(.dependencies) func replyDelegatesTheQuotedTextAndKeepsTheMessageUntilDelivered() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    let id = store.state.file.boxes[id: surface]!.messages[0].id

    await store.send(.replySent(id, text: "  ship it\n"))
    await store.receive(
      \.delegate,
      .sendReply(messageID: id, surfaceID: surface, text: MailboxFeature.replyQuote(for: "hello") + "ship it"))
    #expect(store.state.file.boxes[id: surface]?.messages.map(\.id) == [id])
  }

  @Test(.dependencies) func blankReplyIsANoOp() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hello")
    let id = store.state.file.boxes[id: surface]!.messages[0].id

    store.exhaustivity = .on
    await store.send(.replySent(id, text: " \n "))
  }

  @Test func replyQuoteKeepsShortMessagesWhole() {
    #expect(MailboxFeature.replyQuote(for: "Just one line") == "<replying-to>\nJust one line\n</replying-to>\n\n")
    #expect(MailboxFeature.replyQuote(for: "one\n\ntwo\n") == "<replying-to>\none\ntwo\n</replying-to>\n\n")
  }

  @Test func replyQuoteCapsLongLines() {
    let long = String(repeating: "x", count: 400)
    let quote = MailboxFeature.replyQuote(for: long)
    #expect(quote.contains(String(repeating: "x", count: MailboxFeature.quotedLineCharacterCap) + "…"))
    #expect(!quote.contains(String(repeating: "x", count: MailboxFeature.quotedLineCharacterCap + 1)))
  }

  @Test func applyStructureKeepsSurvivingSelection() {
    var state = MailboxFeature.State()
    let first = UUID()
    let second = UUID()
    let row = { (id: UUID) in
      MailboxStructure.Row(
        id: id, worktreeID: Self.worktreeID, tab: nil, worktreeName: "wt", repositoryName: "repo",
        agent: .claude, unreadCount: 0, messageCount: 1, isStale: false)
    }
    state.applyStructure(MailboxStructure(rows: [row(first), row(second)]))
    #expect(state.selectedSurfaceID == first)
    state.selectedSurfaceID = second
    state.applyStructure(MailboxStructure(rows: [row(second)]))
    #expect(state.selectedSurfaceID == second)
    state.applyStructure(MailboxStructure(rows: [row(first)]))
    #expect(state.selectedSurfaceID == first)
  }
}

@MainActor
struct TerminalTabChromeMailTests {
  @Test func stripActionsNeedMailAndAWiredHandler() {
    let chrome = TerminalTabChrome()
    #expect(chrome.stripActions.isEmpty)

    chrome.hasMail = true
    #expect(chrome.stripActions.isEmpty)

    let opened = LockIsolated(0)
    let readAloud = LockIsolated(0)
    chrome.showLastMessage = { opened.withValue { $0 += 1 } }
    chrome.readLastMessageAloud = { readAloud.withValue { $0 += 1 } }
    let actions = chrome.stripActions
    #expect(
      actions.map(\.shortcut.id) == [AppShortcuts.showLastAgentMessage.id, AppShortcuts.readLastAgentMessageAloud.id])
    actions.forEach { $0.perform() }
    #expect(opened.value == 1)
    #expect(readAloud.value == 1)

    chrome.hasMail = false
    #expect(chrome.stripActions.isEmpty)
  }
}

struct SpeakableTextTests {
  @Test func blocksGetTheirOwnLinesWithoutMarkup() {
    let markdown = "# Done\n\nAll **tests** pass, see [the log](https://example.com).\n\n- one\n- `two`"
    #expect(SpeakableText.plainText(fromMarkdown: markdown) == "Done\nAll tests pass, see the log.\none\ntwo")
  }

  @Test func hardWrappedLinesDoNotRunTogether() {
    let spoken = SpeakableText.plainText(fromMarkdown: "All tests\npass now.")
    #expect(!spoken.contains("testspass"))
    #expect(spoken.contains("tests") && spoken.contains("pass now."))
  }

  @Test func codeBlocksAreNamedNotRead() {
    let markdown = "Run:\n\n```swift\nlet x = 1\n```\n\nThen ship."
    #expect(SpeakableText.plainText(fromMarkdown: markdown) == "Run:\nCode block.\nThen ship.")
  }
}

extension MailboxFeatureTests {
  @Test(.dependencies) func arrowsMoveIntoAndThroughTheSelectedSessionsMessages() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "first")
    await Self.deliver(store, surface: surface, "second")
    await Self.deliver(store, surface: surface, "third")
    let ids = store.state.file.boxes[id: surface]!.messages.map(\.id)

    await store.send(.moveFocus(.right))
    #expect(store.state.focusedMessageID == ids[0])
    await store.send(.moveFocus(.down))
    await store.send(.moveFocus(.down))
    await store.send(.moveFocus(.down))
    #expect(store.state.focusedMessageID == ids[2])
    await store.send(.moveFocus(.up))
    #expect(store.state.focusedMessageID == ids[1])
    await store.send(.moveFocus(.right))
    #expect(store.state.focusedMessageID == ids[1])

    await store.send(.moveFocus(.left))
    #expect(store.state.focusedMessageID == nil)
    #expect(store.state.selectedSurfaceID == surface)
  }

  @Test(.dependencies) func returnMovesIntoTheMessagesThenOpensTheFocusedOne() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "first")
    await Self.deliver(store, surface: surface, "second")
    let ids = store.state.file.boxes[id: surface]!.messages.map(\.id)

    await store.send(.activateFocused)
    #expect(store.state.focusedMessageID == ids[0])
    #expect(store.state.openMessageID == nil)
    await store.send(.moveFocus(.down))
    await store.send(.activateFocused)
    #expect(store.state.openMessageID == ids[1])
    #expect(store.state.openMessage?.isRead == true)

    // The open message ignores the arrows, and closing it lands back on its row.
    await store.send(.moveFocus(.up))
    #expect(store.state.focusedMessageID == ids[1])
    await store.send(.viewerClosed)
    #expect(store.state.openMessageID == nil)
    #expect(store.state.focusedMessageID == ids[1])
  }

  @Test(.dependencies) func clickingFocusesTheMessageAndPickingASessionReturnsToTheList() async {
    let store = Self.makeStore()
    let first = UUID()
    let second = UUID()
    await Self.deliver(store, surface: first, "a")
    await Self.deliver(store, surface: second, "b")
    let id = store.state.file.boxes[id: first]!.messages[0].id

    await store.send(.messageOpened(id))
    #expect(store.state.focusedMessageID == id)
    await store.send(.viewerClosed)
    await store.send(.sessionSelected(second))
    #expect(store.state.focusedMessageID == nil)
  }

  @Test(.dependencies) func doneOnTheFocusedMessageMovesToItsNeighbourThenTheList() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "first")
    await Self.deliver(store, surface: surface, "second")
    let ids = store.state.file.boxes[id: surface]!.messages.map(\.id)

    await store.send(.moveFocus(.right))
    await store.send(.activateFocused)
    await store.send(.markDone(ids[0]))
    #expect(store.state.openMessageID == nil)
    #expect(store.state.focusedMessageID == ids[1])

    await store.send(.markDone(ids[1]))
    #expect(store.state.focusedMessageID == nil)
  }

  @Test(.dependencies) func submittingAReplyToTheFocusedMessageMovesToItsNeighbour() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "first")
    await Self.deliver(store, surface: surface, "second")
    let ids = store.state.file.boxes[id: surface]!.messages.map(\.id)

    await store.send(.moveFocus(.right))
    await store.send(.replyTapped(ids[0]))
    await store.send(.promptSubmitted(surfaceID: surface))
    #expect(store.state.focusedMessageID == ids[1])
  }

  @Test(.dependencies) func endingTheSelectedSessionReturnsTheKeysToTheList() async {
    let store = Self.makeStore()
    let first = UUID()
    let second = UUID()
    await Self.deliver(store, surface: first, "a")
    await Self.deliver(store, surface: second, "b")

    await store.send(.moveFocus(.right))
    #expect(store.state.focusedMessageID != nil)
    await store.send(.sessionEnded(surfaceID: first))
    #expect(store.state.selectedSurfaceID == second)
    #expect(store.state.focusedMessageID == nil)
  }

  @Test(.dependencies) func losingTheSelectedRowReturnsTheKeysToTheList() {
    var state = MailboxFeature.State()
    let survivor = UUID()
    state.selectedSurfaceID = UUID()
    state.focusedMessageID = UUID()

    state.applyStructure(
      MailboxStructure(rows: [
        MailboxStructure.Row(
          id: survivor, worktreeID: Self.worktreeID, tab: nil, worktreeName: "", repositoryName: "",
          agent: .claude, unreadCount: 0, messageCount: 0, isStale: false)
      ]))
    #expect(state.selectedSurfaceID == survivor)
    #expect(state.focusedMessageID == nil)
  }

  @Test(.dependencies) func returnInAPaneOpenedViewerKeepsItClosingToThePane() async {
    let store = Self.makeStore()
    let surface = UUID()
    await Self.deliver(store, surface: surface, "hi")

    await store.send(.lastMessageOpened(surfaceID: surface))
    await store.send(.activateFocused)
    #expect(store.state.viewerReturnsToPane)
  }
}
