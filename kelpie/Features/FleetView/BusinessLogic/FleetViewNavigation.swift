import Foundation

/// Pure keyboard geometry for the Fleet View and Pods grids. Sections are rows of
/// cards wrapped at `columnCount`; left/right walk the flattened order, up/down
/// step by a row and cross section boundaries.
nonisolated enum FleetViewNavigation {
  enum Direction: Equatable, Sendable {
    case left, right, up, down
  }

  static let maximumColumnCount = 6
  static let cardMinimumWidth: CGFloat = 260
  static let cardSpacing: CGFloat = 16

  static func move<ID: Equatable>(
    from focused: ID?,
    _ direction: Direction,
    sections: [[ID]],
    columnCount: Int
  ) -> ID? {
    let flat = sections.flatMap { $0 }
    guard let first = flat.first else { return nil }
    guard let focused, let position = locate(focused, in: sections) else { return first }
    let columns = max(1, columnCount)
    let section = sections[position.section]
    switch direction {
    case .left:
      return flat[max(0, position.flat - 1)]
    case .right:
      return flat[min(flat.count - 1, position.flat + 1)]
    case .up:
      if position.index - columns >= 0 { return section[position.index - columns] }
      guard let previous = sections[..<position.section].lastIndex(where: { !$0.isEmpty }) else { return focused }
      let target = sections[previous]
      let lastRowStart = (target.count - 1) / columns * columns
      return target[min(target.count - 1, lastRowStart + position.index % columns)]
    case .down:
      if position.index + columns < section.count { return section[position.index + columns] }
      guard let next = sections[(position.section + 1)...].firstIndex(where: { !$0.isEmpty }) else { return focused }
      let target = sections[next]
      return target[min(target.count - 1, position.index % columns)]
    }
  }

  /// Keeps `focused` when it survives; otherwise the nearest survivor by the
  /// previous order (first later card, else last earlier card, else the first).
  static func reconcile<ID: Hashable>(
    focused: ID?,
    previous: [ID],
    current: [ID]
  ) -> ID? {
    guard let focused else { return nil }
    guard !current.contains(focused) else { return focused }
    let survivors = Set(current)
    guard let removedIndex = previous.firstIndex(of: focused) else { return current.first }
    let later = previous[(removedIndex + 1)...].first(where: survivors.contains)
    let earlier = previous[..<removedIndex].last(where: survivors.contains)
    return later ?? earlier ?? current.first
  }

  /// Cards per row for a container width, never more than `maximum` and never
  /// fewer than one. The defaults are Fleet View's card metrics.
  static func columnCount(
    forWidth width: CGFloat,
    minimumWidth: CGFloat = cardMinimumWidth,
    spacing: CGFloat = cardSpacing,
    maximum: Int = maximumColumnCount
  ) -> Int {
    let fitting = Int((width + spacing) / (minimumWidth + spacing))
    return min(maximum, max(1, fitting))
  }

  /// `items` cut into the rows a grid of `columnCount` draws: the same rows
  /// `move` steps through, so the views and the arrow keys cannot disagree.
  static func rows<Element>(_ items: [Element], columnCount: Int) -> [[Element]] {
    let columns = max(1, columnCount)
    return stride(from: 0, to: items.count, by: columns).map {
      Array(items[$0..<min($0 + columns, items.count)])
    }
  }

  private struct Position {
    let section: Int
    let index: Int
    let flat: Int
  }

  private static func locate<ID: Equatable>(_ id: ID, in sections: [[ID]]) -> Position? {
    var offset = 0
    for (sectionIndex, section) in sections.enumerated() {
      if let index = section.firstIndex(of: id) {
        return Position(section: sectionIndex, index: index, flat: offset + index)
      }
      offset += section.count
    }
    return nil
  }
}
