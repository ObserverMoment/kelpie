import Foundation
import KelpieSettingsShared
import OrderedCollections

/// A Claude Code config folder Kelpie has hooks installed in, offered as an
/// "account" in the launcher (the default `~/.claude` plus every custom folder).
struct ClaudeAccount: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  /// nil for the default folder, so the launch command sets no `CLAUDE_CONFIG_DIR`.
  let configDirectoryPath: String?

  static let `default` = ClaudeAccount(id: "default", displayName: "~/.claude", configDirectoryPath: nil)
}

/// Builds the shell input that starts an agent in a fresh tab.
enum AgentLaunchCommand {
  /// Agents the launcher can start: those with a known CLI.
  static let launchableAgents: [SkillAgent] = SkillAgent.allCasesByDisplayName.filter { $0.launchCommand != nil }

  /// The folders Kelpie has Claude hooks in: the default one when it is on record
  /// (or nothing is, so `claude` still launches), plus each custom folder once.
  static func claudeAccounts(from file: AgentsFile) -> [ClaudeAccount] {
    let records = file.agents.filter { $0.agent == .claude }
    let customPaths = OrderedSet(records.compactMap(\.path))
    let customAccounts = customPaths.map { path in
      ClaudeAccount(
        id: path,
        displayName: (path as NSString).abbreviatingWithTildeInPath,
        configDirectoryPath: path)
    }
    let includesDefault = records.isEmpty || records.contains { $0.path == nil }
    return (includesDefault ? [.default] : []) + customAccounts
  }

  /// The remembered folder when it is still on record, else the first account
  /// (the default when installed, otherwise the only custom folder).
  static func resolvedConfigDirectoryPath(stored: String?, accounts: [ClaudeAccount]) -> String? {
    guard accounts.count > 1 else { return accounts.first?.configDirectoryPath }
    return accounts.first { $0.configDirectoryPath == stored }?.configDirectoryPath
      ?? accounts.first?.configDirectoryPath
  }

  /// A plain `VAR=value command` prefix (bash, zsh and fish 3.1+ all accept it) rather
  /// than `env`, which would bypass the shell alias or function many Claude Code
  /// installs launch through.
  static func command(agent: SkillAgent, configDirectoryPath: String?) -> String? {
    guard let cli = agent.launchCommand else { return nil }
    guard agent == .claude, let path = configDirectoryPath, !path.isEmpty else { return cli }
    return "CLAUDE_CONFIG_DIR=\(SSHCommand.shellQuote(path)) \(cli)"
  }
}
