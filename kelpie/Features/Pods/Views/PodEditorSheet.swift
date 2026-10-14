import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// The New Pod / Add Members sheet. Each picked session needs a name; the
/// description is optional and goes into its podmates' roster.
struct PodEditorSheet: View {
  @Bindable var store: StoreOf<PodEditorFeature>
  let runtime: ContentRuntime

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
            title: TabTitle.resolved(for: candidate.tab, runtime: runtime),
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
        Text(footerHint)
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

  /// Names whatever still blocks the submit button.
  private var footerHint: String {
    if store.selectedDrafts.contains(where: { $0.trimmedName.isEmpty }) {
      return "Name each selected session."
    }
    return store.isCreating ? "Pick at least two sessions." : "Pick the sessions to add."
  }
}

/// One session: a checkbox, and once checked, its member name and description.
private struct PodCandidateRow: View {
  let candidate: PodStructure.Candidate
  let title: String
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
            Text(title)
              .lineLimit(1)
            HStack(spacing: 6) {
              Text("\(candidate.repositoryName) · \(candidate.branchName)")
              // Two sessions on one branch share every other line; the
              // surface id is what `kelpie pod register` names them by.
              Text(candidate.id.uuidString.prefix(8))
                .monospaced()
            }
            .appFont(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
      .disabled(!candidate.isEligible)
      .help(candidate.disabledReason ?? "Add this session to the pod")
      if let draft, draft.isSelected {
        TextField(
          "Member name", text: Binding(get: { draft.name }, set: { onNameChange($0) }), prompt: Text("Frontend agent"))
        TextField(
          "Member description", text: Binding(get: { draft.description }, set: { onDescriptionChange($0) }),
          prompt: Text("Optional: what this agent works on"))
      }
    }
    .padding(.vertical, 2)
  }
}
