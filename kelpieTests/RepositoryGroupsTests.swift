import ComposableArchitecture
import Foundation
import IdentifiedCollections
import OrderedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

/// User-defined sidebar groups: the `SidebarState` model, how
/// `computeSidebarStructure` nests them as group sections above the
/// ungrouped repositories, and the reducer arms.
@MainActor
struct RepositoryGroupsTests {
  private let repoA: Repository.ID = "/tmp/repo-a"
  private let repoB: Repository.ID = "/tmp/repo-b"
  private let repoC: Repository.ID = "/tmp/repo-c"
  private let groupID = RepositoryGroupID("g1")
  private let otherGroupID = RepositoryGroupID("g2")

  private func makeSidebar(_ ids: [Repository.ID]) -> SidebarState {
    var sidebar = SidebarState()
    for id in ids { sidebar.sections[id] = .init() }
    return sidebar
  }

  private func makeRepository(_ id: Repository.ID) -> Repository {
    let root = URL(fileURLWithPath: id.rawValue)
    let main = Worktree(
      id: WorktreeID(root.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(id: id, rootURL: root, name: root.lastPathComponent, worktrees: [main])
  }

  private func memberIDs(
    of structure: SidebarStructure, _ groupID: RepositoryGroupID
  ) -> [SidebarStructure.Section.SectionID] {
    structure.memberSections(of: groupID).map(\.id)
  }

  private func makeState(_ ids: [Repository.ID]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State(reconciledRepositories: ids.map(makeRepository))
    state.isInitialLoadComplete = true
    state.reconcileSidebarForTesting()
    return state
  }

  // MARK: - SidebarState

  @Test func addRenameRemoveGroup() {
    var sidebar = SidebarState()
    sidebar.addGroup(id: groupID, name: "Work")
    sidebar.addGroup(id: groupID, name: "Duplicate")
    #expect(sidebar.groups[groupID]?.name == "Work")

    sidebar.renameGroup(groupID, to: "Play")
    #expect(sidebar.groups[groupID]?.name == "Play")

    sidebar.removeGroup(groupID)
    #expect(sidebar.groups.isEmpty)
  }

  @Test func assignGroupReslotsSectionBesideTheBlock() {
    var sidebar = makeSidebar([repoA, repoB, repoC])
    sidebar.addGroup(id: groupID, name: "Work")

    // First member has no block to anchor to, so it keeps its slot.
    sidebar.assignGroup(of: repoA, to: groupID)
    #expect(Array(sidebar.sections.keys) == [repoA, repoB, repoC])

    // Joining lands after the group's last member.
    sidebar.assignGroup(of: repoC, to: groupID)
    #expect(sidebar.groups[groupID]?.repositoryIDs == [repoA, repoC])
    #expect(Array(sidebar.sections.keys) == [repoA, repoC, repoB])

    // Leaving lands after the block.
    sidebar.assignGroup(of: repoA, to: nil)
    #expect(sidebar.groups[groupID]?.repositoryIDs == [repoC])
    #expect(sidebar.groupID(containing: repoA) == nil)
    #expect(Array(sidebar.sections.keys) == [repoC, repoA, repoB])
  }

  @Test func assignGroupMovesBetweenGroupsAndIgnoresUnknownGroup() {
    var sidebar = makeSidebar([repoA, repoB])
    sidebar.addGroup(id: groupID, name: "One")
    sidebar.addGroup(id: otherGroupID, name: "Two")
    sidebar.assignGroup(of: repoA, to: groupID)
    sidebar.assignGroup(of: repoA, to: otherGroupID)
    #expect(sidebar.groups[groupID]?.repositoryIDs.isEmpty == true)
    #expect(sidebar.groups[otherGroupID]?.repositoryIDs == [repoA])

    // An unknown target (stale menu) is a no-op, not a silent ungroup.
    sidebar.assignGroup(of: repoA, to: RepositoryGroupID("missing"))
    #expect(sidebar.groupID(containing: repoA) == otherGroupID)
    sidebar.assignGroup(of: repoB, to: RepositoryGroupID("missing"))
    #expect(sidebar.groupID(containing: repoB) == nil)
  }

  @Test func assignGroupNilRepairsADuplicatedMembership() {
    var sidebar = makeSidebar([repoA])
    sidebar.addGroup(id: groupID, name: "One")
    sidebar.addGroup(id: otherGroupID, name: "Two")
    sidebar.groups[groupID]?.repositoryIDs = [repoA]
    sidebar.groups[otherGroupID]?.repositoryIDs = [repoA]

    sidebar.assignGroup(of: repoA, to: nil)

    #expect(sidebar.groups[groupID]?.repositoryIDs.isEmpty == true)
    #expect(sidebar.groups[otherGroupID]?.repositoryIDs.isEmpty == true)
  }

  @Test func normalizeSectionOrderSeedsMissingMembersAndKeepsUnknownTail() {
    var sidebar = makeSidebar([repoA, "/tmp/loading"])
    sidebar.addGroup(id: groupID, name: "Work")
    sidebar.groups[groupID]?.repositoryIDs = [repoB]

    // B is live but has no section yet; "/tmp/loading" has a section but is
    // not (yet) a known repository.
    sidebar.normalizeSectionOrder(knownIDs: [repoA, repoB], excluding: [])

    #expect(Array(sidebar.sections.keys) == [repoB, repoA, "/tmp/loading"])
  }

  @Test func malformedGroupsEntryDropsGroupsButKeepsSections() throws {
    let json = Data(
      #"{"schemaVersion":1,"sections":["/tmp/repo-a",{"collapsed":true}],"groups":["g1",{"name":"no id"}]}"#.utf8)

    let decoded = try JSONDecoder().decode(SidebarState.self, from: json)

    #expect(decoded.groups.isEmpty)
    #expect(decoded.sections[repoA]?.collapsed == true)
  }

  @Test func groupEntryWithOnlyIDAndNameDecodesDefaults() throws {
    let json = Data(#"{"id":"g1","name":"Work"}"#.utf8)

    let decoded = try JSONDecoder().decode(SidebarState.RepositoryGroup.self, from: json)

    #expect(decoded.collapsed == false)
    #expect(decoded.repositoryIDs.isEmpty)
  }

  @Test func rekeyGroupMembersFollowsARepositoryIDChangeAndDedupesCollisions() {
    var sidebar = SidebarState()
    sidebar.addGroup(id: groupID, name: "Work")
    sidebar.addGroup(id: otherGroupID, name: "Play")
    sidebar.groups[groupID]?.repositoryIDs = [repoA, repoB]
    sidebar.groups[otherGroupID]?.repositoryIDs = [repoC]

    // A and C both become C: the first occurrence (in group order) wins.
    sidebar.rekeyGroupMembers { $0 == repoA ? repoC : $0 }

    #expect(sidebar.groups[groupID]?.repositoryIDs == [repoC, repoB])
    #expect(sidebar.groups[otherGroupID]?.repositoryIDs.isEmpty == true)
  }

  @Test func pruningGroupMembersDropsMissingReposButKeepsGroup() {
    var sidebar = SidebarState()
    sidebar.addGroup(id: groupID, name: "Work")
    sidebar.groups[groupID]?.repositoryIDs = [repoA, repoB]

    let pruned = SidebarState.pruningGroupMembers(of: sidebar.groups, keeping: [repoA])

    #expect(pruned[groupID]?.repositoryIDs == [repoA])
    let emptied = SidebarState.pruningGroupMembers(of: sidebar.groups, keeping: [])
    #expect(emptied[groupID] != nil)
  }

  @Test func codableRoundTripAndLegacyBlobWithoutGroups() throws {
    var original = makeSidebar([repoA])
    original.addGroup(id: groupID, name: "Work")
    original.assignGroup(of: repoA, to: groupID)
    original.groups[groupID]?.collapsed = true

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SidebarState.self, from: data)
    #expect(decoded == original)

    let legacy = Data(#"{"schemaVersion":1,"sections":[]}"#.utf8)
    #expect(try JSONDecoder().decode(SidebarState.self, from: legacy).groups.isEmpty)

    // No groups: the blob is byte-identical to what older builds wrote.
    let untouched = try #require(String(data: JSONEncoder().encode(SidebarState()), encoding: .utf8))
    #expect(!untouched.contains("groups"))
  }

  // MARK: - SidebarStructure

  @Test func groupSectionHoldsMembersAboveUngroupedRepos() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA, repoC]
    }

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(structure.sections.map(\.id) == [.repositoryGroup(groupID), .repository(repoB)])
    #expect(memberIDs(of: structure, groupID) == [.repository(repoA), .repository(repoC)])
    #expect(structure.reorderableRepositoryIDs == [repoA, repoC, repoB])
  }

  @Test func groupsRenderAboveUngroupedReposRegardlessOfKeyOrder() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "One")
      sidebar.addGroup(id: otherGroupID, name: "Two")
      sidebar.groups[groupID]?.repositoryIDs = [repoC]
      sidebar.groups[otherGroupID]?.repositoryIDs = [repoB]
    }

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(
      structure.sections.map(\.id) == [
        .repositoryGroup(groupID), .repositoryGroup(otherGroupID), .repository(repoA),
      ])
    #expect(memberIDs(of: structure, groupID) == [.repository(repoC)])
    #expect(memberIDs(of: structure, otherGroupID) == [.repository(repoB)])
    #expect(structure.orderedGroupIDs == [groupID, otherGroupID])
    #expect(structure.reorderableRepositoryIDs == [repoC, repoB, repoA])
  }

  @Test func collapsedGroupOmitsMembersAndTheirHotkeySlots() {
    var state = makeState([repoA, repoB])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA]
      sidebar.groups[groupID]?.collapsed = true
    }

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(structure.sections.map(\.id) == [.repositoryGroup(groupID), .repository(repoB)])
    let mainA = makeRepository(repoA).worktrees[0].id
    let mainB = makeRepository(repoB).worktrees[0].id
    #expect(structure.slotByID[mainA] == nil)
    #expect(structure.slotByID[mainB] != nil)
  }

  @Test func emptyGroupStillRendersItsHeader() {
    var state = makeState([repoA])
    state.$sidebar.withLock { $0.addGroup(id: groupID, name: "Empty") }

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(structure.sections.map(\.id) == [.repositoryGroup(groupID), .repository(repoA)])
  }

  @Test func sectionRunsSplitLeadingGroupBlockAndUngrouped() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA, repoC]
    }

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(structure.leadingSections.isEmpty)
    #expect(structure.groupBlockSections.map(\.id) == [.repositoryGroup(groupID)])
    #expect(structure.ungroupedSections.map(\.id) == [.repository(repoB)])
  }

  @Test func memberMoveMapsIntoTheGroupSliceOfTheReorderableOrder() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoB, repoC]
    }
    // Reorderable: [B, C, A]; members: [B, C].
    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let toFront = structure.memberMove(in: groupID, offsets: [1], destination: 0)
    #expect(toFront?.offsets == [1])
    #expect(toFront?.destination == 0)
    let pastEnd = structure.memberMove(in: groupID, offsets: [0], destination: 2)
    #expect(pastEnd?.offsets == [0])
    #expect(pastEnd?.destination == 2)
    #expect(structure.memberMove(in: otherGroupID, offsets: [0], destination: 0) == nil)
  }

  @Test func groupedOrderPutsMembersFirstInGroupOrder() {
    var sidebar = makeSidebar([repoA, repoB, repoC])
    sidebar.addGroup(id: groupID, name: "One")
    sidebar.addGroup(id: otherGroupID, name: "Two")
    sidebar.groups[groupID]?.repositoryIDs = [repoC]
    sidebar.groups[otherGroupID]?.repositoryIDs = [repoA, "/tmp/gone"]

    #expect(sidebar.groupedOrder(of: [repoA, repoB, repoC], excluding: []) == [repoC, repoA, repoB])
    // An ungroupable member renders, and orders, as ungrouped.
    #expect(sidebar.groupedOrder(of: [repoA, repoB, repoC], excluding: [repoC]) == [repoA, repoB, repoC])
  }

  @Test func ungroupedMoveMapsIntoTheReorderableOrder() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoB]
    }
    // Reorderable: [B, A, C]; ungrouped run: [A, C].
    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    let up = structure.ungroupedMove(offsets: [1], destination: 0)
    #expect(up?.offsets == [2])
    #expect(up?.destination == 1)
    let toEnd = structure.ungroupedMove(offsets: [0], destination: 2)
    #expect(toEnd?.offsets == [1])
    #expect(toEnd?.destination == 3)
    #expect(structure.ungroupedMove(offsets: [5], destination: 0) == nil)
  }

  @Test func failedMemberFallsBackToTheUngroupedRunInBothIndexSpaces() {
    var state = makeState([repoA, repoB, repoC])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA, repoC]
    }
    state.loadFailuresByID[repoC] = "gone"

    let structure = state.computeSidebarStructure(groupPinned: false, groupActive: false)

    #expect(memberIDs(of: structure, groupID) == [.repository(repoA)])
    #expect(structure.ungroupedSections.map(\.id) == [.repository(repoB), .failedRepository(repoC)])
    #expect(structure.reorderableRepositoryIDs == state.groupedRepositoryOrder())
  }

  // MARK: - Reducer

  @Test func createGroupTrimsNameAndSkipsBlank() async {
    let store = TestStore(initialState: makeState([repoA])) {
      RepositoriesFeature()
    } withDependencies: {
      $0.uuid = .incrementing
    }
    let expectedID = RepositoryGroupID("00000000-0000-0000-0000-000000000000")

    await store.send(.createRepositoryGroup(name: "  Work ")) {
      $0.$sidebar.withLock { $0.addGroup(id: expectedID, name: "Work") }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.createRepositoryGroup(name: "   "))
  }

  @Test func renameRemoveAndExpansionArms() async {
    var initial = makeState([repoA])
    initial.$sidebar.withLock { $0.addGroup(id: groupID, name: "Work") }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }

    await store.send(.renameRepositoryGroup(groupID, name: " Play ")) {
      $0.$sidebar.withLock { $0.renameGroup(groupID, to: "Play") }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.renameRepositoryGroup(groupID, name: ""))
    await store.send(.repositoryGroupExpansionChanged(groupID, isExpanded: false)) {
      $0.$sidebar.withLock { $0.groups[groupID]?.collapsed = true }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.repositoryGroupExpansionChanged(otherGroupID, isExpanded: false))
    await store.send(.removeRepositoryGroup(groupID)) {
      $0.$sidebar.withLock { sidebar in
        sidebar.removeGroup(groupID)
        // Removal re-normalizes the key order, which also seeds the section.
        sidebar.normalizeSectionOrder(knownIDs: [repoA], excluding: [])
      }
      $0.applyPostReduceCacheRecomputes()
    }
    await store.send(.removeRepositoryGroup(groupID))
  }

  @Test func moveRepositoryToGroupViaMenu() async {
    var initial = makeState([repoA, repoB])
    initial.$sidebar.withLock { $0.addGroup(id: groupID, name: "Work") }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.repositoryGroupExpansionChanged(groupID, isExpanded: false))
    await store.send(.moveRepositoryToGroup(repoB, groupID))
    #expect(store.state.sidebar.groups[groupID]?.repositoryIDs == [repoB])
    // Joining reveals the group and pulls the key order into rendered order.
    #expect(store.state.sidebar.groups[groupID]?.collapsed == false)
    #expect(Array(store.state.sidebar.sections.keys) == [repoB, repoA])
    #expect(memberIDs(of: store.state.sidebarStructure, groupID) == [.repository(repoB)])

    await store.send(.moveRepositoryToGroup(repoB, nil))
    #expect(store.state.sidebar.groups[groupID]?.repositoryIDs.isEmpty == true)
    #expect(store.state.sidebarStructure.ungroupedSections.map(\.id) == [.repository(repoB), .repository(repoA)])
  }

  @Test func repositoriesMovedReordersInRenderedOrderWithoutTouchingMembership() async {
    var initial = makeState([repoA, repoB, repoC])
    initial.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoB]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Rendered order is [B, A, C]; move C (index 2) above A (index 1).
    await store.send(.repositoriesMoved([2], 1))
    #expect(Array(store.state.sidebar.sections.keys) == [repoB, repoC, repoA])
    #expect(store.state.sidebar.groups[groupID]?.repositoryIDs == [repoB])
    #expect(
      store.state.sidebarStructure.sections.map(\.id) == [
        .repositoryGroup(groupID), .repository(repoC), .repository(repoA),
      ])
  }

  @Test func repositoryGroupsMovedReordersGroupsAndKeyOrder() async {
    var initial = makeState([repoA, repoB])
    initial.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "One")
      sidebar.addGroup(id: otherGroupID, name: "Two")
      sidebar.groups[groupID]?.repositoryIDs = [repoA]
      sidebar.groups[otherGroupID]?.repositoryIDs = [repoB]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.repositoryGroupsMoved([0], 2))
    #expect(Array(store.state.sidebar.groups.keys) == [otherGroupID, groupID])
    #expect(Array(store.state.sidebar.sections.keys) == [repoB, repoA])
    #expect(store.state.sidebarStructure.orderedGroupIDs == [otherGroupID, groupID])

    await store.send(.repositoryGroupsMoved([5], 0))
    #expect(Array(store.state.sidebar.groups.keys) == [otherGroupID, groupID])
  }

  @Test func setAllSidebarGroupsExpandedCoversUserGroups() async {
    var initial = makeState([repoA])
    initial.$sidebar.withLock { $0.addGroup(id: groupID, name: "Work") }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.setAllSidebarGroupsExpanded(false))
    #expect(store.state.sidebar.groups[groupID]?.collapsed == true)
    await store.send(.setAllSidebarGroupsExpanded(true))
    #expect(store.state.sidebar.groups[groupID]?.collapsed == false)
  }

  @Test func reconcilePrunesMembersWhoseRepositoryIsGoneOnlyAgainstATrustedRoster() {
    var state = makeState([repoA])
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA, "/tmp/gone"]
    }
    let roots = [URL(fileURLWithPath: repoA.rawValue)]

    // First load: the roster may still be hydrating, so membership survives.
    state.reconcileSidebarState(roots: roots, pruneLivenessAgainstRoster: false)
    #expect(state.sidebar.groups[groupID]?.repositoryIDs == [repoA, "/tmp/gone"])

    state.reconcileSidebarState(roots: roots, pruneLivenessAgainstRoster: true)
    #expect(state.sidebar.groups[groupID]?.repositoryIDs == [repoA])
  }

  @Test func reconcilePruningKeepsAPersistedRootThatIsStillLoading() {
    var state = makeState([repoA])
    let rootB = URL(fileURLWithPath: repoB.rawValue)
    state.repositoryRoots.append(rootB)
    state.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA, repoB]
    }

    // B is a persisted root with no loaded repository yet: not gone, just slow.
    state.reconcileSidebarState(
      roots: [URL(fileURLWithPath: repoA.rawValue), rootB], pruneLivenessAgainstRoster: true)

    #expect(state.sidebar.groups[groupID]?.repositoryIDs == [repoA, repoB])
  }

  @Test func repositoriesMovedAcrossRunsKeepsTheKeyOrderGrouped() async {
    var initial = makeState([repoA, repoB, repoC])
    initial.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoB]
    }
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    // Rendered [B(g), A, C]; a sender asks for C above the group's member.
    await store.send(.repositoriesMoved([2], 0))

    #expect(Array(store.state.sidebar.sections.keys) == store.state.groupedRepositoryOrder())
    #expect(Array(store.state.sidebar.sections.keys) == [repoB, repoC, repoA])
  }

  @Test func revealSelectedWorktreeOpensItsCollapsedGroup() async {
    var initial = makeState([repoA])
    let worktreeID = makeRepository(repoA).worktrees[0].id
    initial.$sidebar.withLock { sidebar in
      sidebar.addGroup(id: groupID, name: "Work")
      sidebar.groups[groupID]?.repositoryIDs = [repoA]
      sidebar.groups[groupID]?.collapsed = true
    }
    initial.selection = .worktree(worktreeID)
    let store = TestStore(initialState: initial) {
      RepositoriesFeature()
    }
    store.exhaustivity = .off

    await store.send(.revealSelectedWorktreeInSidebar)

    #expect(store.state.sidebar.groups[groupID]?.collapsed == false)
  }
}
