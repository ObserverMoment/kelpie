import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct FleetViewStructureTests {
  // MARK: - Fixtures.

  private struct Fixture {
    struct AddedRow {
      let row: SidebarItemID
      let surface: UUID
      let tab: TabID
    }

    var items: IdentifiedArrayOf<SidebarItemFeature.State> = []
    var repositories: IdentifiedArrayOf<Repository> = []
    var presence = AgentPresenceFeature.State()
    var layouts: IdentifiedArrayOf<LayoutFeature.State> = []
    var groupIDByRepositoryID: [Repository.ID: RepositoryGroupID] = [:]

    /// Adds a row with one surface hosted by one tab.
    @discardableResult
    mutating func addRow(
      repository: Repository.ID, worktree: String, kind: SidebarItemFeature.State.Kind = .gitWorktree,
      agents: [SkillAgent] = [.claude], inLayout: Bool = true
    ) -> AddedRow {
      let rowID = SidebarItemID("\(repository.rawValue)/\(worktree)")
      let surfaceID = UUID()
      let tabID = TabID()
      var row = SidebarItemFeature.State(
        id: rowID, repositoryID: repository, kind: kind, name: worktree, branchName: worktree,
        subtitle: nil, workingDirectory: URL(fileURLWithPath: rowID.rawValue), repositoryAccent: nil,
        isMainWorktree: false, isPinned: false, hasMergedBadge: false)
      row.surfaceIDs = [surfaceID]
      items.append(row)
      if repositories[id: repository] == nil {
        let root = URL(fileURLWithPath: repository.rawValue)
        repositories.append(
          Repository(id: repository, rootURL: root, name: root.lastPathComponent, worktrees: []))
      }
      for agent in agents {
        presence.records[.init(agent: agent, surfaceID: surfaceID)] = .init(pids: [])
      }
      if inLayout {
        let paneID = PaneID()
        let layout = PaneLayout(
          tree: SplitTree(view: paneID),
          panes: [
            Pane(
              id: paneID,
              tabs: [
                TabItem(
                  id: tabID, title: worktree,
                  content: ContentSnapshot(
                    id: ContentID(rawValue: surfaceID),
                    state: .terminal(TerminalContentState(workingDirectory: nil))))
              ])
          ])
        layouts.append(LayoutFeature.State(id: rowID, layout: layout))
      }
      return AddedRow(row: rowID, surface: surfaceID, tab: tabID)
    }

    func compute(_ sections: [SidebarStructure.Section], hoisted: Set<SidebarItemID> = []) -> FleetViewStructure {
      var structure = SidebarStructure.empty
      structure.sections = sections
      structure.hoistedRowIDs = hoisted
      return FleetViewStructure.compute(
        .init(
          sidebarStructure: structure, groupIDByRepositoryID: groupIDByRepositoryID, sidebarItems: items,
          repositories: repositories, presence: presence, layouts: layouts))
    }
  }

  private func repositorySection(_ id: Repository.ID, rows: [SidebarItemID]) -> SidebarStructure.Section {
    .repository(
      repositoryID: id,
      groups: [SidebarItemGroup(slot: .main(isSole: false), repositoryID: id, rowIDs: rows)])
  }

  private func groupSection(
    _ name: String, collapsed: Bool = false, members: [SidebarStructure.Section]
  ) -> SidebarStructure.Section {
    .repositoryGroup(groupID: groupID, name: name, collapsed: collapsed, members: members)
  }

  private let repoA: Repository.ID = "/tmp/repo-a"
  private let repoB: Repository.ID = "/tmp/repo-b"
  private let groupID = RepositoryGroupID("g1")

  // MARK: - Grouping and order.

  @Test func groupsComeFirstThenUngroupedWithTitle() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "main")
    let rowB = fixture.addRow(repository: repoB, worktree: "main")
    let structure = fixture.compute([
      groupSection("Clients", members: [repositorySection(repoB, rows: [rowB.row])]),
      repositorySection(repoA, rows: [rowA.row]),
    ])

    #expect(structure.sections.map(\.id) == [.group(groupID), .ungrouped])
    #expect(structure.sections[0].title == "Clients")
    #expect(structure.sections[0].cards.map(\.surfaceID) == [rowB.surface])
    #expect(structure.sections[1].title == FleetViewStructure.ungroupedTitle)
    #expect(structure.sections[1].cards.map(\.surfaceID) == [rowA.surface])
    #expect(structure.launcherRows.map(\.id) == [rowB.row, rowA.row])
  }

  @Test func collapsedGroupsStillShowTheirCards() {
    var fixture = Fixture()
    let rowB = fixture.addRow(repository: repoB, worktree: "main")
    let structure = fixture.compute([
      groupSection("Clients", collapsed: true, members: [repositorySection(repoB, rows: [rowB.row])])
    ])

    #expect(structure.sections.map(\.id) == [.group(groupID)])
    #expect(structure.sections[0].cards.map(\.surfaceID) == [rowB.surface])
    #expect(structure.launcherRows.map(\.id) == [rowB.row])
  }

  @Test func ungroupedSectionHasNoTitleWithoutGroups() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "main")
    let structure = fixture.compute([repositorySection(repoA, rows: [rowA.row])])

    #expect(structure.sections.count == 1)
    #expect(structure.sections[0].title == nil)
    #expect(structure.sections[0].cards.first?.tab.id == rowA.tab)
  }

  @Test func emptySectionsAreOmittedAndHighlightsIgnored() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "main", agents: [])
    let structure = fixture.compute([
      .highlight(kind: .active, rowIDs: [rowA.row]),
      groupSection("Empty", members: [repositorySection(repoB, rows: [])]),
      repositorySection(repoA, rows: [rowA.row]),
      .placeholder,
    ])

    #expect(structure.isEmpty)
    #expect(structure.launcherRows.map(\.id) == [rowA.row])
  }

  @Test func hoistedRowsFollowListedRowsInSidebarItemOrder() {
    var fixture = Fixture()
    let hoistedFirst = fixture.addRow(repository: repoA, worktree: "zeta")
    let listed = fixture.addRow(repository: repoA, worktree: "main")
    let hoistedSecond = fixture.addRow(repository: repoA, worktree: "alpha")
    let structure = fixture.compute(
      [
        .highlight(kind: .pinned, rowIDs: [hoistedFirst.row, hoistedSecond.row]),
        repositorySection(repoA, rows: [listed.row]),
      ],
      hoisted: [hoistedFirst.row, hoistedSecond.row])

    #expect(structure.allCards.map(\.surfaceID) == [listed.surface, hoistedFirst.surface, hoistedSecond.surface])
  }

  @Test func rowsNeitherListedNorHoistedAreLeftOut() {
    // Archived worktrees stay in `sidebarItems` but the sidebar shows them nowhere.
    var fixture = Fixture()
    let archived = fixture.addRow(repository: repoA, worktree: "archived")
    let listed = fixture.addRow(repository: repoA, worktree: "main")
    let structure = fixture.compute([repositorySection(repoA, rows: [listed.row])])

    #expect(structure.allCards.map(\.surfaceID) == [listed.surface])
    #expect(structure.launcherRows.map(\.id) == [listed.row])
    #expect(!structure.launcherRows.contains { $0.id == archived.row })
  }

  @Test func hoistedFolderWithoutASectionLandsInItsGroupOrUngrouped() {
    var fixture = Fixture()
    let folderInGroup = fixture.addRow(repository: repoB, worktree: "docs", kind: .folder)
    let folderUngrouped = fixture.addRow(repository: "/tmp/notes", worktree: "notes", kind: .folder)
    let rowA = fixture.addRow(repository: repoA, worktree: "main")
    fixture.groupIDByRepositoryID = [repoB: groupID]
    let structure = fixture.compute(
      [
        .highlight(kind: .pinned, rowIDs: [folderInGroup.row, folderUngrouped.row]),
        groupSection("Clients", members: []),
        repositorySection(repoA, rows: [rowA.row]),
      ],
      hoisted: [folderInGroup.row, folderUngrouped.row])

    #expect(structure.sections.map(\.id) == [.group(groupID), .ungrouped])
    #expect(structure.sections[0].cards.map(\.surfaceID) == [folderInGroup.surface])
    #expect(structure.sections[1].cards.map(\.surfaceID) == [rowA.surface, folderUngrouped.surface])
    #expect(structure.launcherRows.map(\.id) == [folderInGroup.row, rowA.row, folderUngrouped.row])
  }

  // MARK: - Cards.

  @Test func twoAgentsOnOneSurfaceMakeTwoCards() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "main", agents: [.pi, .claude])
    let structure = fixture.compute([repositorySection(repoA, rows: [rowA.row])])

    #expect(structure.allCards.map(\.agent) == [.claude, .pi])
  }

  @Test func surfaceWithoutTabYieldsNoCard() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "main", inLayout: false)
    let structure = fixture.compute([repositorySection(repoA, rows: [rowA.row])])

    #expect(structure.isEmpty)
  }

  @Test func cardCarriesPresenceAndNewestNotification() {
    var fixture = Fixture()
    let rowA = fixture.addRow(repository: repoA, worktree: "feature")
    let key = AgentPresenceFeature.PresenceKey(agent: .claude, surfaceID: rowA.surface)
    fixture.presence.records[key] = .init(activity: .busy, pids: [], model: "claude-fable-5-1", effort: "high")
    fixture.items[id: rowA.row]?.notifications = [
      .init(surfaceID: rowA.surface, title: "Old", body: "older", createdAt: Date(timeIntervalSince1970: 1)),
      .init(surfaceID: rowA.surface, title: "New", body: "newest", createdAt: Date(timeIntervalSince1970: 2)),
      .init(surfaceID: UUID(), title: "Other", body: "other surface", createdAt: Date(timeIntervalSince1970: 3)),
    ]
    let structure = fixture.compute([repositorySection(repoA, rows: [rowA.row])])
    let card = structure.allCards[0]

    #expect(card.activity == .busy)
    #expect(card.model == "claude-fable-5-1")
    #expect(card.effort == "high")
    #expect(card.lastMessage == "newest")
    #expect(card.repositoryName == "repo-a")
    #expect(card.branchName == "feature")
    #expect(card.isFolder == false)
    #expect(card.tab.title == "feature")
    #expect(card.tab.customTitle == nil)
    #expect(structure.card(id: card.id) == card)
  }

  @Test func folderRowsAreMarked() {
    var fixture = Fixture()
    let folderRow = fixture.addRow(repository: repoB, worktree: "folder", kind: .folder)
    let structure = fixture.compute([.folder(repositoryID: repoB, rowID: folderRow.row)])

    #expect(structure.allCards.first?.isFolder == true)
    #expect(structure.launcherRows.first?.repositoryName == "repo-b")
  }
}
