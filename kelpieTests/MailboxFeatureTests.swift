import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct MailboxFeatureTests {
  private static let worktreeID = WorktreeID("/tmp/mailbox/wt")

  private static func makeStore() -> TestStoreOf<MailboxFeature> {
    let store = TestStore(initialState: MailboxFeature.State()) {
      MailboxFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
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
