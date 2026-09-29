import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// Worktree, agent and (for Claude Code with several config folders) account
/// pickers plus the Launch button.
struct FleetLauncherView: View {
  @Bindable var store: StoreOf<FleetViewFeature>

  var body: some View {
    HStack(spacing: 8) {
      Picker("Worktree", selection: worktreeSelection) {
        if needsPlaceholderChoice {
          Text("Choose a worktree").tag(Worktree.ID?.none)
        }
        ForEach(store.structure.launcherRows) { row in
          Text("\(row.repositoryName) · \(row.name)").tag(Worktree.ID?.some(row.id))
        }
      }
      .help("Worktree the new session opens in")

      Picker("Agent", selection: agentSelection) {
        ForEach(AgentLaunchCommand.launchableAgents, id: \.self) { agent in
          Text(agent.displayName).tag(agent)
        }
      }
      .help("Agent to launch; Claude Code by default")

      if store.showsAccountPicker {
        Picker("Account", selection: accountSelection) {
          ForEach(store.claudeAccounts) { account in
            Text(account.displayName).tag(account.configDirectoryPath)
          }
        }
        .help("Claude Code config folder, set through CLAUDE_CONFIG_DIR")
      }

      Button {
        store.send(.launchTapped)
      } label: {
        Label("Launch", systemImage: "play.fill")
      }
      .disabled(store.launcherWorktreeID == nil)
      .help("Launch \(store.resolvedLauncherAgent.displayName) in a new tab of the chosen worktree")
    }
    .pickerStyle(.menu)
  }

  /// The picker needs an explicit empty entry until the selection names a listed row.
  private var needsPlaceholderChoice: Bool {
    let selected = store.launcherWorktreeID
    return selected == nil || !store.structure.launcherRows.contains { $0.id == selected }
  }

  private var worktreeSelection: Binding<Worktree.ID?> {
    Binding(
      get: { store.launcherWorktreeID },
      set: { store.send(.launcherWorktreeChanged($0)) })
  }

  private var agentSelection: Binding<SkillAgent> {
    Binding(
      get: { store.resolvedLauncherAgent },
      set: { store.send(.launcherAgentChanged($0)) })
  }

  private var accountSelection: Binding<String?> {
    Binding(
      get: { store.resolvedClaudeConfigDirectory },
      set: { store.send(.launcherAccountChanged($0)) })
  }
}
