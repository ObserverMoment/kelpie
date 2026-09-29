import Foundation
import IdentifiedCollections
import KelpieSettingsShared

/// One Fleet View card: a single agent on a single terminal surface.
struct FleetCardID: Hashable, Sendable {
  let surfaceID: UUID
  let agent: SkillAgent
}

/// The card grid Fleet View renders plus the launcher's worktree list, derived
/// from the sidebar structure (order and grouping), the per-row sidebar state,
/// agent presence and the layouts. Pure and cached on `FleetViewFeature.State`,
/// so the view observes one value.
struct FleetViewStructure: Equatable, Sendable {
  struct Card: Identifiable, Equatable, Sendable {
    let id: FleetCardID
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
    /// The hosting tab, so the card opens it and resolves its title exactly as
    /// the strip does (`TabTitle.resolved`).
    let tab: TabItem
    let activity: AgentPresenceFeature.Activity
    let repositoryName: String
    let worktreeName: String
    let branchName: String
    let workingDirectoryPath: String
    let isFolder: Bool
    let model: String?
    let effort: String?
    let lastMessage: String?
    /// The agent pod the session belongs to, if any.
    var podName: String?

    var agent: SkillAgent { id.agent }
    var surfaceID: UUID { id.surfaceID }
  }

  enum SectionID: Hashable, Sendable {
    case group(RepositoryGroupID)
    case ungrouped
  }

  struct Section: Identifiable, Equatable, Sendable {
    let id: SectionID
    /// nil when there is nothing to distinguish the section from (no groups exist).
    let title: String?
    let cards: [Card]
  }

  /// One launcher choice: a sidebar row in sidebar order.
  struct LauncherRow: Identifiable, Equatable, Sendable {
    let id: SidebarItemID
    let name: String
    let repositoryName: String
  }

  var sections: [Section]
  var launcherRows: [LauncherRow]

  static let empty = FleetViewStructure(sections: [], launcherRows: [])

  static let ungroupedTitle = "Ungrouped"

  var isEmpty: Bool { sections.isEmpty }

  var sectionCardIDs: [[FleetCardID]] { sections.map { $0.cards.map(\.id) } }

  var allCards: [Card] { sections.flatMap(\.cards) }

  func card(id: FleetCardID) -> Card? {
    allCards.first { $0.id == id }
  }

  /// Sections follow the sidebar: every user group in order (titled with the
  /// group name), then one section for everything ungrouped. Rows hoisted into
  /// the sidebar's Pinned/Active sections sit under their own repository after
  /// its listed rows, in `sidebarItems` order; a hoisted folder (which has no
  /// section of its own) lands in its group or at the end of the ungrouped run.
  /// Rows the sidebar does not show (archived worktrees) do not appear. A
  /// surface with no tab in the worktree's layout yields no card, so every card
  /// can be opened. Sections with no cards are omitted.
  /// Everything `compute` reads, all of it reducer state.
  struct Inputs {
    let sidebarStructure: SidebarStructure
    let groupIDByRepositoryID: [Repository.ID: RepositoryGroupID]
    let sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
    let repositories: IdentifiedArrayOf<Repository>
    let presence: AgentPresenceFeature.State
    let layouts: IdentifiedArrayOf<LayoutFeature.State>
    var podNameBySurface: [UUID: String] = [:]
  }

  static func compute(_ inputs: Inputs) -> FleetViewStructure {
    let sidebarItems = inputs.sidebarItems
    let repositories = inputs.repositories
    let placement = RowPlacement.resolve(
      sidebarStructure: inputs.sidebarStructure,
      groupIDByRepositoryID: inputs.groupIDByRepositoryID,
      sidebarItems: sidebarItems)
    let builder = CardBuilder(
      sidebarItems: sidebarItems, repositories: repositories, presence: inputs.presence, layouts: inputs.layouts,
      podNameBySurface: inputs.podNameBySurface)
    let groupSections = placement.groups.compactMap { group -> Section? in
      let cards = group.repositories.flatMap { builder.cards(forRows: $0.rowIDs) }
      return cards.isEmpty ? nil : Section(id: .group(group.id), title: group.name, cards: cards)
    }
    let ungroupedCards = placement.ungrouped.flatMap { builder.cards(forRows: $0.rowIDs) }
    let ungroupedTitle = placement.groups.isEmpty ? nil : Self.ungroupedTitle
    let ungroupedSection =
      ungroupedCards.isEmpty ? nil : Section(id: .ungrouped, title: ungroupedTitle, cards: ungroupedCards)
    let launcherRows = placement.orderedRowIDs
      .compactMap { sidebarItems[id: $0] }
      .map { row in
        LauncherRow(
          id: row.id,
          name: row.name,
          repositoryName: repositories[id: row.repositoryID]?.name ?? row.name)
      }
    return FleetViewStructure(
      sections: groupSections + [ungroupedSection].compactMap { $0 },
      launcherRows: launcherRows)
  }
}

/// Which rows sit under which repository and group, in sidebar order. Listed
/// rows come from the rendered sections; hoisted rows attach to their own
/// repository, creating an entry for a repository the sections do not show.
private struct RowPlacement {
  struct RepositoryRows {
    let repositoryID: Repository.ID
    var rowIDs: [SidebarItemID]
  }

  struct GroupRows {
    let id: RepositoryGroupID
    let name: String
    var repositories: [RepositoryRows]
  }

  var groups: [GroupRows]
  var ungrouped: [RepositoryRows]

  var orderedRowIDs: [SidebarItemID] {
    (groups.flatMap(\.repositories) + ungrouped).flatMap(\.rowIDs)
  }

  static func resolve(
    sidebarStructure: SidebarStructure,
    groupIDByRepositoryID: [Repository.ID: RepositoryGroupID],
    sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
  ) -> RowPlacement {
    let listed = RowPlacement(
      groups: sidebarStructure.sections.compactMap { section in
        guard case .repositoryGroup(let id, let name, _, let members) = section else { return nil }
        return GroupRows(id: id, name: name, repositories: members.compactMap(listedRows))
      },
      ungrouped: sidebarStructure.sections.compactMap(listedRows))
    let hoistedRows = sidebarItems.filter { sidebarStructure.hoistedRowIDs.contains($0.id) }
    return hoistedRows.reduce(into: listed) { placement, row in
      placement.attach(
        rowID: row.id,
        repositoryID: row.repositoryID,
        groupID: groupIDByRepositoryID[row.repositoryID])
    }
  }

  private static func listedRows(_ section: SidebarStructure.Section) -> RepositoryRows? {
    switch section {
    case .repository(let repositoryID, let groups):
      RepositoryRows(repositoryID: repositoryID, rowIDs: groups.flatMap(\.rowIDs))
    case .folder(let repositoryID, let rowID):
      RepositoryRows(repositoryID: repositoryID, rowIDs: [rowID])
    case .repositoryGroup, .highlight, .failedRepository, .environmentBlockedRepository, .placeholder:
      nil
    }
  }

  /// Appends a hoisted row to its repository wherever the sidebar placed that
  /// repository, else to its group, else to the ungrouped run.
  private mutating func attach(rowID: SidebarItemID, repositoryID: Repository.ID, groupID: RepositoryGroupID?) {
    for groupIndex in groups.indices {
      if let index = groups[groupIndex].repositories.firstIndex(where: { $0.repositoryID == repositoryID }) {
        groups[groupIndex].repositories[index].rowIDs.append(rowID)
        return
      }
    }
    if let index = ungrouped.firstIndex(where: { $0.repositoryID == repositoryID }) {
      ungrouped[index].rowIDs.append(rowID)
      return
    }
    let fresh = RepositoryRows(repositoryID: repositoryID, rowIDs: [rowID])
    if let groupID, let groupIndex = groups.firstIndex(where: { $0.id == groupID }) {
      groups[groupIndex].repositories.append(fresh)
    } else {
      ungrouped.append(fresh)
    }
  }
}

/// Builds cards for rows; presence is grouped by surface once so a surface with
/// no agent costs one dictionary miss.
private struct CardBuilder {
  let sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>
  let repositories: IdentifiedArrayOf<Repository>
  let layouts: IdentifiedArrayOf<LayoutFeature.State>
  let recordsBySurface: [UUID: [(agent: SkillAgent, record: AgentPresenceFeature.PresenceRecord)]]
  let podNameBySurface: [UUID: String]

  init(
    sidebarItems: IdentifiedArrayOf<SidebarItemFeature.State>,
    repositories: IdentifiedArrayOf<Repository>,
    presence: AgentPresenceFeature.State,
    layouts: IdentifiedArrayOf<LayoutFeature.State>,
    podNameBySurface: [UUID: String]
  ) {
    self.sidebarItems = sidebarItems
    self.repositories = repositories
    self.layouts = layouts
    self.podNameBySurface = podNameBySurface
    recordsBySurface = presence.records.reduce(into: [:]) { grouped, entry in
      grouped[entry.key.surfaceID, default: []].append((entry.key.agent, entry.value))
    }
  }

  func cards(forRows rowIDs: [SidebarItemID]) -> [FleetViewStructure.Card] {
    rowIDs.compactMap { sidebarItems[id: $0] }.flatMap(cards(for:))
  }

  private func cards(for row: SidebarItemFeature.State) -> [FleetViewStructure.Card] {
    let repositoryName = repositories[id: row.repositoryID]?.name ?? row.name
    let layout = layouts[id: row.id]?.layout
    return row.surfaceIDs.flatMap { surfaceID -> [FleetViewStructure.Card] in
      guard let records = recordsBySurface[surfaceID],
        let tab = layout?.tab(containingContent: ContentID(rawValue: surfaceID))?.tab
      else { return [] }
      let lastMessage = row.notifications
        .filter { $0.surfaceID == surfaceID && !$0.body.isEmpty }
        .max { $0.createdAt < $1.createdAt }?
        .body
      return
        records
        .sorted { $0.agent.rawValue < $1.agent.rawValue }
        .map { agent, record in
          FleetViewStructure.Card(
            id: FleetCardID(surfaceID: surfaceID, agent: agent),
            worktreeID: row.id,
            repositoryID: row.repositoryID,
            tab: tab,
            activity: record.activity,
            repositoryName: repositoryName,
            worktreeName: row.name,
            branchName: row.branchName,
            workingDirectoryPath: row.workingDirectoryPath.isEmpty
              ? row.workingDirectory.path(percentEncoded: false) : row.workingDirectoryPath,
            isFolder: row.kind == .folder,
            model: record.model,
            effort: record.effort,
            lastMessage: lastMessage,
            podName: podNameBySurface[surfaceID])
        }
    }
  }
}
