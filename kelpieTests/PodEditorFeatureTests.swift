import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct PodEditorFeatureTests {
  private let worktree = Worktree.ID("/tmp/pods/a")
  private let first = UUID()
  private let second = UUID()
  private let codex = UUID()

  private func candidate(_ id: UUID, reason: String? = nil) -> PodStructure.Candidate {
    PodStructure.Candidate(
      id: id, worktreeID: worktree, worktreeName: "a", repositoryName: "pods", branchName: "main",
      agents: [.claude], activity: .idle, disabledReason: reason)
  }

  private var candidates: [PodStructure.Candidate] {
    [candidate(first), candidate(second), candidate(codex, reason: PodStructure.notClaudeReason)]
  }

  @Test func onlyEligibleSessionsGetDrafts() {
    let state = PodEditorFeature.State(mode: .create, candidates: candidates)
    #expect(Array(state.drafts.ids) == [first, second])
  }

  @Test func createNeedsANameTwoMembersAndMemberNames() {
    var state = PodEditorFeature.State(mode: .create, candidates: candidates)
    state.podName = "  "
    state.drafts[id: first]?.isSelected = true
    state.drafts[id: first]?.name = "Frontend"
    state.drafts[id: second]?.isSelected = true
    #expect(!state.canSubmit)
    state.podName = "Chat"
    #expect(!state.canSubmit)
    state.drafts[id: second]?.name = "Backend"
    #expect(state.canSubmit)
    state.drafts[id: second]?.isSelected = false
    #expect(!state.canSubmit)
  }

  @Test func addingNeedsOneNamedMember() {
    var state = PodEditorFeature.State(mode: .addMembers(PodID(rawValue: UUID())), candidates: candidates)
    #expect(!state.canSubmit)
    state.drafts[id: first]?.isSelected = true
    #expect(!state.canSubmit)
    state.drafts[id: first]?.name = "Frontend"
    #expect(state.canSubmit)
  }

  @Test(.dependencies) func submitSendsTrimmedMembersAndDismisses() async {
    var state = PodEditorFeature.State(mode: .create, candidates: candidates)
    state.podName = " Chat "
    state.podDescription = " Build chat "
    let dismissed = LockIsolated(false)
    let store = TestStore(initialState: state) {
      PodEditorFeature()
    } withDependencies: {
      $0.dismiss = DismissEffect { dismissed.setValue(true) }
    }

    await store.send(.memberToggled(first)) { $0.drafts[id: self.first]?.isSelected = true }
    await store.send(.memberNameChanged(first, " Frontend ")) { $0.drafts[id: self.first]?.name = " Frontend " }
    await store.send(.memberToggled(second)) { $0.drafts[id: self.second]?.isSelected = true }
    await store.send(.memberNameChanged(second, "Backend")) { $0.drafts[id: self.second]?.name = "Backend" }
    await store.send(.memberDescriptionChanged(second, " API ")) {
      $0.drafts[id: self.second]?.description = " API "
    }
    await store.send(.submitTapped)
    await store.receive(
      .delegate(
        .create(
          name: "Chat", description: "Build chat",
          members: [
            PodMemberDraft(id: first, worktreeID: worktree, isSelected: true, name: "Frontend"),
            PodMemberDraft(id: second, worktreeID: worktree, isSelected: true, name: "Backend", description: "API"),
          ])))
    await store.finish()
    #expect(dismissed.value)
  }

  @Test(.dependencies) func submitDoesNothingUntilValid() async {
    let store = TestStore(initialState: PodEditorFeature.State(mode: .create, candidates: candidates)) {
      PodEditorFeature()
    }
    await store.send(.submitTapped)
  }
}
