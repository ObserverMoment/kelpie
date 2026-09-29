import KelpieSettingsShared
import SwiftUI

/// One agent session. Equatable on its card value and focus so a presence tick
/// on another card leaves this one alone; the live title is read off the
/// content's observable chrome.
struct FleetSessionCardView: View, Equatable {
  let card: FleetViewStructure.Card
  let isFocused: Bool
  let runtime: ContentRuntime
  let onOpen: () -> Void

  private static let cornerRadius: CGFloat = 12

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.card == rhs.card && lhs.isFocused == rhs.isFocused
  }

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: 10) {
        agentRow
        Divider()
        locationRow
        Text(title)
          .appFont(.body, weight: .medium)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let lastMessage = card.lastMessage {
          Text(lastMessage)
            .appFont(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
      .overlay {
        RoundedRectangle(cornerRadius: Self.cornerRadius)
          .strokeBorder(
            isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .separatorColor)),
            lineWidth: isFocused ? 2 : 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
    .buttonStyle(.plain)
    .help("Open this session (Return)")
    .accessibilityIdentifier("fleetCard-\(card.surfaceID.uuidString)")
    .accessibilityAddTraits(isFocused ? .isSelected : [])
  }

  private var agentRow: some View {
    HStack(alignment: .top, spacing: 10) {
      AgentBadgeView(agent: card.agent, size: 24, activity: card.activity)
      VStack(alignment: .leading, spacing: 2) {
        Text(card.agent.displayName)
          .appFont(.headline)
        Text(card.activity.fleetLabel)
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if card.model != nil || card.effort != nil {
        VStack(alignment: .trailing, spacing: 2) {
          if let model = card.model {
            Text(model)
              .appFont(.caption, monospaced: true)
              .lineLimit(1)
          }
          if let effort = card.effort {
            Text("\(effort.capitalized) effort")
              .appFont(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var locationRow: some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(card.isFolder ? card.repositoryName : "\(card.repositoryName) · \(card.branchName)")
          .appFont(.subheadline, weight: .medium)
          .lineLimit(1)
        Text(card.workingDirectoryPath)
          .appFont(.caption, monospaced: true)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    } icon: {
      Image(systemName: card.isFolder ? "folder" : "arrow.triangle.branch")
        .foregroundStyle(.secondary)
    }
  }

  /// Exactly what the tab strip shows for this tab.
  private var title: String {
    TabTitle.resolved(for: card.tab, chrome: runtime.content(for: ContentID(rawValue: card.surfaceID))?.chrome)
  }
}

extension AgentPresenceFeature.Activity {
  var fleetLabel: String {
    switch self {
    case .busy: "Working"
    case .idle: "Idle"
    case .awaitingInput: "Needs input"
    case .error: "Stopped on an error"
    case .compacting: "Compacting context"
    }
  }
}
