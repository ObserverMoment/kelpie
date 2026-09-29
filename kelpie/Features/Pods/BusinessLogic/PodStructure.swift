import Foundation
import IdentifiedCollections
import KelpieSettingsShared

/// What Pods mode renders: one card per pod, and the sessions the pod editor
/// offers. Derived from the pods and Fleet View's cards, cached on
/// `PodsFeature.State` so the view observes one value.
struct PodStructure: Equatable, Sendable {
  struct MemberCard: Identifiable, Equatable, Sendable {
    /// The member's terminal surface.
    let id: UUID
    let worktreeID: Worktree.ID
    let name: String
    let description: String
    let registration: PodMember.Registration
    /// Nil when the session has no live Claude presence.
    let activity: AgentPresenceFeature.Activity?
    let worktreeName: String?
  }

  struct PodCard: Identifiable, Equatable, Sendable {
    let id: PodID
    let name: String
    let description: String
    let members: [MemberCard]
  }

  /// A session the pod editor lists. Only a Claude Code session outside every
  /// pod can join one; the rest show with the reason they can't.
  struct Candidate: Identifiable, Equatable, Sendable {
    /// The session's terminal surface.
    let id: UUID
    let worktreeID: Worktree.ID
    let worktreeName: String
    let repositoryName: String
    let branchName: String
    let agents: [SkillAgent]
    let activity: AgentPresenceFeature.Activity?
    let disabledReason: String?

    var isEligible: Bool { disabledReason == nil }
  }

  var pods: [PodCard]
  var candidates: [Candidate]

  static let empty = PodStructure(pods: [], candidates: [])

  static let notClaudeReason = "Pods work with Claude Code sessions only."

  static func alreadyInPodReason(_ podName: String) -> String {
    "Already in the pod \"\(podName)\"."
  }

  static func compute(pods: IdentifiedArrayOf<Pod>, cards: [FleetViewStructure.Card]) -> PodStructure {
    let claudeCards = Dictionary(
      cards.filter { $0.agent == .claude }.map { ($0.surfaceID, $0) },
      uniquingKeysWith: { first, _ in first })
    let podNameBySurface = podNames(pods)
    let podCards = pods.map { pod in
      PodCard(
        id: pod.id,
        name: pod.name,
        description: pod.description,
        members: pod.members.map { member in
          let card = claudeCards[member.id]
          return MemberCard(
            id: member.id,
            worktreeID: member.worktreeID,
            name: member.name,
            description: member.description,
            registration: member.registration,
            activity: card?.activity,
            worktreeName: card?.worktreeName)
        })
    }
    let cardsBySurface = Dictionary(grouping: cards, by: \.surfaceID)
    let candidates = cards.map(\.surfaceID).uniqued().compactMap { surfaceID -> Candidate? in
      guard let surfaceCards = cardsBySurface[surfaceID], let first = surfaceCards.first else { return nil }
      let claude = claudeCards[surfaceID]
      let disabledReason: String? =
        if let podName = podNameBySurface[surfaceID] {
          alreadyInPodReason(podName)
        } else if claude == nil {
          notClaudeReason
        } else {
          nil
        }
      return Candidate(
        id: surfaceID,
        worktreeID: first.worktreeID,
        worktreeName: first.worktreeName,
        repositoryName: first.repositoryName,
        branchName: first.branchName,
        agents: surfaceCards.map(\.agent),
        activity: claude?.activity,
        disabledReason: disabledReason)
    }
    return PodStructure(pods: podCards, candidates: candidates)
  }

  /// The pod each member surface belongs to, by name.
  static func podNames(_ pods: IdentifiedArrayOf<Pod>) -> [UUID: String] {
    pods.reduce(into: [:]) { names, pod in
      for member in pod.members { names[member.id] = pod.name }
    }
  }
}

extension Sequence where Element: Hashable {
  /// The elements in order, keeping the first of each duplicate.
  fileprivate func uniqued() -> [Element] {
    var seen: Set<Element> = []
    return filter { seen.insert($0).inserted }
  }
}
