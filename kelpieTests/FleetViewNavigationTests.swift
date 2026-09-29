import Foundation
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct FleetViewNavigationTests {
  private func ids(_ count: Int) -> [FleetCardID] {
    (0..<count).map { _ in FleetCardID(surfaceID: UUID(), agent: .claude) }
  }

  @Test func nilFocusMovesToFirstCard() {
    let first = ids(3)
    #expect(FleetViewNavigation.move(from: nil, .down, sections: [first], columnCount: 2) == first[0])
    #expect(FleetViewNavigation.move(from: nil, .left, sections: [], columnCount: 2) == nil)
  }

  @Test func leftRightWalkTheFlattenedOrderAndClamp() {
    let first = ids(2)
    let second = ids(2)
    let sections = [first, second]
    #expect(FleetViewNavigation.move(from: first[1], .right, sections: sections, columnCount: 6) == second[0])
    #expect(FleetViewNavigation.move(from: second[0], .left, sections: sections, columnCount: 6) == first[1])
    #expect(FleetViewNavigation.move(from: first[0], .left, sections: sections, columnCount: 6) == first[0])
    #expect(FleetViewNavigation.move(from: second[1], .right, sections: sections, columnCount: 6) == second[1])
  }

  @Test func upDownStepByColumnWithinSection() {
    let first = ids(5)
    #expect(FleetViewNavigation.move(from: first[0], .down, sections: [first], columnCount: 2) == first[2])
    #expect(FleetViewNavigation.move(from: first[3], .up, sections: [first], columnCount: 2) == first[1])
    #expect(FleetViewNavigation.move(from: first[4], .down, sections: [first], columnCount: 2) == first[4])
  }

  @Test func downCrossesIntoNextSectionKeepingColumn() {
    let first = ids(3)
    let second = ids(2)
    #expect(FleetViewNavigation.move(from: first[1], .down, sections: [first, second], columnCount: 3) == second[1])
    #expect(FleetViewNavigation.move(from: first[2], .down, sections: [first, second], columnCount: 3) == second[1])
  }

  @Test func upCrossesIntoPreviousSectionLastRow() {
    let first = ids(5)
    let second = ids(2)
    #expect(FleetViewNavigation.move(from: second[1], .up, sections: [first, second], columnCount: 3) == first[4])
    #expect(FleetViewNavigation.move(from: second[0], .up, sections: [first, second], columnCount: 3) == first[3])
    #expect(FleetViewNavigation.move(from: first[0], .up, sections: [first, second], columnCount: 3) == first[0])
  }

  @Test func reconcileKeepsSurvivorOrPicksNearest() {
    let first = ids(4)
    #expect(FleetViewNavigation.reconcile(focused: first[1], previous: first, current: first) == first[1])
    #expect(
      FleetViewNavigation.reconcile(focused: first[1], previous: first, current: [first[0], first[2], first[3]])
        == first[2])
    #expect(
      FleetViewNavigation.reconcile(focused: first[3], previous: first, current: [first[0], first[1]]) == first[1])
    #expect(FleetViewNavigation.reconcile(focused: first[3], previous: first, current: []) == nil)
    #expect(FleetViewNavigation.reconcile(focused: nil, previous: first, current: first) == nil)
  }

  @Test func columnCountIsClampedBetweenOneAndSix() {
    #expect(FleetViewNavigation.columnCount(forWidth: 0) == 1)
    #expect(FleetViewNavigation.columnCount(forWidth: 300) == 1)
    #expect(FleetViewNavigation.columnCount(forWidth: 540) == 2)
    #expect(FleetViewNavigation.columnCount(forWidth: 5000) == 6)
  }
}
