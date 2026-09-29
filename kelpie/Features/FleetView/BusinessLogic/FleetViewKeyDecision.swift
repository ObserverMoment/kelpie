import AppKit

/// What the Fleet View key monitor does with one keystroke. Command chords are
/// offered to the menu bar only (the hidden terminal handles ⌘V and friends in
/// `performKeyEquivalent` otherwise); everything else is either a navigation key
/// or is swallowed so it never reaches the terminal.
enum FleetViewKeyDecision: Equatable, Sendable {
  case move(FleetViewNavigation.Direction)
  case activate
  case dismiss
  case swallow
  case menuShortcut

  static let escapeKeyCode: UInt16 = 53

  static func decide(
    keyCode: UInt16,
    specialKey: NSEvent.SpecialKey?,
    modifiers: NSEvent.ModifierFlags
  ) -> FleetViewKeyDecision {
    let userModifiers = modifiers.intersection([.command, .shift, .option, .control])
    guard !userModifiers.contains(.command) else { return .menuShortcut }
    guard userModifiers.isEmpty else { return .swallow }
    switch specialKey {
    case .leftArrow?: return .move(.left)
    case .rightArrow?: return .move(.right)
    case .upArrow?: return .move(.up)
    case .downArrow?: return .move(.down)
    case .carriageReturn?, .enter?: return .activate
    default: return keyCode == escapeKeyCode ? .dismiss : .swallow
    }
  }
}
