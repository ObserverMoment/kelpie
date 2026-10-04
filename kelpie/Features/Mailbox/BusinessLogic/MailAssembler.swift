import Foundation
import KelpieSettingsShared

/// Reassembles `kind=mail` OSC chunks into whole messages, one assembler per
/// surface. `seq=1` always starts a fresh message, so a chunk lost in transit
/// costs at most the message it belonged to, never the ones after it.
nonisolated struct MailAssembler: Equatable, Sendable {
  struct Completed: Equatable, Sendable {
    let agent: SkillAgent
    let body: String
  }

  private struct Partial: Equatable, Sendable {
    let agent: String
    let total: Int
    var chunks: [Int: String] = [:]
  }

  private var partials: [String: Partial] = [:]

  /// Feeds one chunk; returns the decoded message when it completes one.
  mutating func accept(_ chunk: AgentPresenceOSC.MailChunk) -> Completed? {
    var partial: Partial
    if chunk.index == 1 || partials[chunk.messageID]?.total != chunk.total {
      partial = Partial(agent: chunk.agent, total: chunk.total)
    } else if let existing = partials[chunk.messageID] {
      partial = existing
    } else {
      // A continuation with no start on record: the first chunk was lost.
      return nil
    }
    partial.chunks[chunk.index] = chunk.body
    guard partial.chunks.count == partial.total else {
      partials[chunk.messageID] = partial
      return nil
    }
    partials.removeValue(forKey: chunk.messageID)
    let joined = (1...partial.total).compactMap { partial.chunks[$0] }.joined()
    guard let agent = SkillAgent(rawValue: partial.agent),
      let body = AgentPresenceOSC.decodeMailBody(joined)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !body.isEmpty
    else { return nil }
    return Completed(agent: agent, body: body)
  }
}
