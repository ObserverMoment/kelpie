import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct ThreadsStructureTests {
  private static let worktreeID = WorktreeID("/tmp/threads/wt")
  private static let podID = PodID(rawValue: UUID())

  private static func box(_ surfaceID: UUID, summary: String? = nil, unread: Int = 1) -> MessageThread {
    var box = MessageThread(surfaceID: surfaceID, worktreeID: worktreeID, agent: .claude)
    box.messages = (0..<unread).map { MailMessage(id: UUID(), body: "m\($0)", createdAt: .distantPast) }
    box.summary = summary
    return box
  }

  private static func compute(file: ThreadsFile, pods: IdentifiedArrayOf<Pod>) -> ThreadsStructure {
    ThreadsStructure.compute(
      .init(
        file: file, pods: pods, sidebarItems: [], repositories: [], presence: AgentPresenceFeature.State(), layouts: [])
    )
  }

  @Test func poddedSessionsSitUnderTheirPodAndLeaveNoTileOfTheirOwn() {
    let member = UUID()
    let loner = UUID()
    let file = ThreadsFile(
      boxes: [Self.box(member, summary: "member summary"), Self.box(loner)],
      podSummaries: [Self.podID.rawValue.uuidString: "pod summary"])
    let pod = Pod(
      id: Self.podID, name: "Crew", description: "",
      members: [PodMember(id: member, worktreeID: Self.worktreeID, name: "Alpha", description: "")],
      sentRoster: nil)
    let structure = Self.compute(file: file, pods: [pod])

    #expect(structure.tiles.map(\.id) == [.pod(Self.podID), .session(loner)])
    #expect(structure.pod(Self.podID)?.members.map(\.memberName) == ["Alpha"])
    #expect(structure.pod(Self.podID)?.members.first?.summary == "member summary")
    #expect(structure.threadID(containingSurface: member) == .pod(Self.podID))
    #expect(structure.threadID(containingSurface: loner) == .session(loner))
    #expect(structure.threadID(containingSurface: UUID()) == nil)
    #expect(structure.memberIDs(of: Self.podID) == [member])
    #expect(
      structure.navigationOrder(expandedPods: [Self.podID]) == [.pod(Self.podID), .session(member), .session(loner)])
    #expect(structure.navigationOrder(expandedPods: []) == [.pod(Self.podID), .session(loner)])
  }

  @Test func aPodWithNoInboxesHasNoTile() {
    let pod = Pod(
      id: Self.podID, name: "Crew", description: "",
      members: [PodMember(id: UUID(), worktreeID: Self.worktreeID, name: "Alpha", description: "")],
      sentRoster: nil)
    #expect(Self.compute(file: ThreadsFile(), pods: [pod]).tiles.isEmpty)
  }

  @Test func sessionsSortLiveBeforeStaleThenByUnreadAndTakeTheirNamesFromTheSidebar() {
    let stale = UUID()
    let liveQuiet = UUID()
    let liveBusy = UUID()
    let file = ThreadsFile(boxes: [
      Self.box(stale, unread: 2), Self.box(liveQuiet, unread: 0), Self.box(liveBusy, unread: 3),
    ])
    var presence = AgentPresenceFeature.State()
    presence.bySurface[liveQuiet] = [.claude]
    presence.bySurface[liveBusy] = [.claude]
    let repositoryID = RepositoryID("/tmp/threads")
    let item = SidebarItemFeature.State(
      id: Self.worktreeID, repositoryID: repositoryID, kind: .gitWorktree, name: "feature", branchName: "feature",
      subtitle: nil, workingDirectory: URL(fileURLWithPath: "/tmp/threads/wt"), repositoryAccent: nil,
      isMainWorktree: false, isPinned: false, hasMergedBadge: false)
    let repository = Repository(
      id: repositoryID, rootURL: URL(fileURLWithPath: "/tmp/threads"), name: "threads", worktrees: [])
    let structure = ThreadsStructure.compute(
      .init(file: file, pods: [], sidebarItems: [item], repositories: [repository], presence: presence, layouts: []))

    #expect(structure.sessions.map(\.id) == [liveBusy, liveQuiet, stale])
    #expect(structure.sessions.map(\.isStale) == [false, false, true])
    #expect(structure.sessions.first?.worktreeName == "feature")
    #expect(structure.sessions.first?.repositoryName == "threads")
  }

  @Test func podsSortByUnreadThenName() {
    let quietSurface = UUID()
    let busySurface = UUID()
    let file = ThreadsFile(boxes: [Self.box(quietSurface, unread: 0), Self.box(busySurface, unread: 2)])
    let quiet = Pod(
      id: PodID(rawValue: UUID()), name: "Alpha", description: "",
      members: [PodMember(id: quietSurface, worktreeID: Self.worktreeID, name: "A", description: "")], sentRoster: nil)
    let busy = Pod(
      id: PodID(rawValue: UUID()), name: "Zulu", description: "",
      members: [PodMember(id: busySurface, worktreeID: Self.worktreeID, name: "B", description: "")], sentRoster: nil)
    #expect(Self.compute(file: file, pods: [quiet, busy]).pods.map(\.name) == ["Zulu", "Alpha"])

    // Equal unread counts fall back to the name.
    let alsoBusy = Pod(
      id: PodID(rawValue: UUID()), name: "Mike", description: "",
      members: [PodMember(id: quietSurface, worktreeID: Self.worktreeID, name: "A", description: "")],
      sentRoster: nil)
    let evenFile = ThreadsFile(boxes: [Self.box(quietSurface, unread: 2), Self.box(busySurface, unread: 2)])
    #expect(Self.compute(file: evenFile, pods: [busy, alsoBusy]).pods.map(\.name) == ["Mike", "Zulu"])
  }

  @Test func sessionsEqualOnLivenessAndUnreadSortByWorktreeName() {
    let zulu = WorktreeID("/tmp/threads/zulu")
    let alpha = WorktreeID("/tmp/threads/alpha")
    let zuluSurface = UUID()
    let alphaSurface = UUID()
    var zuluBox = MessageThread(surfaceID: zuluSurface, worktreeID: zulu, agent: .claude)
    zuluBox.messages = [MailMessage(id: UUID(), body: "z", createdAt: .distantPast)]
    var alphaBox = MessageThread(surfaceID: alphaSurface, worktreeID: alpha, agent: .claude)
    alphaBox.messages = [MailMessage(id: UUID(), body: "a", createdAt: .distantPast)]
    let repositoryID = RepositoryID("/tmp/threads")
    let items = [zulu, alpha].map { id in
      SidebarItemFeature.State(
        id: id, repositoryID: repositoryID, kind: .gitWorktree, name: id.rawValue, branchName: "main",
        subtitle: nil, workingDirectory: URL(fileURLWithPath: id.rawValue), repositoryAccent: nil,
        isMainWorktree: false, isPinned: false, hasMergedBadge: false)
    }
    let structure = ThreadsStructure.compute(
      .init(
        file: ThreadsFile(boxes: [zuluBox, alphaBox]), pods: [], sidebarItems: IdentifiedArray(uniqueElements: items),
        repositories: [], presence: AgentPresenceFeature.State(), layouts: []))
    #expect(structure.sessions.map(\.id) == [alphaSurface, zuluSurface])
  }
}
