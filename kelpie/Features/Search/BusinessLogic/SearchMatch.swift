import Foundation

/// Substring matching for the ⌘F filter fields: case- and diacritic-insensitive,
/// no fuzzy scoring. Pure; the lists call it from their cached `filtered`
/// projections and `SearchHighlightedText` marks the hits with `ranges`.
enum SearchMatch {
  private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

  /// The query the lists filter on: trimmed, or `nil` when blank.
  static func normalized(_ query: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func matches(_ query: String, _ text: String?) -> Bool {
    text?.range(of: query, options: options) != nil
  }

  /// Any of the texts contains the query.
  static func matches(_ query: String, any texts: [String?]) -> Bool {
    texts.contains { matches(query, $0) }
  }

  /// Every non-overlapping hit, left to right.
  static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
    guard !query.isEmpty else { return [] }
    return Array(
      sequence(state: text.startIndex) { start -> Range<String.Index>? in
        guard start < text.endIndex,
          let range = text.range(of: query, options: options, range: start..<text.endIndex)
        else { return nil }
        start = range.upperBound
        return range
      })
  }
}
