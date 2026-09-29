import Foundation

/// The text Kelpie types into pod members. Agents act on it, so every prompt
/// opens with a `[Kelpie]` tag and says exactly what to do.
enum PodPrompt {
  /// A podmate as the roster lists it. `id` is the name `SendMessage` takes.
  struct Podmate: Equatable, Encodable, Sendable {
    let id: String
    let name: String
    let description: String
  }

  /// Asks the agent to report the session name its podmates reach it by.
  static func register(podName: String, memberName: String, surfaceID: UUID) -> String {
    """
    [Kelpie] You are being added to the agent pod "\(podName)" as "\(memberName)". \
    Find your own session name with ListAgents, then run this shell command with that name:
    kelpie pod register --surface \(surfaceID.uuidString) --name <your session name>
    Do nothing else, and reply with one short line.
    """
  }

  /// Introduces the agent to its podmates and sets the bar for messaging them.
  static func roster(podName: String, podDescription: String, you: Podmate, podmates: [Podmate]) -> String {
    let pod = podDescription.isEmpty ? "\"\(podName)\"" : "\"\(podName)\" (\(podDescription))"
    let yourself = you.description.isEmpty ? "" : ": \(you.description)"
    return """
      [Kelpie] You are in the agent pod \(pod) as "\(you.name)"\(yourself). \
      Your podmates, where id is the name SendMessage takes:
      \(json(podmates))
      Message a podmate with SendMessage only when you change or decide something they depend on \
      (an API contract, shared types, a schema, or a plan decision that affects their area), \
      or when you are blocked on them. Do not send progress updates, acknowledgements, \
      or replies that add nothing. Reply with one short line, then carry on with your current task.
      """
  }

  /// Tells a former member the pod is gone.
  static func disbanded(podName: String) -> String {
    """
    [Kelpie] The agent pod "\(podName)" was disbanded. \
    Stop messaging your former podmates. Reply with one short line.
    """
  }

  private static func json(_ podmates: [Podmate]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(podmates) else { return "[]" }
    return String(bytes: data, encoding: .utf8) ?? "[]"
  }
}
