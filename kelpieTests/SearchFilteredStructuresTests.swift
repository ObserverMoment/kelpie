import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

/// The pure `filtered` projections the ⌘F fields drive.
struct SearchFilteredStructuresTests {
  private static let worktree = Worktree.ID("/tmp/search/a")

  private static func tab(_ surfaceID: UUID, title: String = "Tab") -> TabItem {
    TabItem(
      id: TabID(), title: title,
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID), state: .terminal(TerminalContentState(workingDirectory: nil))))
  }

  private static func card(
    _ surfaceID: UUID = UUID(), repository: String = "kelpie", worktree: String = "a", branch: String = "main",
    title: String = "Tab", pod: String? = nil, agent: SkillAgent = .claude
  ) -> FleetViewStructure.Card {
    FleetViewStructure.Card(
      id: FleetCardID(surfaceID: surfaceID, agent: agent), worktreeID: Self.worktree, repositoryID: "/tmp/search",
      tab: tab(surfaceID, title: title), activity: .idle, repositoryName: repository, worktreeName: worktree,
      branchName: branch, workingDirectoryPath: "/tmp/search/a", isFolder: false, model: nil, effort: nil,
      lastMessage: nil, podName: pod)
  }

  // MARK: - Fleet

  @Test func fleetFilterKeepsMatchingCardsAndDropsEmptiedSections() {
    let kelpie = Self.card(branch: "feature/search")
    let other = Self.card(repository: "zig", branch: "main")
    let structure = FleetViewStructure(
      sections: [
        .init(id: .ungrouped, title: nil, cards: [kelpie, other]),
        .init(id: .group(RepositoryGroupID("g")), title: "G", cards: [other]),
      ],
      launcherRows: [.init(id: Self.worktree, name: "a", repositoryName: "kelpie")])

    let filtered = structure.filtered(query: "SEARCH")
    #expect(filtered.sections.map(\.id) == [.ungrouped])
    #expect(filtered.allCards.map(\.id) == [kelpie.id])
    #expect(filtered.launcherRows == structure.launcherRows)
    #expect(structure.filtered(query: nil) == structure)
    #expect(structure.filtered(query: "nothing").isEmpty)
  }

  @Test func fleetCardMatchesEveryNamedField() {
    let card = Self.card(repository: "repo", worktree: "wt", branch: "br", title: "title", pod: "Crew", agent: .codex)
    for query in ["repo", "wt", "br", "title", "crew", SkillAgent.codex.displayName] {
      #expect(card.matches(query), "\(query)")
    }
    #expect(!card.matches("claude"))
  }

  // MARK: - Pods

  private static func member(_ id: UUID, name: String, session: String? = nil, worktree: String? = nil)
    -> PodStructure.MemberCard
  {
    PodStructure.MemberCard(
      id: id, worktreeID: Self.worktree, name: name, description: "",
      registration: session.map { .registered(sessionName: $0) } ?? .pending, activity: nil, worktreeName: worktree)
  }

  @Test func podFilterKeepsWholePodOnNameElseMatchingMembers() {
    let alpha = Self.member(UUID(), name: "Alpha", session: "alpha-1")
    let beta = Self.member(UUID(), name: "Beta", worktree: "feature/search")
    let crew = PodStructure.PodCard(id: PodID(rawValue: UUID()), name: "Crew", description: "", members: [alpha, beta])
    let solo = PodStructure.PodCard(id: PodID(rawValue: UUID()), name: "Solo", description: "", members: [alpha])
    let structure = PodStructure(pods: [crew, solo], candidates: [])

    #expect(structure.filtered(query: "crew").pods == [crew])
    #expect(structure.filtered(query: "beta").pods.map { $0.members.map(\.id) } == [[beta.id]])
    #expect(structure.filtered(query: "alpha-1").pods.map(\.id) == [crew.id, solo.id])
    #expect(structure.filtered(query: "search").pods.map { $0.members.map(\.id) } == [[beta.id]])
    #expect(structure.filtered(query: "zig").pods.isEmpty)
    #expect(structure.filtered(query: nil) == structure)
  }

  // MARK: - Threads

  private static func row(
    _ id: UUID = UUID(), worktree: String = "wt", repository: String = "kelpie", member: String? = nil,
    summary: String? = nil, branch: String = "main", title: String? = nil
  ) -> ThreadsStructure.Row {
    ThreadsStructure.Row(
      id: id, worktreeID: Self.worktree, tab: title.map { tab(id, title: $0) }, worktreeName: worktree,
      repositoryName: repository, agent: .claude, unreadCount: 0, messageCount: 1, isStale: false, summary: summary,
      memberName: member, branchName: branch)
  }

  @Test func threadsFilterMatchesTilesOnNamesBranchAndSummary() {
    let podID = PodID(rawValue: UUID())
    let alpha = Self.row(member: "Alpha", summary: "Fixing the search filter")
    let beta = Self.row(member: "Beta", branch: "feature/zig")
    let loner = Self.row(repository: "other", summary: "Idle", title: "vim")
    let structure = ThreadsStructure(
      tiles: [.pod(.init(id: podID, name: "Crew", members: [alpha, beta])), .session(loner)])

    #expect(structure.filtered(query: "crew").tiles.map(\.id) == [.pod(podID)])
    #expect(structure.filtered(query: "crew").pod(podID)?.members.count == 2)
    #expect(structure.filtered(query: "filter").pod(podID)?.members.map(\.id) == [alpha.id])
    #expect(structure.filtered(query: "feature/zig").pod(podID)?.members.map(\.id) == [beta.id])
    #expect(structure.filtered(query: "other").tiles.map(\.id) == [.session(loner.id)])
    #expect(structure.filtered(query: "vim").tiles.map(\.id) == [.session(loner.id)])
    #expect(structure.filtered(query: "idle").sessions.map(\.id) == [loner.id])
    #expect(structure.filtered(query: "nope").tiles.isEmpty)
    #expect(structure.filtered(query: nil) == structure)
  }

  // MARK: - Sidebar

  @Test func sidebarFilterPrunesRowsKeepsMatchingReposAndOpensMatchedGroups() {
    let repoA = Repository.ID("/tmp/a")
    let repoB = Repository.ID("/tmp/b")
    let rowA1 = Worktree.ID("/tmp/a/one")
    let rowA2 = Worktree.ID("/tmp/a/two")
    let rowB1 = Worktree.ID("/tmp/b/one")
    let groupID = RepositoryGroupID("g")
    let repoSectionA = SidebarStructure.Section.repository(
      repositoryID: repoA, groups: [.init(slot: .unpinnedTail, repositoryID: repoA, rowIDs: [rowA1, rowA2])])
    let repoSectionB = SidebarStructure.Section.repository(
      repositoryID: repoB, groups: [.init(slot: .main(isSole: true), repositoryID: repoB, rowIDs: [rowB1])])
    let group = SidebarStructure.Section.repositoryGroup(
      groupID: groupID, name: "Work", collapsed: true, members: [repoSectionB])
    let highlight = SidebarStructure.Section.highlight(kind: .pinned, rowIDs: [rowA1, rowB1])
    let structure = SidebarStructure(
      sections: [highlight, group, repoSectionA], hoistedRowIDs: [rowA1, rowB1], hotkeySlots: [], slotByID: [rowA1: 0],
      repositoryHighlightByID: [:], hoistSummaryByRepositoryID: [:], reorderableRepositoryIDs: [repoA],
      leadingSections: [highlight], groupBlockSections: [group], ungroupedSections: [repoSectionA])

    // Only row rowA2 matches: the highlight empties, the group drops, repo A keeps one row.
    let rows = structure.filtered(
      rowMatches: { $0 == rowA2 }, repositoryMatches: { _ in false }, textMatches: { _ in false })
    #expect(rows.leadingSections.isEmpty)
    #expect(rows.groupBlockSections.isEmpty)
    #expect(
      rows.ungroupedSections == [
        .repository(repositoryID: repoA, groups: [.init(slot: .unpinnedTail, repositoryID: repoA, rowIDs: [rowA2])])
      ])
    #expect(rows.sections == rows.ungroupedSections)
    #expect(rows.slotByID == structure.slotByID)

    // Repo B matches by name: its whole section stays and the collapsed group opens.
    let repo = structure.filtered(
      rowMatches: { _ in false }, repositoryMatches: { $0 == repoB }, textMatches: { _ in false })
    #expect(
      repo.groupBlockSections == [
        .repositoryGroup(groupID: groupID, name: "Work", collapsed: false, members: [repoSectionB])
      ])
    #expect(repo.ungroupedSections.isEmpty)

    // The group name matches: the group is kept verbatim, still collapsed.
    let named = structure.filtered(
      rowMatches: { _ in false }, repositoryMatches: { _ in false }, textMatches: { $0 == "Work" })
    #expect(named.groupBlockSections == [group])
  }
}
