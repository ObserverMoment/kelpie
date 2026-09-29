import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsFeature
@testable import KelpieSettingsShared
@testable import kelpie

@MainActor
struct AppFeaturePodsTests {
  private static let root = URL(fileURLWithPath: "/tmp/pods-app")
  private let member = UUID()
  private let podmate = UUID()
  private let podID = PodID(rawValue: UUID())

  private func makeStore() -> TestStoreOf<AppFeature> {
    let worktree = Worktree(
      id: WorktreeID("/tmp/pods-app/wt"), name: "wt", detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/pods-app/wt"), repositoryRootURL: Self.root)
    var repositories = RepositoriesFeature.State(reconciledRepositories: [
      Repository(id: RepositoryID(Self.root.path), rootURL: Self.root, name: "pods-app", worktrees: [worktree])
    ])
    repositories.isInitialLoadComplete = true
    var state = AppFeature.State(repositories: repositories, settings: SettingsFeature.State())
    state.pods.pods = [
      Pod(
        id: podID, name: "Chat", description: "",
        members: [
          PodMember(id: member, worktreeID: worktree.id, name: "A", description: ""),
          PodMember(id: podmate, worktreeID: worktree.id, name: "B", description: ""),
        ])
    ]
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.deliverPrompt = { _, _ in true }
      $0.terminalClient.reassertSurfaceActivity = {}
    }
    store.exhaustivity = .off
    return store
  }

  private func makePipe() -> (readFD: Int32, writeFD: Int32) {
    var fds: [Int32] = [0, 0]
    let result = fds.withUnsafeMutableBufferPointer { Darwin.pipe($0.baseAddress!) }
    precondition(result == 0, "pipe() failed")
    return (fds[0], fds[1])
  }

  private func readPipeJSON(_ fileDescriptor: Int32) -> [String: Any]? {
    _ = fcntl(fileDescriptor, F_SETFL, fcntl(fileDescriptor, F_GETFL) | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = buffer.withUnsafeMutableBufferPointer { Darwin.read(fileDescriptor, $0.baseAddress!, $0.count) }
    guard bytesRead > 0 else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(buffer.prefix(bytesRead))) as? [String: Any]
  }

  @Test(.dependencies) func aMembersSocketRegisterReachesThePodAndAnswersOK() async {
    let store = makeStore()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .podRegister(surfaceID: member, sessionName: "kelpie-a"), source: .socket, responseFD: writeFD,
        timeoutSeconds: 0))
    await store.receive(\.pods.registered)
    await store.finish()
    #expect(store.state.pods.pods[id: podID]?.members[id: member]?.sessionName == "kelpie-a")
    #expect(readPipeJSON(readFD)?["ok"] as? Bool == true)
  }

  @Test(.dependencies) func aNonMembersRegisterFailsTheCommand() async {
    let store = makeStore()
    let (readFD, writeFD) = makePipe()
    defer { close(readFD) }
    await store.send(
      .deeplink(
        .podRegister(surfaceID: UUID(), sessionName: "kelpie-x"), source: .socket, responseFD: writeFD,
        timeoutSeconds: 0))
    await store.finish()
    let response = readPipeJSON(readFD)
    #expect(response?["ok"] as? Bool == false)
    #expect(response?["error"] as? String == "This session is not a member of an agent pod.")
  }

  @Test(.dependencies) func aRegisterFromAURLIsIgnored() async {
    let store = makeStore()
    await store.send(.deeplink(.podRegister(surfaceID: member, sessionName: "kelpie-a"), source: .urlScheme))
    await store.finish()
    #expect(store.state.pods.pods[id: podID]?.members[id: member]?.registration == .pending)
  }

  @Test(.dependencies) func presenceChangesReachThePodForMembersOnly() async {
    let store = makeStore()
    let bystander = UUID()
    await store.send(.agentPresence(.delegate(.surfacesChanged([member, bystander]))))
    await store.receive(\.pods.memberActivityChanged) {
      // The member has no Claude presence, so its departure grace starts.
      $0.pods.memberActivity[self.member] = nil
    }
    #expect(store.state.pods.trackedSurfaceIDs.contains(bystander) == false)
    await store.skipInFlightEffects()
  }

  @Test(.dependencies) func openingTheWorkspaceShowsItAndExemptsItsMembers() async {
    let store = makeStore()
    await store.send(.fleetView(.togglePods))
    await store.send(.pods(.openTapped(podID)))
    await store.receive(\.pods.delegate.openWorkspace)
    await store.receive(\.fleetView.modeChanged)
    await store.receive(\.terminals.podSurfacesChanged)
    #expect(store.state.fleetView.isShowingPodWorkspace)
    #expect(store.state.terminals.podWorkspaceSurfaceIDs == [member, podmate])
    #expect(store.state.terminals.podSurfaceIDs == [member, podmate])
  }
}
