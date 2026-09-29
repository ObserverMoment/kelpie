import ArgumentParser

@main
struct KelpieCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "kelpie",
    abstract: "Control Kelpie from the command line.",
    subcommands: [
      OpenCommand.self,
      WorktreeCommand.self,
      PaneCommand.self,
      TabCommand.self,
      SurfaceCommand.self,
      RepoCommand.self,
      SettingsCommand.self,
      PodCommand.self,
      SocketCommand.self,
    ],
    defaultSubcommand: OpenCommand.self
  )
}
