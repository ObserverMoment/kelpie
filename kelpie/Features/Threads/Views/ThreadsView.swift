import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI
import Textual

/// Full-window threads: the pods and sessions as tiles on the left, the
/// selected thread's summary and messages on the right, and a message opened
/// full-window as rendered markdown. Hosted by `FleetView` in its `.threads`
/// mode.
struct ThreadsView: View {
  @Bindable var store: StoreOf<ThreadsFeature>
  let runtime: ContentRuntime
  /// Mirrors the arrow-key column onto the list's first responder, so the
  /// selected tile dims to the unemphasized grey while the keys are on a message.
  @FocusState private var isTileListFocused: Bool
  /// Messages shown in full rather than clamped to a few lines.
  @State private var expandedMessageIDs: Set<MailMessage.ID> = []
  /// Files dropped on the thread's reply box.
  @State private var panelAttachments: [URL] = []

  /// The one glyph used by the header, the toolbar buttons and the menu item.
  static let symbolName = "bubble.left.and.bubble.right"
  /// The same glyph with mail in it, for an unread count.
  static let unreadSymbolName = "bubble.left.and.text.bubble.right"
  static let tileListWidth: CGFloat = 300

  var body: some View {
    if let message = store.openMessage, let row = store.openMessageRow {
      MailMessageViewer(
        message: message, row: row, runtime: runtime, returnsToPane: store.viewerReturnsToPane,
        isReadingAloud: store.isReadingAloud, isAgentRunning: !row.isStale
      ) {
        store.send(.viewerClosed)
      } onDone: {
        store.send(.markDone(message.id))
      } onReadAloud: {
        store.send(.readAloudToggled(message.id))
      } onSend: { text, attachments in
        store.send(.replySent(message.id, text: text, attachments: attachments))
      }
      // A draft belongs to its message.
      .id(message.id)
    } else if store.structure.tiles.isEmpty {
      ContentUnavailableView(
        "No Threads",
        systemImage: Self.symbolName,
        description: Text("Messages agents finish a turn with land here, one thread per session or pod.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      HStack(spacing: 0) {
        tiles
          .frame(width: Self.tileListWidth)
        Divider()
        messages
      }
    }
  }

  private var tiles: some View {
    List(selection: $store.selectedThreadID.sending(\.tileSelected)) {
      ForEach(store.structure.tiles) { tile in
        switch tile {
        case .pod(let pod):
          DisclosureGroup(
            isExpanded: Binding(
              get: { !store.collapsedPods.contains(pod.id) },
              set: { isExpanded in
                // Only a real change toggles: SwiftUI may write the current value back.
                if isExpanded == store.collapsedPods.contains(pod.id) { store.send(.podExpansionToggled(pod.id)) }
              })
          ) {
            ForEach(pod.members) { member in
              ThreadTile(row: member, runtime: runtime)
                .tag(ThreadID.session(member.id))
                .contextMenu { sessionMenu(for: member) }
            }
          } label: {
            PodTile(pod: pod)
          }
          .tag(ThreadID.pod(pod.id))
          .contextMenu {
            Button("Mark All Done", systemImage: "checkmark.circle") {
              store.send(.markAllDone(.pod(pod.id)))
            }
            .help("Mark every member's messages done")
          }
        case .session(let row):
          ThreadTile(row: row, runtime: runtime)
            .tag(ThreadID.session(row.id))
            .contextMenu { sessionMenu(for: row) }
        }
      }
    }
    .listStyle(.sidebar)
    // Outside a split view the sidebar material blends with the desktop behind
    // the window; drop it so the list sits on Fleet's window background.
    .scrollContentBackground(.hidden)
    .focused($isTileListFocused)
    .onChange(of: store.focusedMessageID == nil, initial: true) { _, isOnTiles in
      isTileListFocused = isOnTiles
    }
    // A click into the list takes the keys back from the messages.
    .onChange(of: isTileListFocused) { _, isFocused in
      if isFocused { store.send(.moveFocus(.left)) }
    }
    .accessibilityIdentifier("threadsTileList")
  }

  @ViewBuilder
  private func sessionMenu(for row: ThreadsStructure.Row) -> some View {
    Button("Mark All Done", systemImage: "checkmark.circle") {
      store.send(.markAllDone(.session(row.id)))
    }
    .help("Mark every message in this thread done")
    Button("Reply", systemImage: "arrowshape.turn.up.left") {
      store.send(.replyToLatest(surfaceID: row.id))
    }
    .help("Open the newest message with the reply box ready")
    .disabled(row.messageCount == 0 || row.isStale)
    Button("View", systemImage: "terminal") {
      store.send(.sessionViewRequested(surfaceID: row.id))
    }
    .help("Go to this session's terminal (Space)")
  }

  @ViewBuilder
  private var messages: some View {
    if store.displayedThreadID != nil {
      VStack(spacing: 0) {
        if let row = store.selectedRow, row.isStale {
          staleBanner(surfaceID: row.id)
          Divider()
        }
        if let pod = store.displayedPod {
          PodMemberChips(members: pod.members, visibleIDs: store.visibleMemberIDs) { surfaceID in
            store.send(.memberToggled(podID: pod.id, surfaceID: surfaceID))
          }
          Divider()
        }
        timeline
        ReplyBox(
          isAgentRunning: store.canReplyToDisplayed, attachments: $panelAttachments, focusesOnAppear: false,
          onFocusChange: { store.send(.panelReplyFocusChanged($0)) },
          onSend: { text, attachments in
            store.send(.threadReplySent(text: text, attachments: attachments))
            panelAttachments = []
          }
        )
        ThreadSummaryCard(summary: store.selectedSummary, isSummarizing: store.isSummarizingSelected)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ContentUnavailableView("Select a Thread", systemImage: Self.symbolName)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  /// Oldest at the top, newest at the bottom, and pinned to the bottom as
  /// messages arrive, like a chat.
  @ViewBuilder
  private var timeline: some View {
    let entries = store.timeline
    if entries.isEmpty {
      ContentUnavailableView(
        "Thread Empty", systemImage: "tray",
        description: Text("Every message here is done.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(entries) { entry in
              MessageTile(
                entry: entry,
                isFocused: entry.id == store.focusedMessageID,
                isExpanded: expandedMessageIDs.contains(entry.id)
              ) {
                expandedMessageIDs.formSymmetricDifference([entry.id])
              } onOpen: {
                store.send(.messageOpened(entry.id))
              } onDone: {
                store.send(.markDone(entry.id))
              }
              .id(entry.id)
            }
          }
          .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onChange(of: store.focusedMessageID) { _, focused in
          if let focused { proxy.scrollTo(focused) }
        }
      }
    }
  }

  private func staleBanner(surfaceID: UUID) -> some View {
    HStack {
      Label("No agent is running in this session any more.", systemImage: "moon.zzz")
        .foregroundStyle(.secondary)
      Spacer()
      Button("Close Stale Thread", systemImage: "xmark.bin") {
        store.send(.closeStaleThread(surfaceID))
      }
      .help("Close this thread and discard its messages")
    }
    .appFont(.callout)
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  /// The tab title the strip shows, else the worktree name.
  static func title(for row: ThreadsStructure.Row, runtime: ContentRuntime) -> String {
    guard let tab = row.tab else { return row.worktreeName }
    let title = TabTitle.resolved(for: tab, runtime: runtime)
    return title.isEmpty ? row.worktreeName : title
  }
}

/// A pod's tile: name, member count and unread total. Its member tiles sit
/// under it in the disclosure.
private struct PodTile: View {
  let pod: ThreadsStructure.PodRow

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Label(pod.name, systemImage: PodsView.symbolName)
          .appFont(.body, weight: pod.unreadCount > 0 ? .semibold : .regular)
          .lineLimit(1)
        Text("^[\(pod.members.count) member](inflect: true)")
          .appFont(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      UnreadBadge(count: pod.unreadCount)
    }
    .padding(.vertical, 2)
    .help("The pod's thread: every member's messages, with one summary for the pod")
  }
}

/// A session's tile, on its own or under its pod: title, where it runs, its
/// summary, and the unread count. It resolves the live tab title itself, so a
/// title report from one session re-renders this leaf and not the whole view.
private struct ThreadTile: View {
  let row: ThreadsStructure.Row
  let runtime: ContentRuntime

  private var title: String { row.memberName ?? ThreadsView.title(for: row, runtime: runtime) }

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
        if let summary = row.summary {
          Text(summary)
            .appFont(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if row.isStale {
        Image(systemName: "moon.zzz")
          .foregroundStyle(.secondary)
          .help("No agent is running in this session any more")
          .accessibilityLabel("Stale")
      }
      UnreadBadge(count: row.unreadCount)
    }
    .padding(.vertical, 2)
    .help("This session's thread. Space opens its terminal.")
  }

  private var subtitle: String {
    [row.repositoryName, row.worktreeName].filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

private struct UnreadBadge: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text(count, format: .number)
        .appFont(.caption, weight: .semibold, monospaced: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint, in: Capsule())
        .foregroundStyle(.white)
        .accessibilityLabel("\(count) unread")
    }
  }
}

/// One message on the timeline, Slack-style: who, when, and the body as
/// markdown, clamped to a few lines until expanded.
private struct MessageTile: View {
  let entry: ThreadsFeature.TimelineEntry
  /// The arrow keys are on this message.
  let isFocused: Bool
  let isExpanded: Bool
  let onToggleExpanded: () -> Void
  let onOpen: () -> Void
  let onDone: () -> Void
  /// About four lines of body text.
  @ScaledMetric(relativeTo: .body) private var collapsedHeight: CGFloat = 92

  /// A body past either of these does not fit the clamp, so it gets a Show more.
  private static let longBodyCharacterCount = 320
  private static let longBodyLineBreakCount = 4
  private static let authorGlyphWidth: CGFloat = 28

  private var message: MailMessage { entry.message }
  private var isUser: Bool { message.author == .user }

  private var isLong: Bool {
    message.body.count > Self.longBodyCharacterCount
      || message.body.filter(\.isNewline).count >= Self.longBodyLineBreakCount
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: isUser ? "person.crop.circle.fill" : "cpu")
        .appFont(.title2)
        .foregroundStyle(isUser ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .frame(width: Self.authorGlyphWidth)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(entry.authorName)
            .appFont(.body, weight: .semibold)
          Text(message.createdAt, format: .dateTime.hour().minute())
            .appFont(.caption)
            .foregroundStyle(.secondary)
          if !message.isRead {
            Circle()
              .fill(.tint)
              .frame(width: 8, height: 8)
              .accessibilityLabel("Unread")
          }
          Spacer(minLength: 0)
          if !isUser {
            Button("Done", systemImage: "checkmark", action: onDone)
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
              .help("Mark as done and remove from the thread (⌃⌘↩)")
          }
        }
        StructuredText(markdown: message.body)
          .textual.structuredTextStyle(.gitHub)
          .appFont(.body)
          .textual.textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(maxHeight: isExpanded ? nil : collapsedHeight, alignment: .top)
          .clipped()
        if isLong {
          Button(isExpanded ? "Show less" : "Show more", action: onToggleExpanded)
            .buttonStyle(.link)
            .appFont(.caption)
            .help(isExpanded ? "Clamp this message back to a few lines" : "Show the whole message")
        }
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Open", systemImage: "arrow.up.left.and.arrow.down.right", action: onOpen)
        .help("Show this message full-window with a reply box (Return)")
      if !isUser {
        Button("Done", systemImage: "checkmark", action: onDone)
          .help("Mark as done and remove from the thread (⌃⌘↩)")
      }
    }
    .overlay {
      if isFocused { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
    }
    .accessibilityAddTraits(isFocused ? .isSelected : [])
    .accessibilityIdentifier("threadMessage")
  }
}

/// One message, full window, as rendered markdown, with a reply box docked
/// below it.
private struct MailMessageViewer: View {
  let message: MailMessage
  /// The message's session; the header resolves its live title here so only
  /// the viewer tracks that session's chrome.
  let row: ThreadsStructure.Row
  let runtime: ContentRuntime
  /// Opened from the pane, so closing goes back there rather than the inbox.
  let returnsToPane: Bool
  let isReadingAloud: Bool
  let isAgentRunning: Bool
  let onClose: () -> Void
  let onDone: () -> Void
  let onReadAloud: () -> Void
  let onSend: (String, [URL]) -> Void
  @Shared(.settingsFile) private var settingsFile
  @State private var attachments: [URL] = []
  @State private var isDropTargeted = false

  /// Shared by the message and the reply box so they line up.
  fileprivate static let columnWidth: CGFloat = 820
  fileprivate static let columnPadding: CGFloat = 32
  fileprivate static let replyBoxCornerRadius: CGFloat = 8

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
        Text(ThreadsView.title(for: row, runtime: runtime))
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
          .keyboardShortcut(.return, modifiers: [.command, .control])
          .help("Mark as done and remove from the inbox (⌃⌘↩)")
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
        ReplyBox(isAgentRunning: isAgentRunning, attachments: $attachments, onSend: onSend)
      }
    }
    // Files dropped anywhere on the viewer attach to the reply. While a drag is
    // over it this covers the reply field too: a focused field's editor takes
    // file drops itself and would type the path instead.
    .overlay {
      if isDropTargeted {
        Rectangle().fill(.tint.quaternary)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      guard isAgentRunning, !files.isEmpty else { return false }
      attachments.append(contentsOf: files.filter { !attachments.contains($0) })
      return true
    } isTargeted: { isTargeted in
      isDropTargeted = isTargeted && isAgentRunning
    }
    .accessibilityIdentifier("mailMessageViewer")
  }

  private var readAloudShortcut: String {
    WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.readLastAgentMessageAloud, overrides: settingsFile.global.shortcutOverrides)
  }
}

/// Owns the draft, so a keystroke re-renders the box and not the message.
private struct ReplyBox: View {
  /// A stale session's agent has exited, so there is no one to reply to.
  let isAgentRunning: Bool
  /// Files dropped on the viewer, sent as paths after the text.
  @Binding var attachments: [URL]
  /// The viewer's box takes the keys as it opens; the thread's waits for a click.
  var focusesOnAppear = true
  /// Reports the field taking or giving up the keys, for the overlay's key monitor.
  var onFocusChange: ((Bool) -> Void)?
  let onSend: (String, [URL]) -> Void
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  private var isBlank: Bool { attachments.isEmpty && draft.allSatisfy(\.isWhitespace) }

  private var placeholder: String {
    isAgentRunning ? "Reply to the agent" : "No agent is running in this session"
  }

  var body: some View {
    VStack(spacing: 0) {
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        if !attachments.isEmpty {
          ScrollView(.horizontal) {
            HStack(spacing: 6) {
              ForEach(attachments, id: \.self) { url in
                AttachmentChip(url: url) { attachments.removeAll { $0 == url } }
              }
            }
          }
        }
        HStack(alignment: .bottom, spacing: 8) {
          TextField(placeholder, text: $draft, axis: .vertical)
            .lineLimit(4...10)
            .textFieldStyle(.plain)
            .appFont(.body)
            .focused($isFocused)
            .onSubmit(send)
            .disabled(!isAgentRunning)
            .help("Reply to the agent: Return sends, ⌥Return adds a line, drop files to attach them")
            .accessibilityIdentifier("mailReplyField")
          Button("Send", systemImage: "arrow.up", action: send)
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .appFont(.body)
            .disabled(!isAgentRunning || isBlank)
            .help("Send the reply (Return); type a reply or drop files first")
        }
      }
      .padding(10)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: MailMessageViewer.replyBoxCornerRadius)
      )
      .overlay(RoundedRectangle(cornerRadius: MailMessageViewer.replyBoxCornerRadius).strokeBorder(.separator))
      .frame(maxWidth: MailMessageViewer.columnWidth)
      .padding(.horizontal, MailMessageViewer.columnPadding)
      .padding(.top, 12)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .background(Color(nsColor: .controlBackgroundColor))
    // `.task`, not `.onAppear`: the field must be in the window before it can
    // take focus, or focus stays on the hidden terminal and Escape goes there.
    .task { if focusesOnAppear { isFocused = true } }
    .onChange(of: isFocused) { _, isFocused in onFocusChange?(isFocused) }
    // Leaving the hierarchy while focused reports nothing through onChange.
    .onDisappear { if isFocused { onFocusChange?(false) } }
  }

  private func send() {
    guard !isBlank else { return }
    onSend(draft, attachments)
    draft = ""
  }
}

/// A dropped file waiting to go with the reply.
private struct AttachmentChip: View {
  let url: URL
  let onRemove: () -> Void
  /// Looked up once per file: the box re-renders its chips on every keystroke.
  @State private var icon: NSImage?

  var body: some View {
    HStack(spacing: 4) {
      Image(nsImage: icon ?? NSImage())
        .resizable()
        .frame(width: 16, height: 16)
        // The file name beside it says the same.
        .accessibilityHidden(true)
      Text(url.lastPathComponent)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 180, alignment: .leading)
      Button("Remove \(url.lastPathComponent)", systemImage: "xmark.circle.fill", action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Remove \(url.lastPathComponent) from the reply")
    }
    .appFont(.caption)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.quaternary, in: Capsule())
    .help(url.path)
    .task(id: url) { icon = NSWorkspace.shared.icon(forFile: url.path) }
  }
}
