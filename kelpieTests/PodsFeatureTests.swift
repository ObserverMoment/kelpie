import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct PodsFeatureTests {
  private let worktree = Worktree.ID("/tmp/pods/a")
  private let first = UUID(1)
  private let second = UUID(2)
  private let third = UUID(3)
  private let podID = PodID(rawValue: UUID(0))

  private func candidate(_ id: UUID, _ activity: AgentPresenceFeature.Activity) -> PodStructure.Candidate {
    PodStructure.Candidate(
      id: id, worktreeID: worktree, worktreeName: "a", repositoryName: "pods", branchName: "main",
      agents: [.claude], activity: activity, disabledReason: nil)
  }

  private func draft(_ id: UUID, _ name: String) -> PodMemberDraft {
    PodMemberDraft(id: id, worktreeID: worktree, isSelected: true, name: name)
  }

  private func member(_ id: UUID, _ name: String, _ registration: PodMember.Registration = .pending) -> PodMember {
    PodMember(id: id, worktreeID: worktree, name: name, description: "", registration: registration)
  }

  private func register(_ id: UUID, _ name: String) -> QueuedPrompt {
    QueuedPrompt(kind: .register, text: PodPrompt.register(podName: "Chat", memberName: name, surfaceID: id))
  }

  private func roster(_ you: PodPrompt.Podmate, _ podmates: [PodPrompt.Podmate]) -> QueuedPrompt {
    QueuedPrompt(
      kind: .roster, text: PodPrompt.roster(podName: "Chat", podDescription: "", you: you, podmates: podmates))
  }

  private var disbanded: QueuedPrompt {
    QueuedPrompt(kind: .disbanded, text: PodPrompt.disbanded(podName: "Chat"))
  }

  /// A pod whose members all registered, as `kelpie-<name>`, and got the roster.
  private func formedPod(_ members: [(UUID, String)]) -> Pod {
    var pod = Pod(
      id: podID, name: "Chat", description: "",
      members: IdentifiedArray(
        uniqueElements: members.map { member($0.0, $0.1, .registered(sessionName: "kelpie-\($0.1)")) }))
    pod.sentRoster = pod.roster
    return pod
  }

  private func makeStore(
    _ state: PodsFeature.State,
    clock: TestClock<Duration>,
    delivered: LockIsolated<[UUID: [String]]>,
    deliverSucceeds: Bool = true
  ) -> TestStoreOf<PodsFeature> {
    TestStore(initialState: state) {
      PodsFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.uuid = .incrementing
      $0[TerminalClient.self].deliverPrompt = { surfaceID, text in
        delivered.withValue { $0[surfaceID, default: []].append(text) }
        return deliverSucceeds
      }
    }
  }

  @Test(.dependencies) func handshakeRegistersEveryoneThenSendsTheRosterWhenIdle() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.structure = PodStructure(pods: [], candidates: [candidate(first, .idle), candidate(second, .busy)])
    state.editor = PodEditorFeature.State(mode: .create, candidates: state.structure.candidates)
    let store = makeStore(state, clock: clock, delivered: delivered)

    let create = PodEditorFeature.Delegate.create(
      name: "Chat", description: "", members: [draft(first, "A"), draft(second, "B")])
    await store.send(.editor(.presented(.delegate(create)))) {
      $0.pods = [
        Pod(
          id: self.podID, name: "Chat", description: "",
          members: [self.member(self.first, "A"), self.member(self.second, "B")])
      ]
      $0.memberActivity = [self.first: .idle, self.second: .busy]
      // The idle member gets its prompt now; the busy one waits.
      $0.queue = [self.second: [self.register(self.second, "B")]]
      $0.awaitingTurn = [self.first]
    }
    await store.receive(.promptDelivered(surfaceID: first, .register))

    // A starts on it; B finishes its turn and gets its prompt.
    await store.send(.memberActivityChanged(surfaceID: first, activity: .busy)) {
      $0.memberActivity[self.first] = .busy
      $0.awaitingTurn = []
    }
    await store.send(.memberActivityChanged(surfaceID: second, activity: .idle)) {
      $0.memberActivity[self.second] = .idle
      $0.queue = [:]
      $0.awaitingTurn = [self.second]
    }
    await store.receive(.promptDelivered(surfaceID: second, .register))
    await store.send(.memberActivityChanged(surfaceID: second, activity: .busy)) {
      $0.memberActivity[self.second] = .busy
      $0.awaitingTurn = []
    }

    await store.send(.registered(surfaceID: first, sessionName: "kelpie-a")) {
      $0.pods[id: self.podID]?.members[id: self.first]?.registration = .registered(sessionName: "kelpie-a")
    }
    let podmateA = PodPrompt.Podmate(id: "kelpie-a", name: "A", description: "")
    let podmateB = PodPrompt.Podmate(id: "kelpie-b", name: "B", description: "")
    await store.send(.registered(surfaceID: second, sessionName: "kelpie-b")) {
      $0.pods[id: self.podID]?.members[id: self.second]?.registration = .registered(sessionName: "kelpie-b")
      $0.pods[id: self.podID]?.sentRoster = [podmateA, podmateB]
      $0.queue = [self.first: [self.roster(podmateA, [podmateB])], self.second: [self.roster(podmateB, [podmateA])]]
    }

    await store.send(.memberActivityChanged(surfaceID: first, activity: .idle)) {
      $0.memberActivity[self.first] = .idle
      $0.queue[self.first] = nil
      $0.awaitingTurn = [self.first]
    }
    await store.receive(.promptDelivered(surfaceID: first, .roster))
    await store.send(.memberActivityChanged(surfaceID: first, activity: .busy)) {
      $0.memberActivity[self.first] = .busy
      $0.awaitingTurn = []
    }
    await store.send(.memberActivityChanged(surfaceID: second, activity: .idle)) {
      $0.memberActivity[self.second] = .idle
      $0.queue = [:]
      $0.awaitingTurn = [self.second]
    }
    await store.receive(.promptDelivered(surfaceID: second, .roster))
    await store.send(.memberActivityChanged(surfaceID: second, activity: .busy)) {
      $0.memberActivity[self.second] = .busy
      $0.awaitingTurn = []
    }

    #expect(delivered.value[first] == [register(first, "A").text, roster(podmateA, [podmateB]).text])
    #expect(delivered.value[second] == [register(second, "B").text, roster(podmateB, [podmateA]).text])
  }

  @Test(.dependencies) func aMemberThatNeverRegistersIsUnreachableAndATwoMemberPodDisbands() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.pods = [
      Pod(
        id: podID, name: "Chat", description: "",
        members: [member(first, "A", .registered(sessionName: "kelpie-a")), member(second, "B")])
    ]
    state.memberActivity = [first: .idle, second: .idle]
    state.queue = [second: [register(second, "B")]]
    let store = makeStore(state, clock: clock, delivered: delivered)

    await store.send(.turnLatchExpired(surfaceID: second)) {
      $0.queue = [:]
      $0.awaitingTurn = [self.second]
    }
    await store.receive(.promptDelivered(surfaceID: second, .register))
    await store.send(.memberActivityChanged(surfaceID: second, activity: .busy)) {
      $0.memberActivity[self.second] = .busy
      $0.awaitingTurn = []
    }
    await clock.advance(by: PodsFeature.registrationTimeout)
    // One podmate left to message is no pod: it disbands, and A hears about it.
    await store.receive(.registrationTimedOut(surfaceID: second)) {
      $0.pods = []
      $0.queue = [self.second: [self.disbanded]]
      $0.awaitingTurn = [self.first]
    }
    await store.receive(.delegate(.podRemoved(podID)))
    await store.receive(.promptDelivered(surfaceID: first, .disbanded)) {
      $0.awaitingTurn = []
      $0.memberActivity[self.first] = nil
    }
    await store.send(.memberActivityChanged(surfaceID: second, activity: .idle)) {
      $0.memberActivity[self.second] = .idle
      $0.queue = [:]
      $0.awaitingTurn = [self.second]
    }
    await store.receive(.promptDelivered(surfaceID: second, .disbanded)) {
      $0.awaitingTurn = []
      $0.memberActivity[self.second] = nil
    }
    #expect(delivered.value[first] == [disbanded.text])
  }

  @Test(.dependencies) func aMemberWhoseSessionEndsLeavesAfterTheGraceAndTheRosterIsResent() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.pods = [formedPod([(first, "a"), (second, "b"), (third, "c")])]
    state.memberActivity = [first: .busy, second: .busy, third: .busy]
    let podmateA = PodPrompt.Podmate(id: "kelpie-a", name: "a", description: "")
    let podmateB = PodPrompt.Podmate(id: "kelpie-b", name: "b", description: "")
    let podmateC = PodPrompt.Podmate(id: "kelpie-c", name: "c", description: "")
    // A still has the old roster waiting; the new one replaces it.
    state.queue = [first: [roster(podmateA, [podmateB, podmateC])]]
    let store = makeStore(state, clock: clock, delivered: delivered)

    await store.send(.memberActivityChanged(surfaceID: third, activity: nil)) {
      $0.memberActivity[self.third] = nil
    }
    await clock.advance(by: PodsFeature.departureGrace)
    await store.receive(.departureGraceElapsed(surfaceID: third)) {
      $0.pods[id: self.podID]?.members.remove(id: self.third)
      $0.pods[id: self.podID]?.sentRoster = [podmateA, podmateB]
      $0.queue = [self.first: [self.roster(podmateA, [podmateB])], self.second: [self.roster(podmateB, [podmateA])]]
    }
    #expect(delivered.value.isEmpty)
  }

  @Test(.dependencies) func presenceReturningWithinTheGraceKeepsTheMember() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.pods = [formedPod([(first, "a"), (second, "b")])]
    state.memberActivity = [first: .busy, second: .busy]
    let store = makeStore(state, clock: clock, delivered: delivered)

    await store.send(.memberActivityChanged(surfaceID: first, activity: nil)) {
      $0.memberActivity[self.first] = nil
    }
    await store.send(.memberActivityChanged(surfaceID: first, activity: .busy)) {
      $0.memberActivity[self.first] = .busy
    }
    await clock.advance(by: PodsFeature.departureGrace)
  }

  @Test(.dependencies) func aFailedDeliveryGoesBackToTheFrontOfTheQueue() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.pods = [Pod(id: podID, name: "Chat", description: "", members: [member(first, "A"), member(second, "B")])]
    state.memberActivity = [first: .busy]
    state.queue = [first: [register(first, "A")]]
    let store = makeStore(state, clock: clock, delivered: delivered, deliverSucceeds: false)

    await store.send(.memberActivityChanged(surfaceID: first, activity: .idle)) {
      $0.memberActivity[self.first] = .idle
      $0.queue = [:]
      $0.awaitingTurn = [self.first]
    }
    await store.receive(.promptDeliveryFailed(surfaceID: first, register(first, "A"))) {
      $0.queue = [self.first: [self.register(self.first, "A")]]
      $0.awaitingTurn = []
    }
  }

  @Test(.dependencies) func disbandTellsMembersThatHeardFromThePodOnly() async {
    let clock = TestClock()
    let delivered = LockIsolated<[UUID: [String]]>([:])
    var state = PodsFeature.State()
    state.pods = [
      Pod(
        id: podID, name: "Chat", description: "",
        members: [member(first, "A", .registered(sessionName: "kelpie-a")), member(second, "B")])
    ]
    state.memberActivity = [first: .busy, second: .busy]
    // B never got its register prompt.
    state.queue = [second: [register(second, "B")]]
    let store = makeStore(state, clock: clock, delivered: delivered)

    await store.send(.disbandTapped(podID)) {
      $0.pods = []
      $0.queue = [self.first: [self.disbanded]]
      $0.memberActivity = [self.first: .busy]
    }
    await store.receive(.delegate(.podRemoved(podID)))
  }

  @Test(.dependencies) func aRegisterFromANonMemberIsIgnored() async {
    let store = makeStore(
      PodsFeature.State(), clock: TestClock(), delivered: LockIsolated([:]))
    await store.send(.registered(surfaceID: first, sessionName: "kelpie-a"))
  }

  @Test(.dependencies) func openAsksTheParentForTheWorkspace() async {
    var state = PodsFeature.State()
    state.pods = [formedPod([(first, "a"), (second, "b")])]
    let store = makeStore(state, clock: TestClock(), delivered: LockIsolated([:]))
    await store.send(.openTapped(podID))
    await store.receive(.delegate(.openWorkspace(podID)))
  }
}
