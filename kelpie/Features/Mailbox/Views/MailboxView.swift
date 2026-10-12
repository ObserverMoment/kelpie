import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI
import Textual

/// Full-window inbox: the sessions with mail on the left, the selected
/// session's messages on the right, and a message opened full-window as
/// rendered markdown. Hosted by `FleetView` in its `.mailbox` mode.
struct MailboxView: View {
  @Bindable var store: StoreOf<MailboxFeature>
  let runtime: ContentRuntime

  /// The one glyph used by the header, the toolbar button and the menu item.
  static let symbolName = "envelope"
  static let sessionListWidth: CGFloat = 280

  var body: some View {
    if let message = store.openMessage, let row = store.selectedRow {
      MailMessageViewer(
        message: message, title: Self.title(for: row, runtime: runtime), returnsToPane: store.viewerReturnsToPane
      ) {
        store.send(.viewerClosed)
      } onDone: {
        store.send(.markDone(message.id))
      } onReply: {
        store.send(.replyTapped(message.id))
      }
    } else if store.structure.rows.isEmpty {
      ContentUnavailableView(
        "No Mail",
        systemImage: Self.symbolName,
        description: Text("Messages agents finish a turn with land here, one inbox per session.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HStack(spacing: 0) {
        sessionList
          .frame(width: Self.sessionListWidth)
        Divider()
        messages
      }
    }
  }

  private var sessionList: some View {
    List(store.structure.rows, selection: $store.selectedSurfaceID.sending(\.sessionSelected)) { row in
      MailboxSessionRow(row: row, title: Self.title(for: row, runtime: runtime))
        .tag(row.id)
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("mailboxSessionList")
  }

  @ViewBuilder
  private var messages: some View {
    if let box = store.selectedBox, let row = store.selectedRow {
      VStack(spacing: 0) {
        if row.isStale {
          staleBanner(surfaceID: row.id)
          Divider()
        }
        if box.messages.isEmpty {
          ContentUnavailableView(
            "Inbox Empty", systemImage: "tray",
            description: Text("Every message from this session is done.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollViewReader { proxy in
            ScrollView {
              LazyVStack(spacing: 0) {
                ForEach(box.messages) { message in
                  MailMessageRow(message: message, isFocused: message.id == store.focusedMessageID) {
                    store.send(.messageOpened(message.id))
                  } onDone: {
                    store.send(.markDone(message.id))
                  } onReply: {
                    store.send(.replyTapped(message.id))
                  }
                  .id(message.id)
                  Divider()
                }
              }
            }
            .onChange(of: store.focusedMessageID, initial: true) { _, focused in
              if let focused { proxy.scrollTo(focused) }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView("Select a Session", systemImage: Self.symbolName)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func staleBanner(surfaceID: UUID) -> some View {
    HStack {
      Label("No agent is running in this session any more.", systemImage: "moon.zzz")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Close Stale Mailbox", systemImage: "xmark.bin") {
        store.send(.closeStaleMailbox(surfaceID))
      }
      .help("Close this mailbox and discard its messages")
    }
    .appFont(.callout)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  /// The tab title the strip shows, else the worktree name.
  static func title(for row: MailboxStructure.Row, runtime: ContentRuntime) -> String {
    guard let tab = row.tab else { return row.worktreeName }
    let title = TabTitle.resolved(for: tab, runtime: runtime)
    return title.isEmpty ? row.worktreeName : title
  }
}

private struct MailboxSessionRow: View {
  let row: MailboxStructure.Row
  let title: String

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .appFont(.body, weight: row.unreadCount > 0 ? .semibold : .regular)
          .lineLimit(1)
        Text(subtitle)
          .appFont(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      if row.isStale {
        Image(systemName: "moon.zzz")
          .foregroundStyle(.secondary)
          .help("No agent is running in this session any more")
          .accessibilityLabel("Stale")
      }
      if row.unreadCount > 0 {
        Text(row.unreadCount, format: .number)
          .appFont(.caption, weight: .semibold, monospaced: true)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.tint, in: Capsule())
          .foregroundStyle(.white)
          .accessibilityLabel("\(row.unreadCount) unread")
      }
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    [row.repositoryName, row.worktreeName].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

private struct MailMessageRow: View {
  let message: MailMessage
  /// The arrow keys are on this row.
  let isFocused: Bool
  let onOpen: () -> Void
  let onDone: () -> Void
  let onReply: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if !message.isRead {
              Circle()
                .fill(.tint)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Unread")
            }
            Text(message.createdAt, format: .dateTime.hour().minute())
              .appFont(.caption)
              .foregroundStyle(.secondary)
            if message.isReplying {
              Label("Replying", systemImage: "arrowshape.turn.up.left")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Text(message.body)
            .appFont(.body, monospaced: true)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open this message (Return)")
      .accessibilityIdentifier("mailMessageOpen")
      HStack(spacing: 4) {
        Button("Done", systemImage: "checkmark", action: onDone)
          .help("Mark as done and remove from the inbox")
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
          .help("Reply in the session with this message quoted")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 12)
    .overlay {
      if isFocused { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
    }
    .accessibilityAddTraits(isFocused ? .isSelected : [])
  }
}

/// One message, full window, as rendered markdown.
private struct MailMessageViewer: View {
  let message: MailMessage
  let title: String
  /// Opened from the pane, so closing goes back there rather than the inbox.
  let returnsToPane: Bool
  let onClose: () -> Void
  let onDone: () -> Void
  let onReply: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        if returnsToPane {
          Button("Close", systemImage: "xmark", action: onClose)
            .help("Close and return to the pane (Esc)")
        } else {
          Button("Back", systemImage: "chevron.left", action: onClose)
            .help("Back to the inbox")
        }
        Text(title)
          .appFont(.headline)
          .lineLimit(1)
        Text(message.createdAt, format: .dateTime.hour().minute())
          .appFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Done", systemImage: "checkmark", action: onDone)
          .help("Mark as done and remove from the inbox")
        Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
          .help("Reply in the session with this message quoted")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .background(Color(nsColor: .controlBackgroundColor))
      Divider()
      ScrollView {
        StructuredText(markdown: message.body)
          .textual.structuredTextStyle(.gitHub)
          .textual.textSelection(.enabled)
          .frame(maxWidth: 820, alignment: .leading)
          .padding(.horizontal, 32)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity, alignment: .center)
      }
    }
    .accessibilityIdentifier("mailMessageViewer")
  }
}
