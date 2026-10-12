import ComposableArchitecture
import Foundation
import KelpieSettingsShared

/// Per-pane inboxes of the messages agents end their turns with, so a reply
/// that scrolled past can still be read, ticked off or answered. Owns the
/// persisted boxes, the session selection and the open message; `AppFeature`
/// feeds it deliveries and lifecycle events and acts on its reply delegate.
@Reducer
struct MailboxFeature {
  @ObservableState
  struct State: Equatable {
    @Shared(.mailboxes) var file: MailboxesFile
    var structure: MailboxStructure = .empty
    var selectedSurfaceID: UUID?
    /// The message shown full-window, if any.
    var openMessageID: MailMessage.ID?
    /// The message last opened from its pane rather than the inbox. Closing
    /// it leaves the overlay for that pane instead of going back to the inbox.
    var paneOpenedMessageID: MailMessage.ID?
    /// Surfaces whose tab chrome last carried an unread-mail badge, so a box
    /// that empties or closes gets its badge cleared.
    var badgedSurfaceIDs: Set<UUID> = []

    var unreadCount: Int { file.unreadCount }

    var selectedBox: Mailbox? { selectedSurfaceID.flatMap { file.boxes[id: $0] } }

    var selectedRow: MailboxStructure.Row? {
      selectedSurfaceID.flatMap { id in structure.rows.first { $0.id == id } }
    }

    var openMessage: MailMessage? {
      guard let openMessageID else { return nil }
      return selectedBox?.messages.first { $0.id == openMessageID }
    }

    /// Closing the open message goes back to its pane, not the inbox.
    var viewerReturnsToPane: Bool { openMessageID != nil && openMessageID == paneOpenedMessageID }

    /// The overlay left for another session or a launch: a viewer opened from
    /// a pane must not reappear, pointing at that pane, on the next open.
    mutating func dropPaneViewer() {
      guard viewerReturnsToPane else { return }
      openMessageID = nil
      paneOpenedMessageID = nil
    }

    /// Stores a freshly computed structure when it changed and keeps the
    /// selection on a surviving row, falling back to the first.
    mutating func applyStructure(_ next: MailboxStructure) {
      guard next != structure else { return }
      structure = next
      if let selected = selectedSurfaceID, next.rows.contains(where: { $0.id == selected }) { return }
      selectedSurfaceID = next.rows.first?.id
      openMessageID = nil
    }
  }

  enum Action: Equatable {
    case received(surfaceID: UUID, worktreeID: Worktree.ID, agent: SkillAgent, body: String)
    case sessionSelected(UUID?)
    /// Shows the message full-window and marks it read.
    case messageOpened(MailMessage.ID)
    /// Opens a pane's newest message, closing back to that pane. No-op when
    /// the pane has no mail.
    case lastMessageOpened(surfaceID: UUID)
    case viewerClosed
    /// The overlay closed: a viewer opened from a pane closes with it, so the
    /// inbox shows next time.
    case overlayDismissed
    /// The tick: the message leaves the inbox.
    case markDone(MailMessage.ID)
    /// Stages a reply in the pane; the message stays, flagged, until the prompt
    /// is submitted.
    case replyTapped(MailMessage.ID)
    case promptSubmitted(surfaceID: UUID)
    case sessionEnded(surfaceID: UUID)
    case surfacesClosed(Set<UUID>)
    case closeStaleMailbox(UUID)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    /// Open the pane and insert `text` at the prompt, without submitting.
    case reply(worktreeID: Worktree.ID, surfaceID: UUID, text: String)
    /// A viewer opened from a pane closed: leave the overlay for that pane.
    case closedToPane(worktreeID: Worktree.ID, surfaceID: UUID)
  }

  @Dependency(\.uuid) private var uuid
  @Dependency(\.date.now) private var now

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .received(let surfaceID, let worktreeID, let agent, let body):
        let message = MailMessage(id: uuid(), body: body, createdAt: now)
        state.$file.withLock { file in
          if file.boxes[id: surfaceID] == nil {
            file.boxes.append(Mailbox(surfaceID: surfaceID, worktreeID: worktreeID, agent: agent))
          }
          file.boxes[id: surfaceID]?.messages.insert(message, at: 0)
        }
        if state.selectedSurfaceID == nil { state.selectedSurfaceID = surfaceID }
        return .none

      case .sessionSelected(let surfaceID):
        guard surfaceID != state.selectedSurfaceID else { return .none }
        state.selectedSurfaceID = surfaceID
        state.openMessageID = nil
        return .none

      case .messageOpened(let messageID):
        guard let surfaceID = state.file.surfaceID(containing: messageID) else { return .none }
        Self.open(messageID, surfaceID: surfaceID, fromPane: false, state: &state)
        return .none

      case .lastMessageOpened(let surfaceID):
        guard let newest = state.file.boxes[id: surfaceID]?.messages.first else { return .none }
        Self.open(newest.id, surfaceID: surfaceID, fromPane: true, state: &state)
        return .none

      case .viewerClosed:
        return Self.closeViewer(state: &state)

      case .overlayDismissed:
        guard state.viewerReturnsToPane else { return .none }
        return Self.closeViewer(state: &state)

      case .markDone(let messageID):
        let effect = state.openMessageID == messageID ? Self.closeViewer(state: &state) : .none
        state.$file.withLock { $0.remove(messageID) }
        return effect

      case .replyTapped(let messageID):
        guard let surfaceID = state.file.surfaceID(containing: messageID),
          let box = state.file.boxes[id: surfaceID],
          let message = box.messages.first(where: { $0.id == messageID })
        else { return .none }
        state.openMessageID = nil
        state.$file.withLock { file in
          file.update(messageID) {
            $0.isRead = true
            $0.isReplying = true
          }
        }
        return .send(
          .delegate(.reply(worktreeID: box.worktreeID, surfaceID: surfaceID, text: Self.replyQuote(for: message.body))))

      case .promptSubmitted(let surfaceID):
        guard let box = state.file.boxes[id: surfaceID], box.messages.contains(where: \.isReplying) else {
          return .none
        }
        if let open = state.openMessageID, box.messages.contains(where: { $0.id == open && $0.isReplying }) {
          state.openMessageID = nil
        }
        state.$file.withLock { $0.boxes[id: surfaceID]?.messages.removeAll(where: \.isReplying) }
        return .none

      case .sessionEnded(let surfaceID), .closeStaleMailbox(let surfaceID):
        return Self.removeBoxes([surfaceID], state: &state)

      case .surfacesClosed(let surfaceIDs):
        return Self.removeBoxes(surfaceIDs, state: &state)

      case .delegate:
        return .none
      }
    }
  }

  /// Shows a message full-window and marks it read.
  private static func open(
    _ messageID: MailMessage.ID, surfaceID: UUID, fromPane: Bool, state: inout State
  ) {
    state.selectedSurfaceID = surfaceID
    state.openMessageID = messageID
    state.paneOpenedMessageID = fromPane ? messageID : nil
    state.$file.withLock { $0.update(messageID) { $0.isRead = true } }
  }

  /// Back to the inbox, or out of the overlay to the pane the viewer was
  /// opened from.
  private static func closeViewer(state: inout State) -> Effect<Action> {
    let returnsToPane = state.viewerReturnsToPane
    state.openMessageID = nil
    state.paneOpenedMessageID = nil
    guard returnsToPane, let box = state.selectedBox else { return .none }
    return .send(.delegate(.closedToPane(worktreeID: box.worktreeID, surfaceID: box.surfaceID)))
  }

  private static func removeBoxes(_ surfaceIDs: Set<UUID>, state: inout State) -> Effect<Action> {
    guard surfaceIDs.contains(where: { state.file.boxes[id: $0] != nil }) else { return .none }
    state.$file.withLock { file in
      for id in surfaceIDs { file.boxes.remove(id: id) }
    }
    if let selected = state.selectedSurfaceID, surfaceIDs.contains(selected) {
      state.selectedSurfaceID = state.file.boxes.first?.id
      state.openMessageID = nil
    }
    return .none
  }

  /// Line cap on each quoted line, so a one-paragraph message quotes as a line,
  /// not the whole paragraph.
  static let quotedLineCharacterCap = 160

  /// What the reply inserts at the prompt: the first and last lines of the
  /// message, enough for the agent to place it, then a blank line for the
  /// cursor. Newlines travel inside a bracketed paste, so nothing submits.
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

extension MailboxesFile {
  fileprivate func surfaceID(containing messageID: MailMessage.ID) -> UUID? {
    boxes.first { $0.messages.contains { $0.id == messageID } }?.surfaceID
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
