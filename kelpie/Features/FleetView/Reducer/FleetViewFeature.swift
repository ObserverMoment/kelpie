import ComposableArchitecture
import Foundation
import KelpieSettingsShared

/// Full-window overview of every live agent session, plus a launcher for new
/// ones. Owns presentation, card focus and the launcher choices; `AppFeature`
/// feeds it the card structure, seeds the launcher's worktree and acts on its
/// delegates.
@Reducer
struct FleetViewFeature {
  /// What the overlay shows.
  enum Mode: Hashable, Sendable {
    case fleet
    case pods
    /// One pod's members side by side, full window.
    case podWorkspace(PodID)
  }

  @ObservableState
  struct State: Equatable {
    var isPresented = false
    var mode: Mode = .fleet

    var isShowingPodWorkspace: Bool {
      guard isPresented, case .podWorkspace = mode else { return false }
      return true
    }
    var structure: FleetViewStructure = .empty
    var focusedCardID: FleetCardID?
    var columnCount = 1
    var launcherWorktreeID: Worktree.ID?
    @Shared(.fleetLauncherAgent) var launcherAgent: SkillAgent
    @Shared(.fleetLauncherClaudeConfigDirectory) var launcherClaudeConfigDirectory: String?
    @Shared(.agentsFile) var agentsFile: AgentsFile

    var claudeAccounts: [ClaudeAccount] { AgentLaunchCommand.claudeAccounts(from: agentsFile) }

    /// The remembered agent, or Claude Code when the stored value has no CLI
    /// (a stale or hand-edited preference), so Launch always does something.
    var resolvedLauncherAgent: SkillAgent {
      launcherAgent.launchCommand == nil ? .claude : launcherAgent
    }

    /// The remembered folder, or the default when it is no longer installed.
    var resolvedClaudeConfigDirectory: String? {
      AgentLaunchCommand.resolvedConfigDirectoryPath(
        stored: launcherClaudeConfigDirectory, accounts: claudeAccounts)
    }

    var showsAccountPicker: Bool { resolvedLauncherAgent == .claude && claudeAccounts.count > 1 }

    var focusedCard: FleetViewStructure.Card? {
      focusedCardID.flatMap(structure.card(id:))
    }

    /// Stores a freshly computed structure when it changed and keeps the focus on
    /// a surviving card (or its nearest neighbour). Called from the parent's
    /// post-reduce step, so no action fires per presence tick.
    mutating func applyStructure(_ next: FleetViewStructure) {
      guard next != structure else { return }
      let previous = structure.allCards.map(\.id)
      structure = next
      focusedCardID =
        FleetViewNavigation.reconcile(
          focused: focusedCardID ?? previous.first, previous: previous, current: next.allCards.map(\.id))
        ?? next.allCards.first?.id
    }
  }

  enum Action: Equatable {
    /// Shows Fleet mode, or closes the overlay when Fleet mode is showing.
    case toggle
    /// Shows Pods mode, or closes the overlay when Pods mode is showing.
    case togglePods
    case modeChanged(Mode)
    case dismiss
    case columnCountChanged(Int)
    case moveFocus(FleetViewNavigation.Direction)
    case activateFocusedCard
    case cardTapped(FleetCardID)
    case launcherWorktreeChanged(Worktree.ID?)
    case launcherAgentChanged(SkillAgent)
    case launcherAccountChanged(String?)
    case launchTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case openSession(worktreeID: Worktree.ID, tabID: TabID, surfaceID: UUID)
    case launch(worktreeID: Worktree.ID, command: String)
    /// Closed without opening a session; the parent refocuses the terminal.
    case dismissed
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggle:
        return Self.toggle(.fleet, state: &state)

      case .togglePods:
        return Self.toggle(.pods, state: &state)

      case .modeChanged(let mode):
        state.mode = mode
        return .none

      case .dismiss:
        guard state.isPresented else { return .none }
        state.isPresented = false
        // Reopening lands on the pod list, not a workspace left open.
        if case .podWorkspace = state.mode {
          state.mode = .pods
        }
        return .send(.delegate(.dismissed))

      case .columnCountChanged(let count):
        state.columnCount = max(1, count)
        return .none

      case .moveFocus(let direction):
        guard state.isPresented, state.mode == .fleet else { return .none }
        state.focusedCardID = FleetViewNavigation.move(
          from: state.focusedCardID, direction,
          sections: state.structure.sectionCardIDs, columnCount: state.columnCount)
        return .none

      case .activateFocusedCard:
        guard state.isPresented, state.mode == .fleet, let card = state.focusedCard else { return .none }
        return Self.open(card, state: &state)

      case .cardTapped(let id):
        guard state.isPresented, let card = state.structure.card(id: id) else { return .none }
        state.focusedCardID = id
        return Self.open(card, state: &state)

      case .launcherWorktreeChanged(let worktreeID):
        state.launcherWorktreeID = worktreeID
        return .none

      case .launcherAgentChanged(let agent):
        state.$launcherAgent.withLock { $0 = agent }
        return .none

      case .launcherAccountChanged(let path):
        state.$launcherClaudeConfigDirectory.withLock { $0 = path }
        return .none

      case .launchTapped:
        guard let worktreeID = state.launcherWorktreeID,
          let command = AgentLaunchCommand.command(
            agent: state.resolvedLauncherAgent,
            configDirectoryPath: state.resolvedClaudeConfigDirectory)
        else { return .none }
        state.isPresented = false
        return .send(.delegate(.launch(worktreeID: worktreeID, command: command)))

      case .delegate:
        return .none
      }
    }
  }

  private static func toggle(_ mode: Mode, state: inout State) -> Effect<Action> {
    guard !(state.isPresented && state.mode == mode) else { return .send(.dismiss) }
    state.mode = mode
    guard !state.isPresented else { return .none }
    state.isPresented = true
    state.focusedCardID = state.structure.allCards.first?.id
    return .none
  }

  private static func open(_ card: FleetViewStructure.Card, state: inout State) -> Effect<Action> {
    state.isPresented = false
    return .send(
      .delegate(.openSession(worktreeID: card.worktreeID, tabID: card.tab.id, surfaceID: card.surfaceID)))
  }
}
