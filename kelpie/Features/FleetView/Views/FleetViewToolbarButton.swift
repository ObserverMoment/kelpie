import ComposableArchitecture
import KelpieSettingsShared
import Sharing
import SwiftUI

/// Window-toolbar toggle for Fleet View, beside the sidebar toggle.
struct FleetViewToolbarButton: View {
  let store: StoreOf<AppFeature>
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.toggleFleetView, overrides: settingsFile.global.shortcutOverrides)
    Button {
      store.send(.fleetView(.toggle))
    } label: {
      Label("Fleet View", systemImage: FleetView.symbolName)
        .symbolVariant(store.fleetView.isPresented ? .fill : .none)
    }
    .help("Fleet View: every active agent session at a glance (\(shortcut))")
    .accessibilityIdentifier("fleetViewToolbarButton")
  }
}
