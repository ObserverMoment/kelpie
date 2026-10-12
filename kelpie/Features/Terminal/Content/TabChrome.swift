import KelpieSettingsShared
import SwiftUI

/// Live, observable chrome a content contributes to its tab in the strip: an
/// accessory view next to the icon slot, activity for the shimmer, progress
/// for the stripe, and read-only input state. Owned by the content so
/// content-specific state never leaks into the layout reducer; the strip
/// reads it as an observable leaf, bounding invalidation to one tab.
@MainActor
protocol TabChrome: AnyObject {
  /// Accessory rendered before the title (agent badges for terminals).
  var accessory: AnyView? { get }
  /// Whether the tab's title should shimmer.
  var isWorking: Bool { get }
  /// Drives the top-of-tab progress stripe.
  var progress: TerminalTabProgressDisplay? { get }
  /// Whether the terminal refuses input (a completed blocking script's parked
  /// shell). The tab's own `isLocked` drives the visible lock marker.
  var isReadOnly: Bool { get }
  /// The title the content last reported, nil until it reports one (and nil for
  /// content kinds that never report one). Agent TUIs rewrite it several times a
  /// second, so it lives here rather than as a layout reducer action, and only
  /// one tab's label re-renders on a report.
  var reportedTitle: String? { get }
  /// A button the content adds to its pane's strip while its tab is selected.
  var stripAction: TabStripAction? { get }
}

extension TabChrome {
  var stripAction: TabStripAction? { nil }
}

/// A content-provided strip button; the strip renders it with the shortcut in
/// its tooltip and runs `perform` on click.
@MainActor
struct TabStripAction {
  let title: String
  let systemImage: String
  let shortcut: AppShortcut
  let perform: () -> Void
}

/// Resolves what a tab shows, and what the layout should persist for it, from
/// the layout's own title and the content's live reported title.
@MainActor
enum TabTitle {
  /// The title the record persists: the content's live report when it has one,
  /// else the layout's own. A locked tab owns its title (a shell report never
  /// reaches it), and the user override is excluded (it persists in its field).
  static func stored(for tab: TabItem, chrome: (any TabChrome)?) -> String {
    guard !tab.isLocked, let reported = chrome?.reportedTitle, !reported.isEmpty else {
      return tab.title
    }
    return reported
  }

  /// What the tab displays: a user override wins over the reported title.
  static func resolved(for tab: TabItem, chrome: (any TabChrome)?) -> String {
    tab.customTitle ?? stored(for: tab, chrome: chrome)
  }

  static func resolved(for tab: TabItem, runtime: ContentRuntime) -> String {
    resolved(for: tab, chrome: runtime.content(for: tab.content.id)?.chrome)
  }
}

/// Terminal chrome, written by the content host and the agent-presence
/// fan-out. Survives hibernation because the owning `TerminalContent` does.
@MainActor
@Observable
final class TerminalTabChrome: TabChrome {
  var agents: [AgentPresenceFeature.AgentInstance] = []
  var isWorking = false
  var progress: TerminalTabProgressDisplay?
  var isReadOnly = false
  var reportedTitle: String?

  /// Unread messages in the pane's mailbox; `MailboxFeature` owns the count.
  var unreadMail = 0
  /// The pane's mailbox holds at least one message, read or not.
  var hasMail = false
  /// Opens the pane's newest message; installed when the content is built.
  @ObservationIgnored var showLastMessage: (() -> Void)?

  var stripAction: TabStripAction? {
    guard hasMail, let showLastMessage else { return nil }
    return TabStripAction(
      title: "Show Last Agent Message", systemImage: "envelope.open",
      shortcut: AppShortcuts.showLastAgentMessage, perform: showLastMessage)
  }

  var accessory: AnyView? {
    guard !agents.isEmpty || unreadMail > 0 else { return nil }
    return AnyView(TerminalAgentBadgeAccessory(agents: agents, unreadMail: unreadMail).equatable())
  }
}

private struct TerminalAgentBadgeAccessory: View, Equatable {
  let agents: [AgentPresenceFeature.AgentInstance]
  let unreadMail: Int

  var body: some View {
    HStack(spacing: 4) {
      if unreadMail > 0 {
        Text(unreadMail, format: .number)
          .appFont(.caption2, weight: .semibold, monospaced: true)
          .padding(.horizontal, 4)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
          .help("\(unreadMail) unread in this pane's mailbox")
          .accessibilityLabel("\(unreadMail) unread messages")
      }
      if !agents.isEmpty {
        AgentAvatarGroupView(instances: agents, size: 14)
      }
    }
    .padding(.trailing, 2)
  }
}
