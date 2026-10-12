import Foundation
import IdentifiedCollections
import KelpieSettingsShared
import Sharing

/// One message an agent ended a turn with. Held until the user ticks it or
/// replies to it; `isRead` only flips when the message is opened.
nonisolated struct MailMessage: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  let body: String
  let createdAt: Date
  var isRead = false
  /// A reply quoting this message is staged in the pane's terminal. The next
  /// prompt submit from that pane marks the message done.
  var isReplying = false
}

/// The inbox of one pane, keyed by its surface. Lives as long as the agent
/// session: cleared on `SessionEnd` or when the pane closes. A box whose
/// surface has no live agent presence is stale and closable by hand.
nonisolated struct Mailbox: Identifiable, Equatable, Codable, Sendable {
  var id: UUID { surfaceID }
  let surfaceID: UUID
  let worktreeID: Worktree.ID
  let agent: SkillAgent
  /// Newest first.
  var messages: [MailMessage] = []

  var unreadCount: Int { messages.count { !$0.isRead } }
  var latestBody: String? { messages.first?.body }
}

/// Everything the Mailbox persists, so inboxes survive an app relaunch.
nonisolated struct MailboxesFile: Equatable, Codable, Sendable {
  var boxes: IdentifiedArrayOf<Mailbox> = []

  var unreadCount: Int { boxes.reduce(0) { $0 + $1.unreadCount } }

  /// The surface's inbox holds at least one message, read or not.
  func hasMail(for surfaceID: UUID) -> Bool {
    boxes[id: surfaceID]?.messages.isEmpty == false
  }

  func newestMessageID(for surfaceID: UUID) -> MailMessage.ID? {
    boxes[id: surfaceID]?.messages.first?.id
  }

  /// Latest message per surface, for the Fleet card excerpt.
  var latestBodyBySurface: [UUID: String] {
    boxes.reduce(into: [:]) { $0[$1.surfaceID] = $1.latestBody }
  }
}

extension SharedReaderKey where Self == FileStorageKey<MailboxesFile>.Default {
  static var mailboxes: Self {
    Self[.fileStorage(KelpiePaths.mailboxesURL), default: MailboxesFile()]
  }
}
