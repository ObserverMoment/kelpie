import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct PodStructureTests {
  private let worktree = Worktree.ID("/tmp/pods/a")

  private func card(
    _ surfaceID: UUID, agent: SkillAgent = .claude, activity: AgentPresenceFeature.Activity = .idle
  ) -> FleetViewStructure.Card {
    let tab = TabItem(
      id: TabID(), title: "Tab",
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID), state: .terminal(TerminalContentState(workingDirectory: nil))))
    return FleetViewStructure.Card(
      id: FleetCardID(surfaceID: surfaceID, agent: agent), worktreeID: worktree, repositoryID: "/tmp/pods",
      tab: tab, activity: activity, repositoryName: "pods", worktreeName: "a", branchName: "main",
      workingDirectoryPath: "/tmp/pods/a", isFolder: false, model: nil, effort: nil, lastMessage: nil)
  }

  private func pod(_ members: [UUID]) -> Pod {
    Pod(
      id: PodID(rawValue: UUID()), name: "Chat", description: "",
      members: IdentifiedArray(
        uniqueElements: members.map { PodMember(id: $0, worktreeID: worktree, name: "Agent", description: "") }))
  }

  @Test func onlyUnpoddedClaudeSessionsAreEligible() {
    let free = UUID()
    let codex = UUID()
    let podded = UUID()
    let structure = PodStructure.compute(
      pods: [pod([podded])],
      cards: [card(free), card(codex, agent: .codex), card(podded)])
    let reasons = Dictionary(uniqueKeysWithValues: structure.candidates.map { ($0.id, $0.disabledReason) })
    #expect(reasons[free] == .some(nil))
    #expect(reasons[codex] == PodStructure.notClaudeReason)
    #expect(reasons[podded] == PodStructure.alreadyInPodReason("Chat"))
  }

  @Test func aSurfaceWithClaudeAndAnotherAgentIsOneEligibleCandidate() {
    let surface = UUID()
    let structure = PodStructure.compute(
      pods: [], cards: [card(surface, activity: .busy), card(surface, agent: .codex)])
    #expect(structure.candidates.count == 1)
    #expect(structure.candidates[0].isEligible)
    #expect(structure.candidates[0].activity == .busy)
    #expect(structure.candidates[0].agents == [.claude, .codex])
  }

  @Test func memberCardsTakeLiveActivityFromTheClaudeCard() {
    let live = UUID()
    let gone = UUID()
    let structure = PodStructure.compute(pods: [pod([live, gone])], cards: [card(live, activity: .busy)])
    let members = structure.pods[0].members
    #expect(members.map(\.activity) == [.busy, nil])
    #expect(members.map(\.worktreeName) == ["a", nil])
  }
}
