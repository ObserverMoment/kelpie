import Foundation
import IdentifiedCollections
import KelpieSettingsShared

/// The Mailbox view's session list, derived in `AppFeature`'s post-reduce step
/// (same precedent as `FleetViewStructure`): one row per inbox, resolved against
/// the sidebar rows, layouts and agent presence.
struct MailboxStructure: Equatable, Sendable {
  struct Row: Identifiable, Equatable, Sendable {
    /// The surface id.
    let id: UUID
    let worktreeID: Worktree.ID
    /// The hosting tab, so the row resolves its title exactly as the strip does.
    /// `nil` once the pane is gone.
    let tab: TabItem?
    let worktreeName: String
    let repositoryName: String
    let agent: SkillAgent
    let unreadCount: Int
    let messageCount: Int
    /// No live agent presence on the surface: the session ended without Kelpie
    /// seeing it, or the pane is gone.
    let isStale: Bool
  }

  var rows: [Row] = []

  static let empty = MailboxStructure()

  struct Inputs {
    let boxes: IdentifiedArrayOf<Mailbox>
    let sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
    let repositories: IdentifiedArrayOf<Repository>
    let presence: AgentPresenceFeature.State
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
  }

  static func compute(_ inputs: Inputs) -> MailboxStructure {
    let rows = inputs.boxes.map { box -> Row in
      let row = inputs.sidebarItems[id: box.worktreeID]
      let tab = inputs.layouts[id: box.worktreeID]?.layout
        .tab(containingContent: ContentID(rawValue: box.surfaceID))?.tab
      let isLive = inputs.presence.bySurface[box.surfaceID]?.isEmpty == false
      return Row(
        id: box.surfaceID,
        worktreeID: box.worktreeID,
        tab: tab,
        worktreeName: row?.name ?? "",
        repositoryName: row.flatMap { inputs.repositories[id: $0.repositoryID]?.name } ?? "",
        agent: box.agent,
        unreadCount: box.unreadCount,
        messageCount: box.messages.count,
        isStale: !isLive)
    }
    .sorted { lhs, rhs in
      if lhs.isStale != rhs.isStale { return !lhs.isStale }
      if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
      return (lhs.worktreeName, lhs.id.uuidString) < (rhs.worktreeName, rhs.id.uuidString)
    }
    return MailboxStructure(rows: rows)
  }
}
