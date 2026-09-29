import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct FleetViewFeatureTests {
  private let worktreeA = Worktree.ID("/tmp/fleet/a")
  private let worktreeB = Worktree.ID("/tmp/fleet/b")

  private func card(_ worktree: Worktree.ID, agent: SkillAgent = .claude) -> FleetViewStructure.Card {
    let surfaceID = UUID()
    let tab = TabItem(
      id: TabID(), title: "Tab",
      content: ContentSnapshot(
        id: ContentID(rawValue: surfaceID), state: .terminal(TerminalContentState(workingDirectory: nil))))
    return FleetViewStructure.Card(
      id: FleetCardID(surfaceID: surfaceID, agent: agent), worktreeID: worktree, repositoryID: "/tmp/fleet",
      tab: tab, activity: .idle, repositoryName: "fleet", worktreeName: worktree.rawValue,
      branchName: "main", workingDirectoryPath: worktree.rawValue, isFolder: false, model: nil, effort: nil,
      lastMessage: nil)
  }

  private func rows(_ worktrees: [Worktree.ID]) -> [FleetViewStructure.LauncherRow] {
    worktrees.map { .init(id: $0, name: $0.rawValue, repositoryName: "fleet") }
  }

  private func structure(
    _ cards: [[FleetViewStructure.Card]], rows: [FleetViewStructure.LauncherRow] = []
  ) -> FleetViewStructure {
    FleetViewStructure(
      sections: cards.enumerated().map { index, cards in
        .init(id: index == 0 ? .ungrouped : .group(RepositoryGroupID("g\(index)")), title: nil, cards: cards)
      },
      launcherRows: rows)
  }

  private func makeStore(_ state: FleetViewFeature.State = .init()) -> TestStoreOf<FleetViewFeature> {
    TestStore(initialState: state) { FleetViewFeature() }
  }

  @Test(.dependencies) func toggleOpensFocusesFirstCardAndClosesAgain() async {
    let first = card(worktreeA)
    let second = card(worktreeB)
    var state = FleetViewFeature.State()
    state.structure = structure([[first, second]])
    let store = makeStore(state)

    await store.send(.toggle) {
      $0.isPresented = true
      $0.focusedCardID = first.id
    }
    await store.send(.toggle)
    await store.receive(\.dismiss) { $0.isPresented = false }
    await store.receive(\.delegate.dismissed)
  }

  @Test(.dependencies) func dismissWhenClosedIsANoOp() async {
    let store = makeStore()
    await store.send(.dismiss)
  }

  @Test(.dependencies) func arrowsMoveFocusUsingColumnCount() async {
    let cards = (0..<4).map { _ in card(worktreeA) }
    var state = FleetViewFeature.State()
    state.structure = structure([cards])
    state.isPresented = true
    state.focusedCardID = cards[0].id
    let store = makeStore(state)

    await store.send(.columnCountChanged(2)) { $0.columnCount = 2 }
    await store.send(.moveFocus(.down)) { $0.focusedCardID = cards[2].id }
    await store.send(.moveFocus(.right)) { $0.focusedCardID = cards[3].id }
    await store.send(.moveFocus(.up)) { $0.focusedCardID = cards[1].id }
    await store.send(.columnCountChanged(0)) { $0.columnCount = 1 }
  }

  @Test(.dependencies) func enterAndClickOpenTheSession() async {
    let first = card(worktreeA)
    let second = card(worktreeB)
    var state = FleetViewFeature.State()
    state.structure = structure([[first, second]])
    state.isPresented = true
    state.focusedCardID = first.id
    let store = makeStore(state)

    await store.send(.activateFocusedCard) { $0.isPresented = false }
    await store.receive(\.delegate.openSession)

    store.exhaustivity = .off
    await store.send(.toggle)
    store.exhaustivity = .on
    await store.send(.cardTapped(second.id)) {
      $0.focusedCardID = second.id
      $0.isPresented = false
    }
    await store.receive(
      .delegate(.openSession(worktreeID: worktreeB, tabID: second.tab.id, surfaceID: second.surfaceID)))
  }

  @Test(.dependencies) func activateWithoutCardsDoesNothing() async {
    var state = FleetViewFeature.State()
    state.isPresented = true
    let store = makeStore(state)
    await store.send(.activateFocusedCard)
    await store.send(.cardTapped(FleetCardID(surfaceID: UUID(), agent: .codex)))
  }

  @Test(.dependencies) func keysAreIgnoredWhileDismissed() async {
    let first = card(worktreeA)
    var state = FleetViewFeature.State()
    state.structure = structure([[first]])
    state.focusedCardID = first.id
    let store = makeStore(state)
    await store.send(.moveFocus(.right))
    await store.send(.activateFocusedCard)
    await store.send(.cardTapped(first.id))
  }

  @Test(.dependencies) func applyStructureReconcilesFocusOntoNearestSurvivor() {
    let cards = (0..<3).map { _ in card(worktreeA) }
    var state = FleetViewFeature.State()
    state.applyStructure(structure([cards], rows: rows([worktreeA])))
    #expect(state.focusedCardID == cards[0].id)
    #expect(state.structure.launcherRows == rows([worktreeA]))

    state.focusedCardID = cards[1].id
    state.applyStructure(structure([[cards[0], cards[2]]], rows: rows([worktreeA, worktreeB])))
    #expect(state.focusedCardID == cards[2].id)
    #expect(state.structure.launcherRows.count == 2)

    state.applyStructure(.empty)
    #expect(state.focusedCardID == nil)

    state.applyStructure(structure([[cards[0]]]))
    #expect(state.focusedCardID == cards[0].id)
  }

  @Test(.dependencies) func launchUsesRememberedAgentAndAccount() async {
    var state = FleetViewFeature.State()
    state.isPresented = true
    state.launcherWorktreeID = worktreeA
    state.$agentsFile.withLock {
      $0 = AgentsFile(agents: [.init(agent: .claude), .init(agent: .claude, path: "/tmp/.claude-personal")])
    }
    let store = makeStore(state)

    await store.send(.launcherAgentChanged(.codex)) { $0.$launcherAgent.withLock { $0 = .codex } }
    await store.send(.launcherAgentChanged(.claude)) { $0.$launcherAgent.withLock { $0 = .claude } }
    await store.send(.launcherAccountChanged("/tmp/.claude-personal")) {
      $0.$launcherClaudeConfigDirectory.withLock { $0 = "/tmp/.claude-personal" }
    }
    #expect(store.state.showsAccountPicker)
    await store.send(.launchTapped) { $0.isPresented = false }
    await store.receive(
      .delegate(.launch(worktreeID: worktreeA, command: "CLAUDE_CONFIG_DIR='/tmp/.claude-personal' claude")))
  }

  @Test(.dependencies) func launchFallsBackToDefaultAccountWhenFolderIsGone() async {
    var state = FleetViewFeature.State()
    state.isPresented = true
    state.launcherWorktreeID = worktreeA
    state.$launcherClaudeConfigDirectory.withLock { $0 = "/gone" }
    let store = makeStore(state)

    #expect(!store.state.showsAccountPicker)
    await store.send(.launchTapped) { $0.isPresented = false }
    await store.receive(.delegate(.launch(worktreeID: worktreeA, command: "claude")))
  }

  @Test(.dependencies) func nonLaunchableRememberedAgentFallsBackToClaude() async {
    var state = FleetViewFeature.State()
    state.isPresented = true
    state.launcherWorktreeID = worktreeA
    state.$launcherAgent.withLock { $0 = .antigravity }
    let store = makeStore(state)

    #expect(store.state.resolvedLauncherAgent == .claude)
    await store.send(.launchTapped) { $0.isPresented = false }
    await store.receive(.delegate(.launch(worktreeID: worktreeA, command: "claude")))
  }

  @Test(.dependencies) func launchNeedsAWorktree() async {
    var state = FleetViewFeature.State()
    state.isPresented = true
    let store = makeStore(state)
    await store.send(.launcherWorktreeChanged(nil))
    await store.send(.launchTapped)
  }
}
