import Foundation
import IdentifiedCollections
import KelpieSettingsShared

/// The Threads view's tile list, derived in `AppFeature`'s post-reduce step
/// (same precedent as `FleetViewStructure`): one tile per pod and one per
/// session in no pod, resolved against the sidebar rows, layouts, pods and
/// agent presence. A pod tile carries its member tiles, so a podded session
/// has no tile of its own.
struct ThreadsStructure: Equatable, Sendable {
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
    /// The session's rolling summary, if one has been written.
    let summary: String?
    /// The member's name in its pod; `nil` for a session in no pod.
    let memberName: String?
  }

  struct PodRow: Identifiable, Equatable, Sendable {
    let id: PodID
    let name: String
    /// Pod order, every member with a thread.
    let members: [Row]

    var unreadCount: Int { members.reduce(0) { $0 + $1.unreadCount } }
  }

  /// Display order: pods first, then sessions in no pod.
  enum Tile: Identifiable, Equatable, Sendable {
    case pod(PodRow)
    case session(Row)

    var id: ThreadID {
      switch self {
      case .pod(let pod): .pod(pod.id)
      case .session(let row): .session(row.id)
      }
    }
  }

  let tiles: [Tile]
  let pods: [PodRow]
  let sessions: [Row]
  /// Every session row, podded or not, keyed by surface.
  let rowsBySurface: [UUID: Row]

  /// The lookups are built once here, since views and the reducer read them
  /// far more often than the post-reduce pass rebuilds the structure.
  init(tiles: [Tile] = []) {
    self.tiles = tiles
    pods = tiles.compactMap { if case .pod(let pod) = $0 { pod } else { nil } }
    sessions = tiles.compactMap { if case .session(let row) = $0 { row } else { nil } }
    let allRows = pods.flatMap(\.members) + sessions
    rowsBySurface = Dictionary(allRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  static let empty = ThreadsStructure()

  func pod(_ podID: PodID) -> PodRow? {
    pods.first { $0.id == podID }
  }

  func memberIDs(of podID: PodID) -> Set<UUID> {
    Set(pod(podID)?.members.map(\.id) ?? [])
  }

  /// The tile a surface's messages show under: its pod, or its own tile.
  func threadID(containingSurface surfaceID: UUID) -> ThreadID? {
    if let pod = pods.first(where: { $0.members.contains { $0.id == surfaceID } }) { return .pod(pod.id) }
    return sessions.contains { $0.id == surfaceID } ? .session(surfaceID) : nil
  }

  /// The arrow-key order: each pod, then its members while expanded, then
  /// the unpodded sessions. A member is addressed by its own session id.
  func navigationOrder(expandedPods: Set<PodID>) -> [ThreadID] {
    tiles.flatMap { tile -> [ThreadID] in
      switch tile {
      case .pod(let pod):
        let members = expandedPods.contains(pod.id) ? pod.members.map { ThreadID.session($0.id) } : []
        return [.pod(pod.id)] + members
      case .session(let row):
        return [.session(row.id)]
      }
    }
  }

  struct Inputs {
    let file: ThreadsFile
    let pods: IdentifiedArrayOf<Pod>
    let sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
    let repositories: IdentifiedArrayOf<Repository>
    let presence: AgentPresenceFeature.State
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
  }

  static func compute(_ inputs: Inputs) -> ThreadsStructure {
    func row(_ box: MessageThread, memberName: String?) -> Row {
      let item = inputs.sidebarItems[id: box.worktreeID]
      let tab = inputs.layouts[id: box.worktreeID]?.layout
        .tab(containingContent: ContentID(rawValue: box.surfaceID))?.tab
      let isLive = inputs.presence.bySurface[box.surfaceID]?.isEmpty == false
      return Row(
        id: box.surfaceID,
        worktreeID: box.worktreeID,
        tab: tab,
        worktreeName: item?.name ?? "",
        repositoryName: item.flatMap { inputs.repositories[id: $0.repositoryID]?.name } ?? "",
        agent: box.agent,
        unreadCount: box.unreadCount,
        messageCount: box.messages.count,
        isStale: !isLive,
        summary: box.summary,
        memberName: memberName)
    }
    let podRows = inputs.pods.compactMap { pod -> PodRow? in
      let members = pod.members.compactMap { member in
        inputs.file.boxes[id: member.id].map { row($0, memberName: member.name) }
      }
      guard !members.isEmpty else { return nil }
      return PodRow(id: pod.id, name: pod.name, members: members)
    }
    .sorted { lhs, rhs in
      if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
      return (lhs.name, lhs.id.rawValue.uuidString) < (rhs.name, rhs.id.rawValue.uuidString)
    }
    let podded = Set(inputs.pods.flatMap { $0.members.map(\.id) })
    let sessionRows = inputs.file.boxes
      .filter { !podded.contains($0.surfaceID) }
      .map { row($0, memberName: nil) }
      .sorted { lhs, rhs in
        if lhs.isStale != rhs.isStale { return !lhs.isStale }
        if lhs.unreadCount != rhs.unreadCount { return lhs.unreadCount > rhs.unreadCount }
        return (lhs.worktreeName, lhs.id.uuidString) < (rhs.worktreeName, rhs.id.uuidString)
      }
    return ThreadsStructure(tiles: podRows.map(Tile.pod) + sessionRows.map(Tile.session))
  }
}
