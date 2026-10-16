import ComposableArchitecture
import KelpieSettingsShared
import SwiftUI

/// The ⌘F filter field a list shows at its top. Takes the keys as it appears
/// and on every repeated ⌘F; Escape clears and hides it. Reports focus so the
/// overlay's key monitor stands aside while it types (ReplyBox precedent).
struct SearchFilterField: View {
  @Bindable var store: StoreOf<SearchFilterFeature>
  /// What the field filters, for the placeholder and tooltip ("sessions").
  let subject: String
  /// Which list hosts the field, for its accessibility identifier ("fleet").
  let surface: String
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(
        "Filter \(subject)",
        text: Binding(get: { store.query ?? "" }, set: { store.send(.queryChanged($0)) })
      )
      .textFieldStyle(.plain)
      .appFont(.body)
      .focused($isFocused)
      .onExitCommand { store.send(.dismissed) }
      .help("Filter \(subject) by text (⌘F); Escape clears and hides the field")
      .accessibilityIdentifier("searchFilterField-\(surface)")
      Button("Clear", systemImage: "xmark.circle.fill") { store.send(.dismissed) }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Clear the filter and hide the field (Escape)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    // `.task`, not `.onAppear`: the field must be in the window before it can
    // take focus, or focus stays on the terminal and Escape goes there. Only
    // when the reducer asked for it: a remount (mode switch, viewer closing)
    // must not take the keys back from the grid.
    .task { if store.isFocused { isFocused = true } }
    .onChange(of: store.focusRequestCount) { _, _ in isFocused = true }
    .onChange(of: isFocused) { _, isFocused in store.send(.focusChanged(isFocused)) }
    // Leaving the hierarchy while focused reports nothing through onChange.
    .onDisappear { if isFocused { store.send(.focusChanged(false)) } }
  }
}
