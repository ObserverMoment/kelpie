import SwiftUI
import Testing

@testable import KelpieSettingsShared

struct ChromeTextSizeTests {
  @Test func defaultIsTheSystemBodySize() {
    #expect(ChromeTextSize.default.points == 13)
    #expect(ChromeTextSize.default.scale == 1.0)
  }

  @Test func sizesOutsideTheRangeClamp() {
    #expect(ChromeTextSize(points: 4).points == 10)
    #expect(ChromeTextSize(points: 40).points == 24)
  }

  @Test func casesCoverTheRangeSmallestFirst() {
    // `allCases` is the order the picker renders.
    #expect(ChromeTextSize.allCases.map(\.points) == Array(10...24))
    #expect(ChromeTextSize.allCases.contains(.default))
  }

  @Test func encodesThePointSize() throws {
    let data = try JSONEncoder().encode(ChromeTextSize(points: 16))
    #expect(String(bytes: data, encoding: .utf8) == "16")
  }

  @Test func decodesClampedPointSizes() throws {
    let points = try ["16", "99"].map {
      try JSONDecoder().decode(ChromeTextSize.self, from: Data($0.utf8)).points
    }
    #expect(points == [16, 24])
  }

  @Test func decodesLegacyNamesAsTheBodySizeTheyRendered() throws {
    // Settings files from before sizes were points saved a name.
    let points = try [#""standard""#, #""large""#, #""extraLarge""#].map {
      try JSONDecoder().decode(ChromeTextSize.self, from: Data($0.utf8)).points
    }
    #expect(points == [13, 15, 17])
  }

  @Test func rejectsUnknownNames() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ChromeTextSize.self, from: Data(#""gigantic""#.utf8))
    }
  }
}

/// The font-resolution core behind `appFont` / `appFontInheriting`. Extracted
/// from the view modifiers so the size math is testable without a view host.
struct AppFontMetricsTests {
  @Test func defaultResolvesToTheExactSemanticFont() {
    // The Default path must leave text byte-identical to `.font(...)`, so no
    // scaled point size is substituted.
    #expect(AppFontMetrics.resolvedFont(for: .body, size: .default, weight: nil, monospaced: false) == .system(.body))
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: .default, weight: .semibold, monospaced: false)
        == .system(.body).weight(.semibold)
    )
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: .default, weight: nil, monospaced: true)
        == .system(.body).monospaced()
    )
  }

  @Test func scaledPathRoundsAndKeepsTheStyleDefaultWeight() {
    let size = AppFontMetrics.scaledPointSize(for: .body, size: ChromeTextSize(points: 15))
    #expect(size == size.rounded())
    #expect(
      AppFontMetrics.resolvedFont(for: .body, size: ChromeTextSize(points: 15), weight: nil, monospaced: false)
        == .system(size: size).weight(.regular)
    )
  }

  @Test func headlineKeepsSemiboldWhenScaled() {
    // `.headline` is the one macOS style that isn't regular; the scaled path
    // re-applies the weight explicitly, so it must preserve it.
    let size = AppFontMetrics.scaledPointSize(for: .headline, size: ChromeTextSize(points: 17))
    #expect(
      AppFontMetrics.resolvedFont(for: .headline, size: ChromeTextSize(points: 17), weight: nil, monospaced: false)
        == .system(size: size).weight(.semibold)
    )
    #expect(AppFontMetrics.defaultWeight(for: .headline) == .semibold)
    #expect(AppFontMetrics.defaultWeight(for: .body) == .regular)
  }

  @Test func scaledPointSizeGrowsWithTheSize() {
    let smallest = AppFontMetrics.scaledPointSize(for: .body, size: .default)
    let middle = AppFontMetrics.scaledPointSize(for: .body, size: ChromeTextSize(points: 15))
    let largest = AppFontMetrics.scaledPointSize(for: .body, size: ChromeTextSize(points: 17))
    #expect(smallest <= middle)
    #expect(middle <= largest)
    #expect(smallest < largest)
  }

  @Test func bodyTextLandsOnThePointSize() {
    #expect(AppFontMetrics.scaledPointSize(for: .body, size: ChromeTextSize(points: 10)) == 10)
    #expect(AppFontMetrics.scaledPointSize(for: .body, size: ChromeTextSize(points: 24)) == 24)
  }

  @Test func inheritedFontIsAbsentAtDefaultAndPresentAbove() {
    #expect(AppFontMetrics.inheritedFont(for: .subheadline, size: .default, weight: nil) == nil)
    #expect(AppFontMetrics.inheritedFont(for: .subheadline, size: ChromeTextSize(points: 15), weight: .semibold) != nil)
  }
}
