import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct ThreadsPodSelectionTests {
  private static let worktreeID = WorktreeID("/tmp/threads/wt")
  private static let podID = PodID(rawValue: UUID())

  private static func row(_ id: UUID, memberName: String?, isStale: Bool = false) -> ThreadsStructure.Row {
    ThreadsStructure.Row(
      id: id, worktreeID: worktreeID, tab: nil, worktreeName: "wt", repositoryName: "repo",
      agent: .claude, unreadCount: 0, messageCount: 1, isStale: isStale, summary: nil, memberName: memberName,
      branchName: nil)
  }

  /// Two members in a pod and one session on its own, each with one message.
  private struct Fixture {
    let store: TestStoreOf<ThreadsFeature>
    let alpha: UUID
    let beta: UUID
    let loner: UUID
  }

  private struct Members {
    let alpha: UUID
    let beta: UUID
    let loner: UUID
  }

  private static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private static func makeState(betaIsStale: Bool = false) -> (ThreadsFeature.State, Members) {
    let members = Members(alpha: UUID(), beta: UUID(), loner: UUID())
    var state = ThreadsFeature.State()
    state.$file.withLock { file in
      let seeds = [(members.alpha, "from alpha"), (members.beta, "from beta"), (members.loner, "alone")]
      for (offset, (surface, body)) in seeds.enumerated() {
        var box = MessageThread(surfaceID: surface, worktreeID: worktreeID, agent: .claude)
        box.messages = [MailMessage(id: UUID(), body: body, createdAt: start.addingTimeInterval(Double(offset)))]
        file.boxes.append(box)
      }
    }
    let pod = ThreadsStructure.PodRow(
      id: podID, name: "Crew",
      members: [
        row(members.alpha, memberName: "Alpha"), row(members.beta, memberName: "Beta", isStale: betaIsStale),
      ])
    state.applyStructure(ThreadsStructure(tiles: [.pod(pod), .session(row(members.loner, memberName: nil))]))
    return (state, members)
  }

  private static func makeStore(betaIsStale: Bool = false) -> Fixture {
    let (state, members) = makeState(betaIsStale: betaIsStale)
    let store = TestStore(initialState: state) {
      ThreadsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = start.addingTimeInterval(60)
    }
    store.exhaustivity = .off
    return Fixture(store: store, alpha: members.alpha, beta: members.beta, loner: members.loner)
  }

  @Test(.dependencies) func aPodTileShowsEveryMemberGroupedAndChipsHideThem() async {
    let fixture = Self.makeStore()
    let (store, alpha, beta) = (fixture.store, fixture.alpha, fixture.beta)
    await store.send(.tileSelected(.pod(Self.podID)))
    #expect(store.state.messageGroups.map(\.title) == ["Alpha", "Beta"])
    #expect(store.state.visibleMemberIDs == [alpha, beta])

    await store.send(.memberToggled(podID: Self.podID, surfaceID: alpha))
    #expect(store.state.messageGroups.map(\.id) == [beta])
    // The last visible member cannot be hidden.
    await store.send(.memberToggled(podID: Self.podID, surfaceID: beta))
    #expect(store.state.messageGroups.map(\.id) == [beta])
    await store.send(.memberToggled(podID: Self.podID, surfaceID: alpha))
    #expect(store.state.visibleMemberIDs == [alpha, beta])
  }

  @Test(.dependencies) func aPaneInAPodOpensThePodThreadWithEveryMemberShowing() async {
    let fixture = Self.makeStore()
    let (store, alpha, beta, loner) = (fixture.store, fixture.alpha, fixture.beta, fixture.loner)
    await store.send(.tileSelected(.pod(Self.podID)))
    await store.send(.memberToggled(podID: Self.podID, surfaceID: alpha))
    #expect(store.state.messageGroups.map(\.id) == [beta])

    await store.send(.threadSelected(forSurface: beta))
    #expect(store.state.selectedThreadID == .pod(Self.podID))
    #expect(store.state.visibleMemberIDs == [alpha, beta])

    await store.send(.threadSelected(forSurface: loner))
    #expect(store.state.selectedThreadID == .session(loner))
  }

  @Test(.dependencies) func aMemberTileShowsThePodThreadNarrowedToThatMember() async {
    let fixture = Self.makeStore()
    let (store, alpha, beta) = (fixture.store, fixture.alpha, fixture.beta)
    await store.send(.tileSelected(.session(beta)))
    #expect(store.state.selectedThreadID == .session(beta))
    #expect(store.state.displayedThreadID == .pod(Self.podID))
    #expect(store.state.messageGroups.map(\.id) == [beta])
    #expect(store.state.selectedBox == nil)

    // A chip from a member tile moves to the pod tile with both showing.
    await store.send(.memberToggled(podID: Self.podID, surfaceID: alpha))
    #expect(store.state.selectedThreadID == .pod(Self.podID))
    #expect(store.state.visibleMemberIDs == [alpha, beta])
  }

  @Test(.dependencies) func spaceJumpsToASessionTileButNotAPod() async {
    let fixture = Self.makeStore()
    let (store, loner) = (fixture.store, fixture.loner)
    await store.send(.tileSelected(.pod(Self.podID)))
    await store.send(.jumpToFocused)
    await store.send(.tileSelected(.session(loner)))
    await store.send(.jumpToFocused)
    await store.receive(\.delegate.jumpToSession)
  }

  @Test(.dependencies) func collapsingAPodSkipsItsMembersWhenWalkingTiles() async {
    let fixture = Self.makeStore()
    let (store, alpha, loner) = (fixture.store, fixture.alpha, fixture.loner)
    await store.send(.tileSelected(.pod(Self.podID)))
    await store.send(.moveFocus(.down))
    #expect(store.state.selectedThreadID == .session(alpha))
    await store.send(.tileSelected(.pod(Self.podID)))
    await store.send(.podExpansionToggled(Self.podID))
    await store.send(.moveFocus(.down))
    #expect(store.state.selectedThreadID == .session(loner))
    // Opening a member's thread from its pane expands the pod again.
    await store.send(.threadSelected(forSurface: alpha))
    #expect(store.state.collapsedPods.isEmpty)
  }

  @Test(.dependencies) func markAllDoneClearsAPodOrOneSession() async {
    let fixture = Self.makeStore()
    let (store, alpha, beta, loner) = (fixture.store, fixture.alpha, fixture.beta, fixture.loner)
    await store.send(.tileSelected(.session(loner)))
    await store.send(.moveFocus(.right))
    #expect(store.state.focusedMessageID != nil)
    await store.send(.markAllDone(.session(loner)))
    #expect(store.state.file.boxes[id: loner]?.messages.isEmpty == true)
    #expect(store.state.focusedMessageID == nil)
    #expect(store.state.file.boxes[id: alpha]?.messages.count == 1)

    await store.send(.replyToLatest(surfaceID: alpha))
    #expect(store.state.openMessage?.body == "from alpha")
    #expect(store.state.viewerReturnsToThread)
    await store.send(.markAllDone(.pod(Self.podID)))
    #expect(store.state.openMessage == nil)
    #expect(store.state.file.boxes[id: alpha]?.messages.isEmpty == true)
    #expect(store.state.file.boxes[id: beta]?.messages.isEmpty == true)

    await store.send(.sessionViewRequested(surfaceID: beta))
    await store.receive(\.delegate.jumpToSession)
  }

  @Test(.dependencies) func aThreadReplyGoesToEveryShownLiveMember() async {
    let fixture = Self.makeStore()
    let (store, alpha, beta) = (fixture.store, fixture.alpha, fixture.beta)
    await store.send(.tileSelected(.pod(Self.podID)))
    await store.send(.memberToggled(podID: Self.podID, surfaceID: alpha))
    await store.send(.threadReplySent(text: "go"))
    await store.receive(
      \.delegate, .sendReply(surfaceID: beta, text: "go", echo: "go"))
    await store.send(.replyDelivered(surfaceID: beta, text: "go"))
    #expect(store.state.timeline.map(\.authorName) == ["Beta", "You"])
    #expect(
      store.state.pendingSummaryInput[.pod(Self.podID)] == nil
        || store.state.summariesInFlight.contains(.pod(Self.podID)))
  }

  @Test(.dependencies) func doneInAPodThreadRemovesTheMessageFromItsMember() async {
    let fixture = Self.makeStore()
    let (store, alpha) = (fixture.store, fixture.alpha)
    await store.send(.tileSelected(.pod(Self.podID)))
    let messageID = store.state.file.boxes[id: alpha]!.messages[0].id
    await store.send(.markDone(messageID))
    #expect(store.state.file.boxes[id: alpha]?.messages.isEmpty == true)
  }

  @Test(.dependencies) func aThreadReplySkipsStaleMembersAndAnUnknownSurfaceDeliversNothing() async {
    let fixture = Self.makeStore(betaIsStale: true)
    let (store, alpha) = (fixture.store, fixture.alpha)
    await store.send(.tileSelected(.pod(Self.podID)))
    store.exhaustivity = .on
    await store.send(.threadReplySent(text: "go"))
    await store.receive(
      \.delegate, .sendReply(surfaceID: alpha, text: "go", echo: "go"))
    await store.send(.replyDelivered(surfaceID: UUID(), text: "lost"))
  }

  @Test(.dependencies) func aDeliveredReplyClosesTheViewerOnItsSession() async {
    let fixture = Self.makeStore()
    let (store, alpha) = (fixture.store, fixture.alpha)
    let messageID = store.state.file.boxes[id: alpha]!.messages[0].id
    await store.send(.messageOpened(messageID))
    #expect(store.state.openMessageID == messageID)
    await store.send(.replyDelivered(surfaceID: alpha, text: "ok"))
    #expect(store.state.openMessageID == nil)
    #expect(store.state.timeline.map(\.authorName) == ["Alpha", "Beta", "You"])
  }

  @Test(.dependencies) func structureChangesPruneFiltersAndKeepOrResetTheSelection() {
    var (state, members) = Self.makeState()
    state.selectedThreadID = .session(members.alpha)
    state.hiddenMembers[Self.podID] = [members.beta]

    // Alpha leaves the pod: the filter forgets it and its tile is now a loner's.
    let reduced = ThreadsStructure.PodRow(
      id: Self.podID, name: "Crew", members: [Self.row(members.beta, memberName: "Beta")])
    state.applyStructure(
      ThreadsStructure(tiles: [
        .pod(reduced), .session(Self.row(members.alpha, memberName: nil)),
        .session(Self.row(members.loner, memberName: nil)),
      ]))
    #expect(state.hiddenMembers[Self.podID] == [members.beta])
    #expect(state.selectedThreadID == .session(members.alpha))
    #expect(state.displayedThreadID == .session(members.alpha))

    // Beta leaves too: nothing is left to hide. The pod goes: selection falls back to the first tile.
    state.selectedThreadID = .pod(Self.podID)
    state.applyStructure(
      ThreadsStructure(tiles: [
        .session(Self.row(members.alpha, memberName: nil)), .session(Self.row(members.loner, memberName: nil)),
      ]))
    #expect(state.hiddenMembers.isEmpty)
    #expect(state.selectedThreadID == .session(members.alpha))
  }
}
