import Foundation

/// The app's font size in points, shared by the chrome and the terminal. The
/// chrome scales each semantic font by `scale` (see `View.appFont`), because
/// macOS SwiftUI does not resize text for Dynamic Type; the terminal takes
/// `points` as Ghostty's `font-size`.
public nonisolated struct ChromeTextSize: Hashable, CaseIterable, Codable, Identifiable, Sendable {
  /// The sizes Settings offers; the layout has to hold at both ends.
  public static let range = 10...24
  /// macOS body text, so Default leaves the chrome at the system sizes.
  public static let `default` = ChromeTextSize(points: 13)
  public static let allCases = range.map(ChromeTextSize.init(points:))

  public let points: Int

  /// Clamps to `range`, so a hand-edited file can't size text past the layout.
  public init(points: Int) {
    self.points = min(max(points, Self.range.lowerBound), Self.range.upperBound)
  }

  public var id: Int { points }

  public var label: String { "\(points) pt" }

  /// Multiplier applied to each semantic font's system point size, so body text
  /// lands on `points`.
  public var scale: Double { Double(points) / Double(Self.default.points) }

  /// Reads the point size, or a name saved before sizes were points. Each name
  /// maps to the body size it rendered at (13 x 1.15 and 13 x 1.3, rounded).
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let points = try? container.decode(Int.self) {
      self.init(points: points)
      return
    }
    switch try container.decode(String.self) {
    case "standard": self = .default
    case "large": self.init(points: 15)
    case "extraLarge": self.init(points: 17)
    case let name:
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown text size \(name)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(points)
  }
}
