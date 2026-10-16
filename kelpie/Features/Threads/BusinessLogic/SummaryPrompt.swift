import Foundation
import KelpieSettingsShared

/// Builds the request that rolls a thread's summary forward and reads the
/// summariser's reply. Pure, so the reducer tests never need a model.
nonisolated enum SummaryPrompt {
  enum Kind: Equatable, Sendable {
    case session
    case pod
  }

  struct Request: Equatable, Sendable {
    let systemPrompt: String
    let prompt: String
    let model: ThreadSummaryModel
    let effort: ThreadSummaryEffort
  }

  /// Each queued message is cut to this before it rides in argv: the summary
  /// wants the gist, and the whole command has to fit the kernel's limit.
  static let maxMessageCharacters = 4000

  /// Three lines of the thread header at a typical window width, about 185
  /// characters a line. A backstop: the prompt asks for a word budget that
  /// lands well under it, since a model counts words far better than characters.
  static func cap(for kind: Kind) -> Int {
    switch kind {
    case .session, .pod: 560
    }
  }

  /// What the prompt asks for. About 6.5 characters a word including the
  /// space, so the ceiling sits around 550 characters and the target around 450.
  static let targetWords = 70
  static let maxWords = 85

  static func request(
    kind: Kind, previous: String?, newMessages: [String], model: ThreadSummaryModel, effort: ThreadSummaryEffort
  ) -> Request {
    Request(
      systemPrompt: systemPrompt(for: kind),
      prompt: prompt(previous: previous, newMessages: newMessages),
      model: model,
      effort: effort)
  }

  static func systemPrompt(for kind: Kind) -> String {
    let subject =
      switch kind {
      case .session: "one coding agent's session"
      case .pod: "a pod of coding agents working together"
      }
    return """
      You keep a running summary of \(subject). You are given the previous summary and the \
      messages the agent ended its latest turns with. Rewrite the summary so it covers everything \
      so far, favouring what is happening now and what is left to do over history. Plain prose of \
      about \(targetWords) words; \(maxWords) words is the absolute most, and anything longer is cut \
      off mid-sentence, so end cleanly before then. No headings, no bullet points, no preamble. \
      Reply with the summary text only.
      """
  }

  static func prompt(previous: String?, newMessages: [String]) -> String {
    let previousBlock =
      previous.map { "<previous-summary>\n\($0)\n</previous-summary>" }
      ?? "<previous-summary>(none yet)</previous-summary>"
    let messages =
      newMessages
      .map { "<message>\n\(truncate($0, cap: maxMessageCharacters))\n</message>" }
      .joined(separator: "\n")
    return "\(previousBlock)\n<new-messages>\n\(messages)\n</new-messages>"
  }

  /// Trims to the cap with a closing ellipsis; the prompt asks for the cap,
  /// this enforces it.
  static func truncate(_ text: String, cap: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > cap else { return trimmed }
    return String(trimmed.prefix(cap - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// `claude -p --output-format json` prints one object whose `result` is the reply.
  static func parseResult(_ data: Data) throws -> String {
    struct Envelope: Decodable {
      let result: String?
      let isError: Bool?

      enum CodingKeys: String, CodingKey {
        case result
        case isError = "is_error"
      }
    }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    let result = envelope.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard envelope.isError != true else { throw ThreadSummaryError.modelFailed(result) }
    guard !result.isEmpty else { throw ThreadSummaryError.emptyResult }
    return result
  }
}

nonisolated enum ThreadSummaryError: LocalizedError, Equatable {
  case claudeFailed(status: Int32, detail: String)
  case modelFailed(String)
  case emptyResult
  case timedOut

  var errorDescription: String? {
    switch self {
    case .claudeFailed(let status, let detail): "claude exited with \(status): \(detail)"
    case .modelFailed(let detail): "Claude reported an error: \(detail)"
    case .emptyResult: "Claude returned no summary."
    case .timedOut: "Claude did not answer within \(ThreadSummaryClient.timeout)."
    }
  }
}
