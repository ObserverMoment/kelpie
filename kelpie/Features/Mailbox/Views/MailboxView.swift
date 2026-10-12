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
        message: message, title: Self.title(for: row, runtime: runtime), returnsToPane: store.viewerReturnsToPane,
        isReadingAloud: store.isReadingAloud
      ) {
        store.send(.viewerClosed)
      } onDone: {
        store.send(.markDone(message.id))
      } onReadAloud: {
        store.send(.readAloudToggled(message.id))
      } onSend: { text in
        store.send(.replySent(message.id, text: text))
      }
      // A draft belongs to its message.
      .id(message.id)
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

/// One message, full window, as rendered markdown, with a reply box docked
/// below it.
private struct MailMessageViewer: View {
  let message: MailMessage
  let title: String
  /// Opened from the pane, so closing goes back there rather than the inbox.
  let returnsToPane: Bool
  let isReadingAloud: Bool
  let onClose: () -> Void
  let onDone: () -> Void
  let onReadAloud: () -> Void
  let onSend: (String) -> Void
  @Shared(.settingsFile) private var settingsFile
  @State private var draft = ""
  @FocusState private var isReplyFocused: Bool

  /// Shared by the message and the reply box so they line up.
  private static let columnWidth: CGFloat = 820
  private static let columnPadding: CGFloat = 32

  private var isDraftBlank: Bool { draft.allSatisfy(\.isWhitespace) }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        // Escape lands here even while the reply box has focus.
        if returnsToPane {
          Button("Close", systemImage: "xmark", action: onClose)
            .keyboardShortcut(.cancelAction)
            .help("Close and return to the pane (Esc)")
        } else {
          Button("Back", systemImage: "chevron.left", action: onClose)
            .keyboardShortcut(.cancelAction)
            .help("Back to the inbox (Esc)")
        }
        Text(title)
          .appFont(.headline)
          .lineLimit(1)
        Text(message.createdAt, format: .dateTime.hour().minute())
          .appFont(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(
          isReadingAloud ? "Stop Reading" : "Read Aloud",
          systemImage: isReadingAloud ? "stop.circle" : "speaker.wave.2",
          action: onReadAloud
        )
        .help("Read this message aloud, or stop (\(readAloudShortcut))")
        Button("Done", systemImage: "checkmark", action: onDone)
          .keyboardShortcut(.return, modifiers: [.command, .option])
          .help("Mark as done and remove from the inbox (⌥⌘↩)")
      }
      .buttonStyle(.borderless)
      .appFont(.body)
      .padding(.horizontal, 20)
      .padding(.vertical, 10)
      .background(Color(nsColor: .controlBackgroundColor))
      Divider()
      ScrollView {
        StructuredText(markdown: message.body)
          .textual.structuredTextStyle(.gitHub)
          // Textual sizes headings and code from the environment font.
          .appFont(.body)
          .textual.textSelection(.enabled)
          .frame(maxWidth: Self.columnWidth, alignment: .leading)
          .padding(.horizontal, Self.columnPadding)
          .padding(.vertical, 24)
          .frame(maxWidth: .infinity, alignment: .center)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        replyBox
      }
    }
    .accessibilityIdentifier("mailMessageViewer")
    .onAppear { isReplyFocused = true }
  }

  private var replyBox: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Reply to the agent", text: $draft, axis: .vertical)
          .lineLimit(3...10)
          .textFieldStyle(.roundedBorder)
          .appFont(.body)
          .focused($isReplyFocused)
          .onSubmit(send)
          .help("Reply to the agent: Return sends and marks done, ⌥Return adds a line")
          .accessibilityIdentifier("mailReplyField")
        Button("Send", systemImage: "arrow.up.circle.fill", action: send)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .appFont(.title2)
          .disabled(isDraftBlank)
          .help("Send the reply and mark the message done (Return)")
      }
      .frame(maxWidth: Self.columnWidth)
      .padding(.horizontal, Self.columnPadding)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var readAloudShortcut: String {
    WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.readLastAgentMessageAloud, overrides: settingsFile.global.shortcutOverrides)
  }

  private func send() {
    guard !isDraftBlank else { return }
    onSend(draft)
  }
}
