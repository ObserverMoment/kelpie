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
    /// Names the pod's current members already use, so a filled-in name
    /// never duplicates one when adding members.
    let takenNames: [String]
    var drafts: IdentifiedArrayOf<PodMemberDraft>

    init(
      mode: Mode, podName: String = "", podDescription: String = "", candidates: [PodStructure.Candidate],
      takenNames: [String] = []
    ) {
      self.mode = mode
      self.podName = podName
      self.podDescription = podDescription
      self.candidates = candidates
      self.takenNames = takenNames
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
  @Dependency(ContentRuntime.self) private var contentRuntime

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .memberToggled(let id):
        state.drafts[id: id]?.isSelected.toggle()
        if state.drafts[id: id]?.isSelected == true {
          fillName(for: id, state: &state)
        }
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

  /// A just-selected member takes its tab title as its name, kept distinct
  /// from every other name in the pod; a name the user typed stays unless it
  /// now collides.
  private func fillName(for id: UUID, state: inout State) {
    guard let draft = state.drafts[id: id], let candidate = state.candidates.first(where: { $0.id == id }) else {
      return
    }
    let otherNames = state.selectedDrafts.filter { $0.id != id }.map(\.trimmedName)
    let base = draft.trimmedName.isEmpty ? TabTitle.resolved(for: candidate.tab, runtime: contentRuntime) : draft.name
    let taken = state.takenNames + otherNames
    state.drafts[id: id]?.name = Self.uniqueName(base, taken: taken)
  }

  /// `name`, or `name 2`, `name 3`… when a selected member already has it, so
  /// two sessions titled alike still get distinct podmate names.
  static func uniqueName(_ name: String, taken: [String]) -> String {
    guard taken.contains(name) else { return name }
    let suffixed = (2...).lazy.map { "\(name) \($0)" }
    return suffixed.first { !taken.contains($0) } ?? name
  }
}
