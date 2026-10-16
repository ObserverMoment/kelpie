import Foundation
import Testing

@testable import kelpie

struct SearchMatchTests {
  @Test func normalizedTrimsAndDropsBlank() {
    #expect(SearchMatch.normalized("  kelpie ") == "kelpie")
    #expect(SearchMatch.normalized("   ") == nil)
    #expect(SearchMatch.normalized("") == nil)
  }

  @Test func matchesIgnoresCaseAndDiacritics() {
    #expect(SearchMatch.matches("KEL", "feature/kelpie"))
    #expect(SearchMatch.matches("resume", "Résumé"))
    #expect(!SearchMatch.matches("zig", "feature/kelpie"))
    #expect(!SearchMatch.matches("kel", nil))
  }

  @Test func matchesAnyChecksEveryText() {
    #expect(SearchMatch.matches("main", any: [nil, "kelpie", "main"]))
    #expect(!SearchMatch.matches("main", any: [nil, "kelpie"]))
  }

  @Test func rangesFindEveryNonOverlappingHit() {
    let text = "Kelpie kelpie KELPIE"
    let hits = SearchMatch.ranges(of: "kel", in: text).map { String(text[$0]) }
    #expect(hits == ["Kel", "kel", "KEL"])
    #expect(SearchMatch.ranges(of: "", in: text).isEmpty)
    #expect(SearchMatch.ranges(of: "zig", in: text).isEmpty)
  }

  @Test func highlightedMarksEveryHit() {
    let attributed = SearchMatch.highlighted("Kelpie kelpie", query: "kel")
    let marked = attributed.runs.filter { $0.backgroundColor != nil }.map { String(attributed[$0.range].characters) }
    #expect(marked == ["Kel", "kel"])
    #expect(String(attributed.characters) == "Kelpie kelpie")
  }
}
