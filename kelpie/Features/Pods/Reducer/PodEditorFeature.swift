import ComposableArchitecture
import Foundation

/// The New pod / Add members sheet: pod fields plus one row per session, of
/// which only eligible Claude Code sessions can be checked.
@Reducer
struct PodEditorFeature {
  @ObservableState
  struct State: Equatable {
    enum Mode: Equatable {
      case create
      /// Pod fields are read-only; only new members are picked.
      case addMembers(PodID)
    }

    let mode: Mode
    var podName: String
    var podDescription: String
    let candidates: [PodStructure.Candidate]
    var drafts: IdentifiedArrayOf<PodMemberDraft>

    init(mode: Mode, podName: String = "", podDescription: String = "", candidates: [PodStructure.Candidate]) {
      self.mode = mode
      self.podName = podName
      self.podDescription = podDescription
      self.candidates = candidates
      drafts = IdentifiedArray(
        uniqueElements: candidates.filter(\.isEligible).map {
          PodMemberDraft(id: $0.id, worktreeID: $0.worktreeID)
        })
    }

    var isCreating: Bool { mode == .create }

    var trimmedPodName: String { podName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var selectedDrafts: [PodMemberDraft] { drafts.filter(\.isSelected) }

    /// A new pod needs a name and two members; adding needs one. Every picked
    /// member needs a name.
    var canSubmit: Bool {
      let selected = selectedDrafts
      guard selected.allSatisfy({ !$0.trimmedName.isEmpty }) else { return false }
      switch mode {
      case .create:
        return !trimmedPodName.isEmpty && selected.count >= 2
      case .addMembers:
        return !selected.isEmpty
      }
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case memberToggled(UUID)
    case memberNameChanged(UUID, String)
    case memberDescriptionChanged(UUID, String)
    case cancelTapped
    case submitTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case create(name: String, description: String, members: [PodMemberDraft])
    case addMembers(PodID, members: [PodMemberDraft])
  }

  @Dependency(\.dismiss) private var dismiss

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .memberToggled(let id):
        state.drafts[id: id]?.isSelected.toggle()
        return .none

      case .memberNameChanged(let id, let name):
        state.drafts[id: id]?.name = name
        return .none

      case .memberDescriptionChanged(let id, let description):
        state.drafts[id: id]?.description = description
        return .none

      case .cancelTapped:
        return .run { _ in await dismiss() }

      case .submitTapped:
        guard state.canSubmit else { return .none }
        let members = state.selectedDrafts.map { draft in
          var trimmed = draft
          trimmed.name = draft.trimmedName
          trimmed.description = draft.trimmedDescription
          return trimmed
        }
        let delegate: Delegate =
          switch state.mode {
          case .create:
            .create(
              name: state.trimmedPodName,
              description: state.podDescription.trimmingCharacters(in: .whitespacesAndNewlines),
              members: members)
          case .addMembers(let podID):
            .addMembers(podID, members: members)
          }
        return .concatenate(.send(.delegate(delegate)), .run { _ in await dismiss() })

      case .delegate:
        return .none
      }
    }
  }
}
