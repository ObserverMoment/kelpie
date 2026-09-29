import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct AgentLaunchCommandTests {
  @Test func plainCommandsForAgentsWithoutAccount() {
    #expect(AgentLaunchCommand.command(agent: .claude, configDirectoryPath: nil) == "claude")
    #expect(AgentLaunchCommand.command(agent: .codex, configDirectoryPath: "/x") == "codex")
    #expect(AgentLaunchCommand.command(agent: .antigravity, configDirectoryPath: nil) == nil)
    #expect(!AgentLaunchCommand.launchableAgents.contains(.antigravity))
    #expect(AgentLaunchCommand.launchableAgents.contains(.claude))
  }

  @Test func claudeAccountUsesEnvWithQuotedPath() {
    let command = AgentLaunchCommand.command(agent: .claude, configDirectoryPath: "/Users/me/it's/.claude-personal")
    #expect(command == "CLAUDE_CONFIG_DIR='/Users/me/it'\\''s/.claude-personal' claude")
    #expect(AgentLaunchCommand.command(agent: .claude, configDirectoryPath: "") == "claude")
  }

  @Test func accountsAreDefaultPlusDistinctClaudeFolders() {
    let file = AgentsFile(agents: [
      .init(agent: .claude),
      .init(agent: .codex, path: "/tmp/.codex-other"),
      .init(agent: .claude, path: NSHomeDirectory() + "/.claude-personal"),
      .init(agent: .claude, path: NSHomeDirectory() + "/.claude-personal"),
    ])
    let accounts = AgentLaunchCommand.claudeAccounts(from: file)

    #expect(accounts.map(\.configDirectoryPath) == [nil, NSHomeDirectory() + "/.claude-personal"])
    #expect(accounts.map(\.displayName) == ["~/.claude", "~/.claude-personal"])
  }

  @Test func storedAccountFallsBackToDefaultWhenGone() {
    let accounts = AgentLaunchCommand.claudeAccounts(
      from: AgentsFile(agents: [.init(agent: .claude), .init(agent: .claude, path: "/a")]))
    #expect(AgentLaunchCommand.resolvedConfigDirectoryPath(stored: "/a", accounts: accounts) == "/a")
    #expect(AgentLaunchCommand.resolvedConfigDirectoryPath(stored: "/gone", accounts: accounts) == nil)
    #expect(AgentLaunchCommand.resolvedConfigDirectoryPath(stored: nil, accounts: accounts) == nil)
  }

  @Test func customOnlyInstallIsTheSingleAccount() {
    let accounts = AgentLaunchCommand.claudeAccounts(from: AgentsFile(agents: [.init(agent: .claude, path: "/a")]))
    #expect(accounts.map(\.configDirectoryPath) == ["/a"])
    #expect(AgentLaunchCommand.resolvedConfigDirectoryPath(stored: nil, accounts: accounts) == "/a")
    #expect(AgentLaunchCommand.claudeAccounts(from: AgentsFile()).map(\.configDirectoryPath) == [nil])
  }
}
