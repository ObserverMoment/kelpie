import ComposableArchitecture
import SwiftUI

/// Pods mode of the Fleet View overlay: one card per pod, and the New pod sheet.
struct PodsView: View {
  @Bindable var store: StoreOf<PodsFeature>
  let runtime: ContentRuntime

  /// The one glyph used by the toolbar, the Sidebar menu item, and the empty state.
  static let symbolName = "circle.hexagongrid"

  var body: some View {
    Group {
      if store.structure.pods.isEmpty {
        ContentUnavailableView {
          Label("No Pods", systemImage: Self.symbolName)
        } description: {
          Text("Group Claude Code sessions into a pod so each agent knows who it works with.")
        } actions: {
          Button("New Pod") { store.send(.newPodTapped) }
            .help("Create a pod from running Claude Code sessions")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { scrollProxy in
          ScrollView {
            // Not lazy: `scrollTo` has to resolve a member tile in a pod that is off screen.
            VStack(alignment: .leading, spacing: 20) {
              ForEach(store.structure.pods) { pod in
                PodCardView(
                  pod: pod,
                  columnCount: store.columnCount,
                  focusedMemberID: store.focusedMemberID,
                  onOpen: { store.send(.openTapped(pod.id)) },
                  onAddMembers: { store.send(.addMembersTapped(pod.id)) },
                  onDisband: { store.send(.disbandTapped(pod.id)) }
                )
              }
            }
            .padding(.bottom, 24)
          }
          .onGeometryChange(for: Int.self) { proxy in
            PodCardView.columnCount(forListWidth: proxy.size.width)
          } action: { columnCount in
            store.send(.columnCountChanged(columnCount))
          }
          .onChange(of: store.focusedMemberID) { _, focused in
            guard let focused else { return }
            withAnimation(.easeOut(duration: 0.15)) { scrollProxy.scrollTo(focused, anchor: nil) }
          }
        }
      }
    }
    .sheet(item: $store.scope(state: \.editor, action: \.editor)) { editorStore in
      PodEditorSheet(store: editorStore, runtime: runtime)
    }
  }
}
