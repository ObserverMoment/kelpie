import AppKit

/// What the Fleet View key monitor does with one keystroke. Command chords are
/// offered to the menu bar only (the hidden terminal handles ⌘V and friends in
/// `performKeyEquivalent` otherwise), except ⌃⌘↩, which marks the focused
/// Threads message done; everything else is either a navigation key or is
/// swallowed so it never reaches the terminal.
enum FleetViewKeyDecision: Equatable, Sendable {
  case move(FleetViewNavigation.Direction)
  case activate
  case dismiss
  /// ⌃⌘↩: the focused Threads message is done.
  case markDone
  /// Space: the selected Threads tile's terminal.
  case jump
  case swallow
  case menuShortcut

  static let escapeKeyCode: UInt16 = 53
  static let spaceKeyCode: UInt16 = 49

  static func decide(
    keyCode: UInt16,
    specialKey: NSEvent.SpecialKey?,
    modifiers: NSEvent.ModifierFlags
  ) -> FleetViewKeyDecision {
    let userModifiers = modifiers.intersection([.command, .shift, .option, .control])
    let isReturn = specialKey == .carriageReturn || specialKey == .enter
    if isReturn, userModifiers == [.command, .control] { return .markDone }
    guard !userModifiers.contains(.command) else { return .menuShortcut }
    guard userModifiers.isEmpty else { return .swallow }
    switch specialKey {
    case .leftArrow?: return .move(.left)
    case .rightArrow?: return .move(.right)
    case .upArrow?: return .move(.up)
    case .downArrow?: return .move(.down)
    case .carriageReturn?, .enter?: return .activate
    default:
      switch keyCode {
      case escapeKeyCode: return .dismiss
      case spaceKeyCode: return .jump
      default: return .swallow
      }
    }
  }
}
