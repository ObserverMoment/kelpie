import AppKit
import Testing

@testable import kelpie

private typealias Decision = FleetViewKeyDecision

struct FleetViewKeyDecisionTests {
  @Test func arrowsMoveAndReturnActivates() {
    #expect(Decision.decide(keyCode: 0, specialKey: .leftArrow, modifiers: []) == .move(.left))
    #expect(Decision.decide(keyCode: 0, specialKey: .rightArrow, modifiers: []) == .move(.right))
    #expect(Decision.decide(keyCode: 0, specialKey: .upArrow, modifiers: []) == .move(.up))
    #expect(Decision.decide(keyCode: 0, specialKey: .downArrow, modifiers: []) == .move(.down))
    #expect(Decision.decide(keyCode: 0, specialKey: .carriageReturn, modifiers: []) == .activate)
    #expect(Decision.decide(keyCode: 0, specialKey: .enter, modifiers: []) == .activate)
  }

  @Test func escapeDismissesAndPlainTypingIsSwallowed() {
    #expect(Decision.decide(keyCode: Decision.escapeKeyCode, specialKey: nil, modifiers: []) == .dismiss)
    #expect(Decision.decide(keyCode: 0, specialKey: nil, modifiers: []) == .swallow)
    #expect(Decision.decide(keyCode: 0, specialKey: nil, modifiers: .shift) == .swallow)
    #expect(Decision.decide(keyCode: 0, specialKey: .leftArrow, modifiers: .control) == .swallow)
  }

  @Test func commandChordsGoToTheMenuBar() {
    #expect(Decision.decide(keyCode: 0, specialKey: nil, modifiers: .command) == .menuShortcut)
    #expect(Decision.decide(keyCode: 0, specialKey: .leftArrow, modifiers: [.command, .shift]) == .menuShortcut)
  }
}
