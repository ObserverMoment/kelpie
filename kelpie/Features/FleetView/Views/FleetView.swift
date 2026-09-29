import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// Full-window overview of every live agent session, grouped like the sidebar.
/// Mounted as an overlay over the split view so the terminals stay hosted; the
/// key monitor lives in `ContentView`, outside this conditionally mounted view.
struct FleetView: View {
  @Bindable var store: StoreOf<FleetViewFeature>
  let runtime: ContentRuntime

  private static let horizontalPadding: CGFloat = 32

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      header
      if store.structure.isEmpty {
        ContentUnavailableView(
          "No Active Agent Sessions",
          systemImage: "square.grid.2x2",
          description: Text("Launch an agent from the menu above, or start one in a terminal.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        sessions
      }
    }
    .padding(.horizontal, Self.horizontalPadding)
    .padding(.vertical, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(.windowBackground)
    .onGeometryChange(for: Int.self) { proxy in
      FleetViewNavigation.columnCount(forWidth: proxy.size.width - Self.horizontalPadding * 2)
    } action: { columnCount in
      store.send(.columnCountChanged(columnCount))
    }
    .accessibilityIdentifier("fleetView")
  }

  /// Title row above the launcher row: the title stays centred and the pickers
  /// never overlap it at narrow widths.
  private var header: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Fleet View")
        .appFont(.title, weight: .semibold)
        .frame(maxWidth: .infinity)
      HStack {
        FleetLauncherView(store: store)
        Spacer(minLength: 0)
      }
    }
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
