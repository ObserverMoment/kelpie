import SwiftUI

/// Which slice of a group's card a row draws: the header row carries the top
/// corners, the padding row the bottom ones, every other row a straight cut.
enum SidebarGroupCardEdge: Equatable {
  case top, middle, bottom

  var roundsTop: Bool { self == .top }
  var roundsBottom: Bool { self == .bottom }
}

/// Row background that joins a group header, its member rows, and the last
/// row into one inset card, slightly darker than the sidebar. Drawn through
/// `listRowBackground` so every row in the block paints its own slice.
struct SidebarGroupCardFill: View {
  static let cornerRadius: CGFloat = 6
  /// Sidebar background left showing around the card. The row background
  /// bleeds past the visible sidebar edge, so the horizontal value is larger
  /// than the visible margin it produces.
  static let horizontalInset: CGFloat = 8
  static let verticalInset: CGFloat = 4

  let edge: SidebarGroupCardEdge
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let top = edge.roundsTop ? Self.cornerRadius : 0
    let bottom = edge.roundsBottom ? Self.cornerRadius : 0
    UnevenRoundedRectangle(
      cornerRadii: .init(topLeading: top, bottomLeading: bottom, bottomTrailing: bottom, topTrailing: top)
    )
    // A black wash darkens the sidebar in both appearances; the system
    // fills would lighten a dark sidebar instead.
    .fill(Color.black.opacity(colorScheme == .dark ? 0.22 : 0.06))
    .padding(.horizontal, Self.horizontalInset)
    .padding(.top, edge.roundsTop ? Self.verticalInset : 0)
  }
}

/// A short trailing row that gives the card its bottom padding under the
/// last member's rows.
struct SidebarGroupCardBottomPaddingRow: View {
  var body: some View {
    Color.clear
      .frame(height: SidebarGroupCardFill.verticalInset)
      .listRowInsets(EdgeInsets())
      .listRowBackground(SidebarGroupCardFill(edge: .bottom))
      .moveDisabled(true)
      .accessibilityHidden(true)
  }
}
