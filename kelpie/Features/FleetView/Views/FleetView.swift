import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// Full-window overview of every live agent session, grouped like the sidebar,
/// or of the agent pods, or one pod's workspace. Mounted as an overlay over the
/// split view so the terminals stay hosted; the key monitor lives in
/// `ContentView`, outside this conditionally mounted view.
struct FleetView: View {
  @Bindable var store: StoreOf<FleetViewFeature>
  let podsStore: StoreOf<PodsFeature>
  let terminalsStore: StoreOf<TerminalsFeature>
  let runtime: ContentRuntime

  private static let horizontalPadding: CGFloat = 32

  /// The one glyph used by the header, the toolbar button and the Sidebar menu item.
  static let symbolName = "square.grid.2x2"

  var body: some View {
    if case .podWorkspace(let podID) = store.mode {
      PodWorkspaceView(
        podsStore: podsStore, terminalsStore: terminalsStore, podID: podID, runtime: runtime
      ) {
        store.send(.modeChanged(.pods))
      }
    } else {
      overview
    }
  }

  private var overview: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      Group {
        if store.mode == .pods {
          PodsView(store: podsStore)
        } else if store.structure.isEmpty {
          ContentUnavailableView(
            "No Active Agent Sessions",
            systemImage: Self.symbolName,
            description: Text("Launch an agent from the menu above, or start one in a terminal.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          sessions
        }
      }
      .padding(.horizontal, Self.horizontalPadding)
      .padding(.top, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.windowBackground)
    .onGeometryChange(for: Int.self) { proxy in
      FleetViewNavigation.columnCount(forWidth: proxy.size.width - Self.horizontalPadding * 2)
    } action: { columnCount in
      store.send(.columnCountChanged(columnCount))
    }
    .accessibilityIdentifier("fleetView")
  }

  /// Title row above the launcher row, both left-aligned on a band that reads
  /// as chrome (control background) against the window background below, so
  /// the header is visibly separate and the pickers never overlap the title.
  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 16) {
        Label {
          Text(store.mode == .pods ? "Pods" : "Fleet View")
        } icon: {
          Image(systemName: store.mode == .pods ? PodsView.symbolName : Self.symbolName)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .appFont(.title, weight: .semibold)
        Spacer(minLength: 0)
        Picker("View", selection: Binding(get: { store.mode }, set: { store.send(.modeChanged($0)) })) {
          Label("Fleet", systemImage: Self.symbolName).tag(FleetViewFeature.Mode.fleet)
          Label("Pods", systemImage: PodsView.symbolName).tag(FleetViewFeature.Mode.pods)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Switch between Fleet View and Pods")
      }
      HStack {
        if store.mode == .pods {
          Button("New Pod", systemImage: "plus") { podsStore.send(.newPodTapped) }
            .help("Create a pod from running Claude Code sessions")
        } else {
          FleetLauncherView(store: store)
        }
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.vertical, 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var sessions: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          ForEach(store.structure.sections) { section in
            FleetSectionView(
              section: section,
              columnCount: store.columnCount,
              focusedCardID: store.focusedCardID,
              runtime: runtime
            ) { store.send(.cardTapped($0)) }
          }
        }
        .padding(.bottom, 24)
      }
      .onChange(of: store.focusedCardID) { _, focused in
        guard let focused else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(focused, anchor: nil) }
      }
    }
  }
}

/// One titled section: cards wrapped into rows of `columnCount`, every cell the
/// same width so a short last row does not stretch its cards.
private struct FleetSectionView: View {
  let section: FleetViewStructure.Section
  let columnCount: Int
  let focusedCardID: FleetCardID?
  let runtime: ContentRuntime
  let onTap: (FleetCardID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title = section.title {
        Text(title)
          .appFont(.title3, weight: .semibold)
          .foregroundStyle(.secondary)
      }
      ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
        HStack(alignment: .top, spacing: FleetViewNavigation.cardSpacing) {
          ForEach(row) { card in
            FleetSessionCardView(card: card, isFocused: card.id == focusedCardID, runtime: runtime) {
              onTap(card.id)
            }
            .equatable()
            .frame(maxWidth: .infinity)
            .id(card.id)
          }
          ForEach(0..<(columnCount - row.count), id: \.self) { _ in
            Color.clear.frame(maxWidth: .infinity)
          }
        }
      }
    }
  }

  private var rows: [[FleetViewStructure.Card]] {
    let columns = max(1, columnCount)
    return stride(from: 0, to: section.cards.count, by: columns).map {
      Array(section.cards[$0..<min($0 + columns, section.cards.count)])
    }
  }
}
