import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// The New Pod / Add Members sheet. Each picked session needs a name; the
/// description is optional and goes into its podmates' roster.
struct PodEditorSheet: View {
  @Bindable var store: StoreOf<PodEditorFeature>

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $store.podName, prompt: Text("New chat feature"))
          .disabled(!store.isCreating)
        TextField("Description", text: $store.podDescription, prompt: Text("Optional"), axis: .vertical)
          .lineLimit(1...3)
          .disabled(!store.isCreating)
      } header: {
        Text(store.isCreating ? "New Pod" : "Add Members to \"\(store.podName)\"")
        Text("Kelpie tells each member who its podmates are. They message each other only when it matters.")
      }
      .headerProminence(.increased)
      Section("Sessions") {
        if store.candidates.isEmpty {
          Text("No agent sessions are running.")
            .foregroundStyle(.secondary)
        }
        ForEach(store.candidates) { candidate in
          PodCandidateRow(
            candidate: candidate,
            draft: store.drafts[id: candidate.id],
            onToggle: { store.send(.memberToggled(candidate.id)) },
            onNameChange: { store.send(.memberNameChanged(candidate.id, $0)) },
            onDescriptionChange: { store.send(.memberDescriptionChanged(candidate.id, $0)) }
          )
        }
      }
    }
    .formStyle(.grouped)
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      HStack {
        Text(store.isCreating ? "Pick at least two sessions and name each one." : "Name each session you add.")
          .appFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { store.send(.cancelTapped) }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")
        Button(store.isCreating ? "Create" : "Add") { store.send(.submitTapped) }
          .keyboardShortcut(.defaultAction)
          .disabled(!store.canSubmit)
          .help(store.isCreating ? "Create the pod and introduce its members (↩)" : "Add the sessions to the pod (↩)")
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 20)
    }
    .frame(minWidth: 520, minHeight: 480)
  }
}

/// One session: a checkbox, and once checked, its member name and description.
private struct PodCandidateRow: View {
  let candidate: PodStructure.Candidate
  let draft: PodMemberDraft?
  let onToggle: () -> Void
  let onNameChange: (String) -> Void
  let onDescriptionChange: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(isOn: Binding(get: { draft?.isSelected ?? false }, set: { _ in onToggle() })) {
        HStack(spacing: 8) {
          ForEach(candidate.agents, id: \.self) { agent in
            AgentBadgeView(agent: agent, size: 16, activity: candidate.activity ?? .idle)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(candidate.worktreeName)
            Text("\(candidate.repositoryName) · \(candidate.branchName)")
              .appFont(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(!candidate.isEligible)
      .help(candidate.disabledReason ?? "Add this session to the pod")
      if let draft, draft.isSelected {
        TextField(
          "Member name", text: Binding(get: { draft.name }, set: onNameChange), prompt: Text("Frontend agent"))
        TextField(
          "Member description", text: Binding(get: { draft.description }, set: onDescriptionChange),
          prompt: Text("Optional: what this agent works on"))
      }
    }
    .padding(.vertical, 2)
  }
}
