import ComposableArchitecture
import KelpieSettingsShared
import Sharing
import SwiftUI

/// Window-toolbar switch between the three full-window views: Fleet, Pods, and
/// Home (the sidebar and terminals). The showing view's glyph is filled.
struct ViewSwitcherToolbarControl: View {
  let store: StoreOf<AppFeature>
  @Shared(.settingsFile) private var settingsFile

  static let homeSymbolName = "terminal"

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    let fleet = store.fleetView
    let showsFleet = fleet.isPresented && fleet.mode == .fleet
    let showsPods = fleet.isPresented && fleet.mode != .fleet
    ControlGroup {
      Button {
        store.send(.fleetView(.toggle))
      } label: {
        Label("Fleet View", systemImage: FleetView.symbolName)
          .symbolVariant(showsFleet ? .fill : .none)
      }
      .help(
        "Fleet View: every active agent session at a glance (\(Self.shortcut(AppShortcuts.toggleFleetView, overrides)))"
      )
      .accessibilityIdentifier("fleetViewToolbarButton")
      Button {
        store.send(.fleetView(.togglePods))
      } label: {
        Label("Pods", systemImage: PodsView.symbolName)
          .symbolVariant(showsPods ? .fill : .none)
      }
      .help("Pods: your agent pods and their members (\(Self.shortcut(AppShortcuts.togglePodsView, overrides)))")
      .accessibilityIdentifier("podsViewToolbarButton")
      Button {
        store.send(.fleetView(.dismiss))
      } label: {
        Label("Home", systemImage: Self.homeSymbolName)
          .symbolVariant(fleet.isPresented ? .none : .fill)
      }
      .help("Home: the sidebar and terminals (\(Self.shortcut(AppShortcuts.showStandardView, overrides)))")
      .accessibilityIdentifier("homeViewToolbarButton")
    }
  }

  private static func shortcut(_ shortcut: AppShortcut, _ overrides: [AppShortcutID: AppShortcutOverride]) -> String {
    WorktreeDetailView.resolveShortcutDisplay(for: shortcut, overrides: overrides)
  }
}
