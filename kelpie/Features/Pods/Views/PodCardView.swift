import KelpieSettingsShared
import SwiftUI

/// One pod: its name and description, actions, and a subcard per member.
struct PodCardView: View {
  let pod: PodStructure.PodCard
  let onOpen: () -> Void
  let onAddMembers: () -> Void
  let onDisband: () -> Void

  @State private var isConfirmingDisband = false

  private static let cornerRadius: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
        ForEach(pod.members) { member in
          PodMemberCardView(member: member)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
    .overlay {
      RoundedRectangle(cornerRadius: Self.cornerRadius)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .confirmationDialog("Disband \"\(pod.name)\"?", isPresented: $isConfirmingDisband) {
      Button("Disband", role: .destructive, action: onDisband)
    } message: {
      Text("Each member is told the pod is gone and to stop messaging its podmates.")
    }
    .accessibilityIdentifier("podCard-\(pod.id.rawValue.uuidString)")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(pod.name)
          .appFont(.title3, weight: .semibold)
        if !pod.description.isEmpty {
          Text(pod.description)
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      Button("Open", systemImage: "rectangle.split.3x1", action: onOpen)
        .help("Show every member side by side")
      Button("Add Members", systemImage: "person.badge.plus", action: onAddMembers)
        .help("Add running Claude Code sessions to this pod")
      Button("Disband", systemImage: "xmark.circle", role: .destructive) {
        isConfirmingDisband = true
      }
      .help("Disband the pod and tell its members")
    }
  }
}

/// One member: its pod name and description, where it runs, and whether it
/// has registered its messaging name.
private struct PodMemberCardView: View {
  let member: PodStructure.MemberCard

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        AgentBadgeView(agent: .claude, size: 18, activity: member.activity ?? .idle)
        Text(member.name)
          .appFont(.headline)
          .lineLimit(1)
      }
      if !member.description.isEmpty {
        Text(member.description)
          .appFont(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      if let worktreeName = member.worktreeName {
        Label(worktreeName, systemImage: "arrow.triangle.branch")
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      HStack(spacing: 6) {
        registration
        if let activity = member.activity {
          Text("· \(activity.fleetLabel)")
            .appFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private var registration: some View {
    switch member.registration {
    case .pending:
      Label("Registering", systemImage: "hourglass")
        .appFont(.caption)
        .foregroundStyle(.secondary)
        .help("Waiting for the agent to report its session name")
    case .registered(let sessionName):
      Text(sessionName)
        .appFont(.caption, monospaced: true)
        .help("The name podmates message this agent by")
    case .unreachable:
      Label("Unreachable", systemImage: "exclamationmark.triangle")
        .appFont(.caption)
        .foregroundStyle(.orange)
        .help("The agent never reported its session name, so podmates can't message it")
    }
  }
}
