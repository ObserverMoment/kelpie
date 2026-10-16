import ComposableArchitecture
import Foundation

/// One ⌘F filter field: shown or hidden, its text, and whether it has the
/// keys. Composed once per filterable list (sidebar, Fleet, Pods, Threads
/// tiles, Threads messages); the parent derives its visible structure from
/// `activeQuery`.
@Reducer
struct SearchFilterFeature {
  @ObservableState
  struct State: Equatable {
    /// The field's text; `nil` while the field is hidden.
    var query: String?
    /// The field has the keys, so the overlay's key monitor must stand aside.
    var isFocused = false
    /// Bumped on every ⌘F so an already shown field takes the keys again.
    var focusRequestCount = 0

    var isPresented: Bool { query != nil }

    /// The trimmed query the list filters on; `nil` when hidden or blank.
    var activeQuery: String? { query.flatMap(SearchMatch.normalized) }
  }

  enum Action: Equatable {
    /// ⌘F: show the field, or focus it again when it is already shown.
    case requested
    case queryChanged(String)
    /// Escape or the field's close button: clear the text and hide the field.
    case dismissed
    case focusChanged(Bool)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .requested:
        state.query = state.query ?? ""
        state.focusRequestCount += 1
        // Expected to hold the keys from here; the field confirms or corrects
        // it through `focusChanged`.
        state.isFocused = true
      case .queryChanged(let query):
        state.query = query
      case .dismissed:
        state.query = nil
        state.isFocused = false
      case .focusChanged(let isFocused):
        state.isFocused = isFocused
      }
      return .none
    }
  }
}
