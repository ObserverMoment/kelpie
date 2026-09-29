import Foundation
import IdentifiedCollections

nonisolated struct PodID: Hashable, Sendable {
  let rawValue: UUID
}

/// One Claude Code session in a pod, keyed by its terminal surface.
struct PodMember: Identifiable, Equatable, Sendable {
  enum Registration: Equatable, Sendable {
    /// Waiting for the agent to report its messaging name.
    case pending
    /// The agent reported the name its podmates reach it by.
    case registered(sessionName: String)
    /// The agent never reported back in time; it is left out of the roster.
    case unreachable
  }

  /// The terminal surface the session runs in.
  let id: UUID
  let worktreeID: Worktree.ID
  var name: String
  var description: String
  var registration: Registration = .pending

  var sessionName: String? {
    guard case .registered(let sessionName) = registration else { return nil }
    return sessionName
  }
}

/// A named group of Claude Code sessions that know about each other. Kelpie
/// introduces them; they message each other with Claude's own tools.
struct Pod: Identifiable, Equatable, Sendable {
  let id: PodID
  var name: String
  var description: String
  var members: IdentifiedArrayOf<PodMember>
  /// The roster last sent to the members, so an unchanged roster is not sent
  /// twice. Nil until the pod first forms.
  var sentRoster: [PodPrompt.Podmate]?

  var hasPendingMembers: Bool {
    members.contains { $0.registration == .pending }
  }

  /// The members podmates can message, in pod order.
  var roster: [PodPrompt.Podmate] {
    members.compactMap { member in
      member.sessionName.map {
        PodPrompt.Podmate(id: $0, name: member.name, description: member.description)
      }
    }
  }
}

/// One session's row in the pod editor.
struct PodMemberDraft: Identifiable, Equatable, Sendable {
  /// The terminal surface the session runs in.
  let id: UUID
  let worktreeID: Worktree.ID
  var isSelected = false
  var name = ""
  var description = ""

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A prompt waiting for its surface's agent to go idle.
struct QueuedPrompt: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case register
    case roster
    case disbanded
  }

  let kind: Kind
  let text: String
}
