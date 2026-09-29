import ArgumentParser
import Foundation

struct PodCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pod",
    abstract: "Work with agent pods.",
    subcommands: [Register.self]
  )
}

extension PodCommand {
  struct Register: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Report this session's messaging name to its agent pod.",
      discussion: """
        Kelpie asks each Claude Code session it adds to a pod to run this with the \
        session name ListAgents reports, so its podmates can message it.
        """
    )

    @Option(name: [.short, .long], help: "The session name podmates message this agent by.")
    var name: String

    @Option(name: [.short, .long], help: "Surface ID. Defaults to $KELPIE_SURFACE_ID.")
    var surface: String?

    @OptionGroup var timeoutOption: TimeoutOption

    func validate() throws {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("--name must not be empty.")
      }
    }

    func run() throws {
      let surfaceID = try IDResolvers.resolveSurfaceID(surface)
      try Dispatcher.dispatch(
        deeplinkURL: DeeplinkURLBuilder.podRegister(surfaceID: surfaceID, name: name),
        timeoutSeconds: timeoutOption.timeout
      )
    }
  }
}
