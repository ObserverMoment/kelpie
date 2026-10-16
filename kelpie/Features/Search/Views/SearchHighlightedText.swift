import SwiftUI

/// A message body as plain text with every hit of the ⌘F query marked. Its
/// only inputs are the two strings, so SwiftUI skips the rescan when the host
/// tile re-renders for focus or expansion.
struct SearchHighlightedText: View {
  let text: String
  let query: String

  var body: some View {
    Text(SearchMatch.highlighted(text, query: query))
  }
}

extension SearchMatch {
  /// The text with every hit on the system find-highlight background.
  static func highlighted(_ text: String, query: String) -> AttributedString {
    ranges(of: query, in: text).reduce(into: AttributedString(text)) { attributed, range in
      guard let hit = Range(range, in: attributed) else { return }
      attributed[hit].backgroundColor = Color(nsColor: .findHighlightColor)
      // The system find highlight is yellow in both appearances, so the hit's
      // text is dark in both too (the surrounding text keeps the label colour).
      attributed[hit].foregroundColor = .black
    }
  }
}
