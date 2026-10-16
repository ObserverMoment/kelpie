import AppKit
import ComposableArchitecture
import Foundation
import KelpieSettingsShared

private nonisolated let threadsLogger = KelpieLogger("Threads")

/// Threads of the messages agents end their turns with: one per session in no
/// pod, one per pod showing its members' messages together, each headed by a
/// rolling summary that Claude rewrites on every delivery. Owns the persisted
/// inboxes and summaries, the tile selection, the pod filters and the open
/// message; `AppFeature` feeds it deliveries and lifecycle events and acts on
/// its delegate.
@Reducer
struct ThreadsFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.threads) var file: ThreadsFile
    @Shared(.settingsFile) var settingsFile
    var structure: ThreadsStructure = .empty
    /// The ⌘F filter over the tile list.
    var tileSearch = SearchFilterFeature.State()
    /// The ⌘F filter over the shown thread's messages.
    var messageSearch = SearchFilterFeature.State()
    /// `structure` pruned to the tile query; only read while one is active.
    var filteredStructure: ThreadsStructure = .empty
    /// What the tile list draws and the arrows walk: the filtered tiles while
    /// a query is active, else every tile.
    var visibleStructure: ThreadsStructure { tileSearch.activeQuery == nil ? structure : filteredStructure }
    /// The selected tile: a pod, a session in no pod, or one member of a pod.
    var selectedThreadID: ThreadID?
    /// The message shown full-window, if any.
    var openMessageID: MailMessage.ID?
    /// The message the arrow keys are on; `nil` while they are on the tile list.
    var focusedMessageID: MailMessage.ID?
    /// The message last opened from its pane rather than the thread. Closing
    /// it leaves the overlay for that pane instead of going back to the thread.
    var paneOpenedMessageID: MailMessage.ID?
    /// Surfaces whose tab chrome last carried an unread-mail badge, so a box
    /// that empties or closes gets its badge cleared.
    var badgedSurfaceIDs: Set<UUID> = []
    /// A message is being read aloud; the next Read Aloud press stops it.
    var isReadingAloud = false
    /// The reply box under the timeline has the keys, so the overlay's key
    /// monitor must stand aside for it.
    var isPanelReplyFocused = false
    /// Pods whose member tiles are folded away; every pod starts expanded.
    var collapsedPods: Set<PodID> = []
    /// Members a pod thread leaves out, per pod, from the chips.
    var hiddenMembers: [PodID: Set<UUID>] = [:]
    var summariesInFlight: Set<ThreadID> = []
    /// Bodies delivered since a thread's last summary run started; the next
    /// run folds them all in at once.
    var pendingSummaryInput: [ThreadID: [String]] = [:]

    var unreadCount: Int { file.unreadCount }

    var expandedPods: Set<PodID> { Set(structure.pods.map(\.id)).subtracting(collapsedPods) }

    /// The thread the right panel shows: a member tile shows its pod's thread.
    var displayedThreadID: ThreadID? {
      guard case .session(let surfaceID)? = selectedThreadID else { return selectedThreadID }
      return structure.threadID(containingSurface: surfaceID) ?? selectedThreadID
    }

    /// The selected session thread; `nil` for a pod thread.
    var selectedBox: MessageThread? {
      guard case .session(let surfaceID)? = displayedThreadID else { return nil }
      return file.boxes[id: surfaceID]
    }

    var selectedRow: ThreadsStructure.Row? {
      guard case .session(let surfaceID)? = displayedThreadID else { return nil }
      return structure.rowsBySurface[surfaceID]
    }

    var displayedPod: ThreadsStructure.PodRow? {
      guard case .pod(let podID)? = displayedThreadID else { return nil }
      return structure.pod(podID)
    }

    /// The members whose messages the pod thread shows: just the selected
    /// member, or everyone the chips have not hidden.
    var visibleMemberIDs: Set<UUID> {
      guard let pod = displayedPod else { return [] }
      if case .session(let member)? = selectedThreadID { return [member] }
      return Set(pod.members.map(\.id)).subtracting(hiddenMembers[pod.id] ?? [])
    }

    /// The right panel's messages, newest first within each session.
    var messageGroups: [MessageGroup] {
      if let pod = displayedPod {
        let visible = visibleMemberIDs
        return pod.members.filter { visible.contains($0.id) }.compactMap { member in
          file.boxes[id: member.id].map {
            MessageGroup(id: member.id, title: member.memberName ?? member.worktreeName, messages: $0.messages)
          }
        }
      }
      return selectedBox.map { [MessageGroup(id: $0.surfaceID, title: nil, messages: $0.messages)] } ?? []
    }

    /// The right panel's timeline, oldest first, newest at the bottom. Each
    /// session's messages keep their delivery order; the stable sort only
    /// interleaves sessions by time.
    var timeline: [TimelineEntry] {
      messageGroups.flatMap { group in
        group.messages.reversed().map { TimelineEntry(message: $0, memberName: group.title) }
      }
      .sorted { $0.message.createdAt < $1.message.createdAt }
    }

    /// The timeline the panel shows: only the messages whose body contains
    /// the message query while one is active.
    var visibleTimeline: [TimelineEntry] {
      guard let query = messageSearch.activeQuery else { return timeline }
      return timeline.filter { SearchMatch.matches(query, $0.message.body) }
    }

    var selectedMessageIDs: [MailMessage.ID] { visibleTimeline.map(\.id) }

    /// The reply box under the timeline can send: at least one shown session
    /// has a live agent.
    var canReplyToDisplayed: Bool {
      messageGroups.contains { structure.rowsBySurface[$0.id]?.isStale == false }
    }

    var selectedSummary: String? { displayedThreadID.flatMap(summary(for:)) }

    var isSummarizingSelected: Bool { displayedThreadID.map(summariesInFlight.contains) ?? false }

    var openMessage: MailMessage? { openMessageID.flatMap(file.message) }

    /// The session row the open message belongs to.
    var openMessageRow: ThreadsStructure.Row? {
      openMessageID.flatMap(file.surfaceID(containing:)).flatMap { structure.rowsBySurface[$0] }
    }

    /// Closing the open message goes back to its pane, not the thread.
    var viewerReturnsToPane: Bool { openMessageID != nil && openMessageID == paneOpenedMessageID }

    /// Closing the open message goes back to the thread.
    var viewerReturnsToThread: Bool { openMessageID != nil && !viewerReturnsToPane }

    func summary(for threadID: ThreadID) -> String? {
      switch threadID {
      case .session(let surfaceID): file.boxes[id: surfaceID]?.summary
      case .pod(let podID): file.podSummaries[podID.rawValue.uuidString]
      }
    }

    /// Messages left the shown thread: the arrow keys move to the nearest
    /// survivor, or back to the tile list once the thread is empty.
    mutating func reconcileFocusedMessage(previous: [MailMessage.ID]) {
      focusedMessageID = FleetViewNavigation.reconcile(
        focused: focusedMessageID, previous: previous, current: selectedMessageIDs)
    }

    /// The overlay left for another session or a launch: a viewer opened from
    /// a pane must not reappear, pointing at that pane, on the next open.
    mutating func dropPaneViewer() {
      guard viewerReturnsToPane else { return }
      openMessageID = nil
      paneOpenedMessageID = nil
    }

    /// Stores a freshly computed structure when it changed, prunes filters for
    /// pods and members that are gone, and keeps the selection on a surviving
    /// tile, falling back to the first.
    mutating func applyStructure(_ next: ThreadsStructure) {
      guard next != structure else { return }
      structure = next
      refilterStructure()
      hiddenMembers = Dictionary(
        uniqueKeysWithValues: hiddenMembers.compactMap { podID, hidden in
          let remaining = hidden.intersection(next.memberIDs(of: podID))
          return remaining.isEmpty ? nil : (podID, remaining)
        })
      let tiles = next.navigationOrder(expandedPods: Set(next.pods.map(\.id)))
      if let selected = selectedThreadID, tiles.contains(selected) { return }
      selectedThreadID = next.tiles.first?.id
      openMessageID = nil
      focusedMessageID = nil
    }

    /// Re-derives the filtered tiles from the full structure and the live
    /// query. A selection the filter hid moves to the first visible tile, as
    /// Fleet and Pods move their focus; with nothing visible it stays, so the
    /// panel keeps showing the thread.
    mutating func refilterStructure() {
      guard let query = tileSearch.activeQuery else { return }
      filteredStructure = structure.filtered(query: query)
      let visible = filteredStructure.navigationOrder(expandedPods: Set(filteredStructure.pods.map(\.id)))
      guard let first = visible.first, let selected = selectedThreadID, !visible.contains(selected) else { return }
      selectedThreadID = first
      openMessageID = nil
      focusedMessageID = nil
    }
  }

  /// One session's messages in the right panel; titled only inside a pod thread.
  struct MessageGroup: Identifiable, Equatable, Sendable {
    /// The surface id.
    let id: UUID
    let title: String?
    let messages: [MailMessage]
  }

  /// One message on the timeline with who sent it.
  struct TimelineEntry: Identifiable, Equatable, Sendable {
    let message: MailMessage
    /// The member's name inside a pod thread.
    let memberName: String?

    var id: MailMessage.ID { message.id }

    var authorName: String { Self.authorName(for: message.author, memberName: memberName) }

    /// "You" for a reply, the member's name in a pod, else the agent. The
    /// summary prompt labels its lines the same way.
    static func authorName(for author: MailMessage.Author, memberName: String?) -> String {
      switch author {
      case .user: "You"
      case .agent: memberName ?? "Agent"
      }
    }
  }

  enum Action: Equatable {
    /// A delivery; `podID` and `memberName` are the session's pod and its name
    /// there, so the pod summary rolls too and its lines name the member.
    case received(
      surfaceID: UUID, worktreeID: Worktree.ID, agent: SkillAgent, body: String, podID: PodID? = nil,
      memberName: String? = nil)
    case tileSelected(ThreadID?)
    /// A pane asked for its thread: its own tile, or its pod's tile with every
    /// member showing.
    case threadSelected(forSurface: UUID)
    case podExpansionToggled(PodID)
    /// The reply box under the timeline took or gave up the keys.
    case panelReplyFocusChanged(Bool)
    /// Tab: the reply box under the timeline takes the keys, when it can send.
    case panelReplyFocusRequested
    /// A chip: hides or shows one member's messages in the pod thread. From a
    /// member tile it moves to the pod tile with both members showing.
    case memberToggled(podID: PodID, surfaceID: UUID)
    /// Arrow keys: ↑/↓ walk the tiles, or the shown thread's messages once →
    /// has moved into them; ← goes back to the tiles. Ignored while a
    /// message is open.
    case moveFocus(FleetViewNavigation.Direction)
    /// Return: opens the focused message, or moves into the thread's messages.
    case activateFocused
    /// Space: leaves the overlay for the selected session's pane. No-op on a
    /// pod tile or while a message is open.
    case jumpToFocused
    /// Shows the message full-window and marks it read.
    case messageOpened(MailMessage.ID)
    /// Opens a pane's newest message, closing back to that pane. No-op when
    /// the pane has no mail.
    case lastMessageOpened(surfaceID: UUID)
    case viewerClosed
    /// Stops the reading, from anywhere, or reads the message aloud. No-op
    /// when nothing is reading and there is no message.
    case readAloudToggled(MailMessage.ID?)
    case readAloudFinished
    /// The viewer's reply box: sends the quoted reply, with any dropped files'
    /// paths after it, to the message's session. No-op when both are blank.
    case replySent(MailMessage.ID, text: String, attachments: [URL] = [])
    /// The thread's reply box: sends the reply to every session the thread
    /// shows, quoting each one's newest message. No-op when both are blank.
    case threadReplySent(text: String, attachments: [URL] = [])
    /// The reply landed in the session: it joins the thread as the user's
    /// message and closes the viewer if it was open on that session.
    case replyDelivered(surfaceID: UUID, text: String)
    /// The overlay closed: the reply box lets go of the keys, and a viewer
    /// opened from a pane closes with it, so the thread shows next time.
    case overlayDismissed
    case tileSearch(SearchFilterFeature.Action)
    case messageSearch(SearchFilterFeature.Action)
    /// The tick: the message leaves the thread.
    case markDone(MailMessage.ID)
    /// The tile's context menu: every message in the thread is done. For a
    /// pod, that is every member's.
    case markAllDone(ThreadID)
    /// The tile's context menu: opens the session's newest message with the
    /// reply box focused. No-op when the session has no mail.
    case replyToLatest(surfaceID: UUID)
    /// The tile's context menu: leaves the overlay for the session's pane.
    case sessionViewRequested(surfaceID: UUID)
    case sessionEnded(surfaceID: UUID)
    case surfacesClosed(Set<UUID>)
    case closeStaleThread(UUID)
    /// The pod is gone: its summary, filter and expansion go with it.
    case podRemoved(PodID)
    case summaryUpdated(ThreadID, String)
    case summaryFailed(ThreadID, String)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// A viewer opened from a pane closed: leave the overlay for that pane.
    case closedToPane(worktreeID: Worktree.ID, surfaceID: UUID)
    /// Space on a session tile: leave the overlay for that session's pane.
    case jumpToSession(worktreeID: Worktree.ID, surfaceID: UUID)
    /// Deliver `text` to the session and submit it; `echo` is what the thread
    /// shows for it once it lands.
    case sendReply(surfaceID: UUID, text: String, echo: String)
  }

  private nonisolated enum CancelID: Hashable, Sendable {
    case readAloud
    case summary(ThreadID)
  }

  @Dependency(\.uuid) private var uuid
  @Dependency(\.date.now) private var now
  @Dependency(SpeechClient.self) private var speechClient
  @Dependency(ThreadSummaryClient.self) private var summaryClient

  var body: some Reducer<State, Action> {
    Scope(state: \.tileSearch, action: \.tileSearch) {
      SearchFilterFeature()
    }
    Scope(state: \.messageSearch, action: \.messageSearch) {
      SearchFilterFeature()
    }
    Reduce { state, action in
      switch action {
      case .tileSearch(.queryChanged), .tileSearch(.dismissed):
        state.refilterStructure()
        return .none

      case .messageSearch(.queryChanged), .messageSearch(.dismissed):
        // A focused message the filter hid gives the keys back to the tiles.
        if let focused = state.focusedMessageID, !state.selectedMessageIDs.contains(focused) {
          state.focusedMessageID = nil
        }
        return .none

      case .tileSearch, .messageSearch:
        return .none

      case .received(let surfaceID, let worktreeID, let agent, let body, let podID, let memberName):
        let message = MailMessage(id: uuid(), body: body, createdAt: now)
        state.$file.withLock { file in
          if file.boxes[id: surfaceID] == nil {
            file.boxes.append(MessageThread(surfaceID: surfaceID, worktreeID: worktreeID, agent: agent))
          }
          file.boxes[id: surfaceID]?.messages.insert(message, at: 0)
        }
        if state.selectedThreadID == nil { state.selectedThreadID = .session(surfaceID) }
        let author = TimelineEntry.authorName(for: .agent, memberName: memberName)
        return queueSummaries("\(author): \(body)", surfaceID: surfaceID, podID: podID, state: &state)

      case .tileSelected(let threadID):
        guard threadID != state.selectedThreadID else { return .none }
        state.selectedThreadID = threadID
        state.openMessageID = nil
        state.focusedMessageID = nil
        return .none

      case .threadSelected(forSurface: let surfaceID):
        guard let threadID = state.structure.threadID(containingSurface: surfaceID) else { return .none }
        state.selectedThreadID = threadID
        state.openMessageID = nil
        state.focusedMessageID = nil
        if case .pod(let podID) = threadID {
          state.collapsedPods.remove(podID)
          state.hiddenMembers[podID] = nil
        }
        return .none

      case .podExpansionToggled(let podID):
        state.collapsedPods.formSymmetricDifference([podID])
        return .none

      case .panelReplyFocusChanged(let isFocused):
        state.isPanelReplyFocused = isFocused
        return .none

      case .panelReplyFocusRequested:
        guard state.openMessageID == nil, state.canReplyToDisplayed else { return .none }
        state.isPanelReplyFocused = true
        return .none

      case .memberToggled(let podID, let surfaceID):
        let members = state.structure.memberIDs(of: podID)
        guard members.contains(surfaceID) else { return .none }
        if case .session(let selectedMember)? = state.selectedThreadID, members.contains(selectedMember) {
          state.selectedThreadID = .pod(podID)
          state.hiddenMembers[podID] = members.subtracting([selectedMember, surfaceID])
        } else {
          let hidden = (state.hiddenMembers[podID] ?? []).symmetricDifference([surfaceID])
          // The last visible member stays: an empty thread says nothing.
          guard hidden != members else { return .none }
          state.hiddenMembers[podID] = hidden
        }
        state.openMessageID = nil
        state.focusedMessageID = nil
        return .none

      case .moveFocus(let direction):
        guard state.openMessageID == nil else { return .none }
        let messageIDs = state.selectedMessageIDs
        switch direction {
        case .left:
          state.focusedMessageID = nil
        case .right:
          state.focusedMessageID = state.focusedMessageID ?? messageIDs.last
        case .up, .down:
          if let focused = state.focusedMessageID {
            state.focusedMessageID = FleetViewNavigation.move(
              from: focused, direction, sections: [messageIDs], columnCount: 1)
          } else {
            let tiles = state.visibleStructure.navigationOrder(expandedPods: state.expandedPods)
            state.selectedThreadID = FleetViewNavigation.move(
              from: state.selectedThreadID, direction, sections: [tiles], columnCount: 1)
          }
        }
        return .none

      case .activateFocused:
        guard state.openMessageID == nil else { return .none }
        if let focused = state.focusedMessageID, let surfaceID = state.file.surfaceID(containing: focused) {
          Self.open(focused, surfaceID: surfaceID, fromPane: false, state: &state)
        } else {
          state.focusedMessageID = state.selectedMessageIDs.last
        }
        return .none

      case .jumpToFocused:
        guard state.openMessageID == nil, case .session(let surfaceID)? = state.selectedThreadID,
          let box = state.file.boxes[id: surfaceID]
        else { return .none }
        return .send(.delegate(.jumpToSession(worktreeID: box.worktreeID, surfaceID: surfaceID)))

      case .messageOpened(let messageID):
        guard let surfaceID = state.file.surfaceID(containing: messageID) else { return .none }
        Self.open(messageID, surfaceID: surfaceID, fromPane: false, state: &state)
        return .none

      case .lastMessageOpened(let surfaceID):
        guard let newestID = state.file.newestMessageID(for: surfaceID) else { return .none }
        Self.open(newestID, surfaceID: surfaceID, fromPane: true, state: &state)
        return .none

      case .viewerClosed:
        return Self.closeViewer(state: &state)

      case .readAloudToggled(let messageID):
        if state.isReadingAloud {
          state.isReadingAloud = false
          return .cancel(id: CancelID.readAloud)
        }
        guard let body = messageID.flatMap({ state.file.message($0)?.body }) else { return .none }
        state.isReadingAloud = true
        let text = SpeakableText.plainText(fromMarkdown: body)
        return .run { [speechClient] send in
          await speechClient.speak(text)
          await send(.readAloudFinished)
        }
        .cancellable(id: CancelID.readAloud)

      case .readAloudFinished:
        state.isReadingAloud = false
        return .none

      case .replySent(let messageID, let text, let attachments):
        guard let reply = Self.replyText(text, attachments: attachments),
          let surfaceID = state.file.surfaceID(containing: messageID),
          let message = state.file.message(messageID)
        else { return .none }
        // The agent still has its own newest message in context, so only an
        // older one needs quoting to place the reply.
        let isNewest = state.file.boxes[id: surfaceID]?.newestAgentMessage?.id == messageID
        let quote = isNewest ? "" : Self.replyQuote(for: message.body)
        return .send(.delegate(.sendReply(surfaceID: surfaceID, text: quote + reply, echo: reply)))

      case .threadReplySent(let text, let attachments):
        guard let reply = Self.replyText(text, attachments: attachments) else { return .none }
        let sends = state.messageGroups.compactMap { group -> Effect<Action>? in
          guard state.structure.rowsBySurface[group.id]?.isStale == false else { return nil }
          return .send(.delegate(.sendReply(surfaceID: group.id, text: reply, echo: reply)))
        }
        return .merge(sends)

      case .replyDelivered(let surfaceID, let text):
        guard state.file.boxes[id: surfaceID] != nil else { return .none }
        let message = MailMessage(id: uuid(), body: text, createdAt: now, isRead: true, author: .user)
        state.$file.withLock { $0.boxes[id: surfaceID]?.messages.insert(message, at: 0) }
        let closes = state.openMessageID.flatMap(state.file.surfaceID(containing:)) == surfaceID
        let closeEffect: Effect<Action> = closes ? Self.closeViewer(state: &state) : .none
        let podID: PodID? =
          if case .pod(let podID)? = state.structure.threadID(containingSurface: surfaceID) { podID } else { nil }
        let author = TimelineEntry.authorName(for: .user, memberName: nil)
        return .merge(
          closeEffect, queueSummaries("\(author): \(text)", surfaceID: surfaceID, podID: podID, state: &state))

      case .overlayDismissed:
        state.isPanelReplyFocused = false
        // Reopening starts unfiltered.
        state.tileSearch = SearchFilterFeature.State()
        state.messageSearch = SearchFilterFeature.State()
        guard state.viewerReturnsToPane else { return .none }
        return Self.closeViewer(state: &state)

      case .markDone(let messageID):
        let effect = state.openMessageID == messageID ? Self.closeViewer(state: &state) : .none
        let previous = state.selectedMessageIDs
        state.$file.withLock { $0.remove(messageID) }
        state.reconcileFocusedMessage(previous: previous)
        return effect

      case .markAllDone(let threadID):
        let surfaceIDs: Set<UUID> =
          switch threadID {
          case .session(let surfaceID): [surfaceID]
          case .pod(let podID): state.structure.memberIDs(of: podID)
          }
        let openSurfaceID = state.openMessageID.flatMap(state.file.surfaceID(containing:))
        let effect = openSurfaceID.map(surfaceIDs.contains) == true ? Self.closeViewer(state: &state) : .none
        let previous = state.selectedMessageIDs
        state.$file.withLock { file in
          for surfaceID in surfaceIDs { file.boxes[id: surfaceID]?.messages.removeAll() }
        }
        state.reconcileFocusedMessage(previous: previous)
        return effect

      case .replyToLatest(let surfaceID):
        guard let newestID = state.file.newestMessageID(for: surfaceID) else { return .none }
        Self.open(newestID, surfaceID: surfaceID, fromPane: false, state: &state)
        return .none

      case .sessionViewRequested(let surfaceID):
        guard let box = state.file.boxes[id: surfaceID] else { return .none }
        return .send(.delegate(.jumpToSession(worktreeID: box.worktreeID, surfaceID: surfaceID)))

      case .sessionEnded(let surfaceID), .closeStaleThread(let surfaceID):
        return Self.removeBoxes([surfaceID], state: &state)

      case .surfacesClosed(let surfaceIDs):
        return Self.removeBoxes(surfaceIDs, state: &state)

      case .podRemoved(let podID):
        state.$file.withLock { $0.podSummaries[podID.rawValue.uuidString] = nil }
        state.hiddenMembers[podID] = nil
        state.collapsedPods.remove(podID)
        if state.selectedThreadID == .pod(podID) { state.selectedThreadID = nil }
        return Self.forgetSummary(.pod(podID), state: &state)

      case .summaryUpdated(let threadID, let text):
        state.summariesInFlight.remove(threadID)
        if !text.isEmpty {
          let summary = SummaryPrompt.truncate(text, cap: SummaryPrompt.cap(for: threadID.summaryKind))
          state.$file.withLock { file in
            switch threadID {
            case .session(let surfaceID): file.boxes[id: surfaceID]?.summary = summary
            case .pod(let podID): file.podSummaries[podID.rawValue.uuidString] = summary
            }
          }
        }
        return startSummary(threadID, state: &state)

      case .summaryFailed(let threadID, let detail):
        threadsLogger.warning("Summary for \(String(describing: threadID)) failed: \(detail)")
        state.summariesInFlight.remove(threadID)
        // Anything delivered meanwhile gets one more try; a dead run stays dead.
        return startSummary(threadID, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  /// The reply as the terminal receives it after the quote: the trimmed text,
  /// then any dropped files' escaped paths. `nil` when both are blank.
  private static func replyText(_ text: String, attachments: [URL]) -> String? {
    let paths = NSPasteboard.ghosttyEscapedPaths(attachments)
    let reply = [text.trimmingCharacters(in: .whitespacesAndNewlines), paths]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return reply.isEmpty ? nil : reply
  }

  /// Queues one line for the session's summary and, in a pod, the pod's.
  private func queueSummaries(_ line: String, surfaceID: UUID, podID: PodID?, state: inout State) -> Effect<Action> {
    let threadIDs = [ThreadID.session(surfaceID)] + (podID.map { [ThreadID.pod($0)] } ?? [])
    for threadID in threadIDs {
      state.pendingSummaryInput[threadID, default: []].append(line)
    }
    return .merge(threadIDs.map { startSummary($0, state: &state) })
  }

  /// Rolls the thread's summary forward with every body queued since the
  /// last run, unless a run is already out; it picks the queue up when done.
  /// Summaries off in Settings drop the queue instead, whenever it is read.
  private func startSummary(_ threadID: ThreadID, state: inout State) -> Effect<Action> {
    let settings = state.settingsFile.global
    guard settings.threadSummaryModel != .off else {
      state.pendingSummaryInput[threadID] = nil
      return .none
    }
    guard !state.summariesInFlight.contains(threadID),
      let newMessages = state.pendingSummaryInput.removeValue(forKey: threadID), !newMessages.isEmpty
    else { return .none }
    state.summariesInFlight.insert(threadID)
    let request = SummaryPrompt.request(
      kind: threadID.summaryKind, previous: state.summary(for: threadID), newMessages: newMessages,
      model: settings.threadSummaryModel, effort: settings.threadSummaryEffort)
    return .run { [summaryClient] send in
      do {
        await send(.summaryUpdated(threadID, try await summaryClient.summarize(request)))
      } catch {
        await send(.summaryFailed(threadID, error.localizedDescription))
      }
    }
    .cancellable(id: CancelID.summary(threadID))
  }

  private static func forgetSummary(_ threadID: ThreadID, state: inout State) -> Effect<Action> {
    state.summariesInFlight.remove(threadID)
    state.pendingSummaryInput[threadID] = nil
    return .cancel(id: CancelID.summary(threadID))
  }

  /// Shows a message full-window and marks it read. The shown thread stays
  /// when it already holds the message's session; otherwise that session's
  /// tile is selected.
  private static func open(
    _ messageID: MailMessage.ID, surfaceID: UUID, fromPane: Bool, state: inout State
  ) {
    if !state.messageGroups.contains(where: { $0.id == surfaceID }) {
      state.selectedThreadID = .session(surfaceID)
    }
    // The viewer replaces the panel, reply box included, before it can report.
    state.isPanelReplyFocused = false
    state.openMessageID = messageID
    state.focusedMessageID = messageID
    state.paneOpenedMessageID = fromPane ? messageID : nil
    state.$file.withLock { $0.update(messageID) { $0.isRead = true } }
  }

  /// Back to the thread, or out of the overlay to the pane the viewer was
  /// opened from.
  private static func closeViewer(state: inout State) -> Effect<Action> {
    let returnsToPane = state.viewerReturnsToPane
    let box = state.openMessageID.flatMap(state.file.surfaceID(containing:)).flatMap { state.file.boxes[id: $0] }
    state.openMessageID = nil
    state.paneOpenedMessageID = nil
    guard returnsToPane, let box else { return .none }
    return .send(.delegate(.closedToPane(worktreeID: box.worktreeID, surfaceID: box.surfaceID)))
  }

  private static func removeBoxes(_ surfaceIDs: Set<UUID>, state: inout State) -> Effect<Action> {
    guard surfaceIDs.contains(where: { state.file.boxes[id: $0] != nil }) else { return .none }
    state.$file.withLock { file in
      for id in surfaceIDs { file.boxes.remove(id: id) }
    }
    if case .session(let selected)? = state.selectedThreadID, surfaceIDs.contains(selected) {
      state.selectedThreadID = state.file.boxes.first.map { .session($0.surfaceID) }
      state.openMessageID = nil
      state.focusedMessageID = nil
    }
    // An emptied file swaps the panel for the empty state, reply box and all.
    if state.file.boxes.isEmpty { state.isPanelReplyFocused = false }
    return .merge(surfaceIDs.map { forgetSummary(.session($0), state: &state) })
  }

  /// Line cap on each quoted line, so a one-paragraph message quotes as a line,
  /// not the whole paragraph.
  static let quotedLineCharacterCap = 160

  /// What a sent reply starts with: the first and last lines of the message,
  /// enough for the agent to place it, then a blank line before the reply.
  /// Newlines travel inside a bracketed paste, so nothing submits early.
  static func replyQuote(for body: String) -> String {
    let lines =
      body
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .map { line -> String in
        line.count > quotedLineCharacterCap ? String(line.prefix(quotedLineCharacterCap)) + "…" : line
      }
    let excerpt = lines.count > 2 ? [lines[0], "…", lines[lines.count - 1]] : lines
    return (["<replying-to>"] + excerpt + ["</replying-to>", "", ""]).joined(separator: "\n")
  }
}

extension ThreadsFile {
  fileprivate func surfaceID(containing messageID: MailMessage.ID) -> UUID? {
    boxes.first { $0.messages.contains { $0.id == messageID } }?.surfaceID
  }

  fileprivate func message(_ messageID: MailMessage.ID) -> MailMessage? {
    boxes.lazy.compactMap { $0.messages.first { $0.id == messageID } }.first
  }

  fileprivate mutating func update(_ messageID: MailMessage.ID, _ change: (inout MailMessage) -> Void) {
    guard let surfaceID = surfaceID(containing: messageID),
      let index = boxes[id: surfaceID]?.messages.firstIndex(where: { $0.id == messageID })
    else { return }
    change(&boxes[id: surfaceID]!.messages[index])
  }

  fileprivate mutating func remove(_ messageID: MailMessage.ID) {
    guard let surfaceID = surfaceID(containing: messageID) else { return }
    boxes[id: surfaceID]?.messages.removeAll { $0.id == messageID }
  }
}
