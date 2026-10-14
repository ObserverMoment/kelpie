import ComposableArchitecture
import KelpieSettingsShared
import Sharing
import SwiftUI

/// Window-toolbar switch between the full-window views: Fleet, Pods, Mailbox and
/// Home (the sidebar and terminals). The showing view's glyph is filled.
struct ViewSwitcherToolbarControl: View {
  let store: StoreOf<AppFeature>
  @Shared(.settingsFile) private var settingsFile
  @Environment(\.controlActiveState) private var controlActiveState

  static let homeSymbolName = "terminal"

  var body: some View {
    let overrides = settingsFile.global.shortcutOverrides
    let fleet = store.fleetView
    let showsFleet = fleet.isPresented && fleet.mode == .fleet
    let showsPods = fleet.isPresented && fleet.mode != .fleet && fleet.mode != .mailbox
    let showsMailbox = fleet.isPresented && fleet.mode == .mailbox
    let unreadMail = store.mailbox.unreadCount
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
        store.send(.fleetView(.toggleMailbox))
      } label: {
        Group {
          if unreadMail > 0 {
            // Palette keeps the badge dot orange, like the notifications bell.
            Label("Mailbox", systemImage: "envelope.badge")
              .symbolRenderingMode(.palette)
              .foregroundStyle(.orange, envelopeBodyStyle)
          } else {
            Label("Mailbox", systemImage: MailboxView.symbolName)
          }
        }
        .symbolVariant(showsMailbox ? .fill : .none)
      }
      .help(
        "Mailbox: messages from your agent sessions, \(unreadMail) unread "
          + "(\(Self.shortcut(AppShortcuts.toggleMailboxView, overrides)))"
      )
      .accessibilityIdentifier("mailboxViewToolbarButton")
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

  // Envelope body for the unread `envelope.badge` variant: palette can't inherit
  // the automatic window-key dim, so it drops to secondary by hand when the
  // window isn't key, matching the notifications bell.
  private var envelopeBodyStyle: AnyShapeStyle {
    controlActiveState == .key ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
  }

  private static func shortcut(_ shortcut: AppShortcut, _ overrides: [AppShortcutID: AppShortcutOverride]) -> String {
    WorktreeDetailView.resolveShortcutDisplay(for: shortcut, overrides: overrides)
  }
}
