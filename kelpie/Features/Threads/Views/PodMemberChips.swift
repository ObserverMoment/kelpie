import KelpieSettingsShared
import SwiftUI

/// One chip per pod member, each carrying the member's own summary. A chip is
/// a filter: off, and that member's messages leave the pod thread.
struct PodMemberChips: View {
  let members: [ThreadsStructure.Row]
  let visibleIDs: Set<UUID>
  let onToggle: (UUID) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .top, spacing: 8) {
        ForEach(members) { member in
          PodMemberChip(member: member, isVisible: visibleIDs.contains(member.id)) {
            onToggle(member.id)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
    }
    .scrollIndicators(.hidden)
    .accessibilityIdentifier("podMemberChips")
  }
}

private struct PodMemberChip: View {
  let member: ThreadsStructure.Row
  let isVisible: Bool
  let onToggle: () -> Void

  /// Wide enough for two lines of summary without the row turning into a wall.
  private static let chipWidth: CGFloat = 220
  private static let hiddenOpacity = 0.55

  private var name: String { member.memberName ?? member.worktreeName }

  var body: some View {
    Button(action: onToggle) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(name)
            .appFont(.caption, weight: .semibold)
            .lineLimit(1)
          if member.unreadCount > 0 {
            Text(member.unreadCount, format: .number)
              .appFont(.caption2, weight: .semibold, monospaced: true)
              .foregroundStyle(.secondary)
              .accessibilityLabel("\(member.unreadCount) unread")
          }
        }
        Text(member.summary ?? "No summary yet")
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
      }
      .frame(width: Self.chipWidth, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.bordered)
    .tint(isVisible ? .accentColor : .secondary)
    .opacity(isVisible ? 1 : Self.hiddenOpacity)
    .help(
      member.summary.map { "\($0)\n\nClick to \(isVisible ? "hide" : "show") \(name)'s messages" }
        ?? "Click to \(isVisible ? "hide" : "show") \(name)'s messages"
    )
    .accessibilityLabel(name)
    .accessibilityValue(isVisible ? "Shown" : "Hidden")
  }
}
