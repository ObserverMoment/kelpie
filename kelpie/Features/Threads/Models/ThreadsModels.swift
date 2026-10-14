import Foundation
import IdentifiedCollections
import KelpieSettingsShared
import Sharing

/// One message in a thread: what an agent ended a turn with, held until the
/// user ticks it, or a reply the user sent. `isRead` only flips when an
/// agent's message is opened; a reply is read from the start.
nonisolated struct MailMessage: Identifiable, Equatable, Codable, Sendable {
  enum Author: String, Codable, Sendable {
    case agent
    case user
  }

  let id: UUID
  let body: String
  let createdAt: Date
  var isRead = false
  var author: Author = .agent

  init(id: UUID, body: String, createdAt: Date, isRead: Bool = false, author: Author = .agent) {
    self.id = id
    self.body = body
    self.createdAt = createdAt
    self.isRead = isRead
    self.author = author
  }

  private enum CodingKeys: String, CodingKey {
    case id, body, createdAt, isRead, author
  }

  /// Messages written before replies were kept have no `author`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    body = try container.decode(String.self, forKey: .body)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    author = try container.decodeIfPresent(Author.self, forKey: .author) ?? .agent
  }
}

/// One session's thread, keyed by its surface. Lives as long as the agent
/// session: cleared on `SessionEnd` or when the pane closes. A box whose
/// surface has no live agent presence is stale and closable by hand.
nonisolated struct MessageThread: Identifiable, Equatable, Codable, Sendable {
  var id: UUID { surfaceID }
  let surfaceID: UUID
  let worktreeID: Worktree.ID
  let agent: SkillAgent
  /// Newest first.
  var messages: [MailMessage] = []
  /// Rolling summary of the session's messages, rewritten on each delivery.
  var summary: String?

  var unreadCount: Int { messages.count { !$0.isRead } }
  /// The newest message the agent sent, past any reply after it.
  var newestAgentMessage: MailMessage? { messages.first { $0.author == .agent } }
  var latestBody: String? { newestAgentMessage?.body }
}

/// Everything Threads persists, so threads survive an app relaunch.
nonisolated struct ThreadsFile: Equatable, Codable, Sendable {
  var boxes: IdentifiedArrayOf<MessageThread> = []
  /// Rolling summary per pod, keyed by the pod id's `uuidString` so the file
  /// holds a JSON object. A pod thread has no messages of its own, so this is
  /// all it persists.
  var podSummaries: [String: String] = [:]

  init(boxes: IdentifiedArrayOf<MessageThread> = [], podSummaries: [String: String] = [:]) {
    self.boxes = boxes
    self.podSummaries = podSummaries
  }

  private enum CodingKeys: String, CodingKey {
    case boxes, podSummaries
  }

  /// A file written before summaries existed has no `podSummaries` key.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    boxes = try container.decodeIfPresent(IdentifiedArrayOf<MessageThread>.self, forKey: .boxes) ?? []
    podSummaries = try container.decodeIfPresent([String: String].self, forKey: .podSummaries) ?? [:]
  }

  var unreadCount: Int { boxes.reduce(0) { $0 + $1.unreadCount } }

  /// The surface's thread holds an agent message, read or not. The user's own
  /// replies do not count: there is nothing to open or answer in them.
  func hasMail(for surfaceID: UUID) -> Bool {
    boxes[id: surfaceID]?.newestAgentMessage != nil
  }

  /// The surface's newest agent message, the one a reply answers.
  func newestMessageID(for surfaceID: UUID) -> MailMessage.ID? {
    boxes[id: surfaceID]?.newestAgentMessage?.id
  }

  /// Latest message per surface, for the Fleet card excerpt.
  var latestBodyBySurface: [UUID: String] {
    boxes.reduce(into: [:]) { $0[$1.surfaceID] = $1.latestBody }
  }
}

/// What a tile in the Threads list stands for: one session's inbox, or one pod
/// whose members' inboxes show together.
nonisolated enum ThreadID: Hashable, Sendable {
  case session(UUID)
  case pod(PodID)

  var summaryKind: SummaryPrompt.Kind {
    switch self {
    case .session: .session
    case .pod: .pod
    }
  }
}

extension SharedReaderKey where Self == FileStorageKey<ThreadsFile>.Default {
  static var threads: Self {
    Self[.fileStorage(KelpiePaths.mailboxesURL), default: ThreadsFile()]
  }
}
