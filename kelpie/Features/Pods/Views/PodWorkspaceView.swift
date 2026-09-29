import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// One pod's members side by side, full window, each its real interactive
/// terminal. Mounting a member here claims its surface; the member's layout
/// reclaims it when it remounts after the workspace closes.
struct PodWorkspaceView: View {
  let podsStore: StoreOf<PodsFeature>
  let terminalsStore: StoreOf<TerminalsFeature>
  let podID: PodID
  let runtime: ContentRuntime
  let onBack: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let pod = podsStore.pods[id: podID] {
        HStack(spacing: 0) {
          ForEach(Array(pod.members.enumerated()), id: \.element.id) { index, member in
            if index > 0 {
              Divider()
            }
            memberPane(member)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.windowBackground)
    .accessibilityIdentifier("podWorkspace")
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Button("Pods", systemImage: "chevron.left", action: onBack)
        .help("Back to Pods")
      VStack(alignment: .leading, spacing: 2) {
        Text(podsStore.pods[id: podID]?.name ?? "")
          .appFont(.title3, weight: .semibold)
        if let description = podsStore.pods[id: podID]?.description, !description.isEmpty {
          Text(description)
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  @ViewBuilder
  private func memberPane(_ member: PodMember) -> some View {
    let contentID = ContentID(rawValue: member.id)
    let layout = terminalsStore.layouts[id: member.worktreeID]
    // The epoch read re-runs this when the member's surface wakes.
    let epoch = layout?.renderEpoch ?? 0
    let isWindowed =
      layout.flatMap { $0.layout.tab(containingContent: contentID) }
      .map { layout?.windowedPaneIDs.contains($0.pane.id) == true } ?? false
    VStack(spacing: 0) {
      Text(member.name)
        .appFont(.subheadline, weight: .medium)
        .lineLimit(1)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
      if isWindowed {
        ContentUnavailableView(
          "In Separate Window", systemImage: "macwindow.on.rectangle",
          description: Text("This member's pane is open in its own window."))
      } else if runtime.renderer(for: contentID) != nil {
        ContentHostView(contentID: contentID, runtime: runtime, epoch: epoch)
      } else {
        ContentUnavailableView(
          "Session Not Running", systemImage: "terminal",
          description: Text("This member's terminal is not live."))
      }
    }
  }
}
