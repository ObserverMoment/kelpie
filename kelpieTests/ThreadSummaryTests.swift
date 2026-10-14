import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import KelpieSettingsShared
@testable import kelpie

struct SummaryPromptTests {
  @Test func requestCarriesThePreviousSummaryAndEveryNewMessage() {
    let request = SummaryPrompt.request(
      kind: .pod, previous: "So far", newMessages: ["one", "two"], model: .sonnet, effort: .medium)
    #expect(request.model == .sonnet)
    #expect(request.effort == .medium)
    #expect(request.systemPrompt.contains("pod of coding agents"))
    #expect(request.systemPrompt.contains("at most 400 characters"))
    let expected = """
      <previous-summary>
      So far
      </previous-summary>
      <new-messages>
      <message>
      one
      </message>
      <message>
      two
      </message>
      </new-messages>
      """
    #expect(request.prompt == expected)
  }

  @Test func firstRunSaysThereIsNoSummaryYet() {
    let prompt = SummaryPrompt.prompt(previous: nil, newMessages: ["hi"])
    #expect(prompt.hasPrefix("<previous-summary>(none yet)</previous-summary>"))
    #expect(SummaryPrompt.systemPrompt(for: .session).contains("at most 280 characters"))
  }

  @Test func truncateKeepsShortTextAndCapsLongText() {
    #expect(SummaryPrompt.truncate("  short  ", cap: 10) == "short")
    let long = String(repeating: "a", count: 20) + " " + String(repeating: "b", count: 20)
    let capped = SummaryPrompt.truncate(long, cap: 22)
    #expect(capped.count <= 22)
    #expect(capped.hasSuffix("…"))
  }

  @Test func parseResultReadsTheReplyAndRejectsErrors() throws {
    let success = Data(#"{"type":"result","is_error":false,"result":" Doing X. "}"#.utf8)
    #expect(try SummaryPrompt.parseResult(success) == "Doing X.")
    let failed = Data(#"{"type":"result","is_error":true,"result":"boom"}"#.utf8)
    #expect(throws: ThreadSummaryError.modelFailed("boom")) { try SummaryPrompt.parseResult(failed) }
    let empty = Data(#"{"type":"result","is_error":false,"result":""}"#.utf8)
    #expect(throws: ThreadSummaryError.emptyResult) { try SummaryPrompt.parseResult(empty) }
  }

  @Test func claudeArgumentsRunHeadlessWithoutToolsOrSettings() {
    let request = SummaryPrompt.request(kind: .session, previous: nil, newMessages: ["m"], model: .haiku, effort: .low)
    let arguments = ThreadSummaryClient.arguments(for: request)
    #expect(arguments.prefix(2) == ["claude", "-p"])
    #expect(arguments.contains(["--model", "haiku"]))
    #expect(arguments.contains(["--effort", "low"]))
    #expect(arguments.contains(["--tools", ""]))
    #expect(arguments.contains(["--setting-sources", ""]))
    #expect(arguments.contains(["--output-format", "json"]))
    #expect(arguments.last == request.prompt)
  }

  @Test func settingsDecodeLenientlyWithDefaults() throws {
    var settings = GlobalSettings.default
    settings.threadSummaryModel = .opus
    let encoded = try #require(String(data: JSONEncoder().encode(SettingsFile(global: settings)), encoding: .utf8))
    let replaced = encoded.replacing(#""threadSummaryEffort":"low""#, with: #""threadSummaryEffort":"bogus""#)
    #expect(replaced != encoded)
    let file = try JSONDecoder().decode(SettingsFile.self, from: Data(replaced.utf8))
    #expect(file.global.threadSummaryModel == .opus)
    #expect(file.global.threadSummaryEffort == .low)
    #expect(GlobalSettings.default.threadSummaryModel == .haiku)
  }

  @Test func aThreadsFileFromBeforeRepliesStillLoads() throws {
    let json = Data(
      #"""
      {"boxes":[{"surfaceID":"11111111-1111-1111-1111-111111111111","worktreeID":"/tmp/wt","agent":"claude",
      "messages":[{"id":"22222222-2222-2222-2222-222222222222","body":"x","createdAt":0}]}]}
      """#.utf8)
    let file = try JSONDecoder().decode(ThreadsFile.self, from: json)
    let message = try #require(file.boxes.first?.messages.first)
    #expect(message.author == .agent)
    #expect(message.isRead == false)
    #expect(file.boxes.first?.summary == nil)
    #expect(file.podSummaries.isEmpty)
  }

  @Test func anUnknownSummaryModelFallsBackToTheDefault() throws {
    let encoded = try #require(String(data: JSONEncoder().encode(SettingsFile.default), encoding: .utf8))
    let replaced = encoded.replacing(#""threadSummaryModel":"haiku""#, with: #""threadSummaryModel":"bogus""#)
    #expect(replaced != encoded)
    let json = Data(replaced.utf8)
    #expect(try JSONDecoder().decode(SettingsFile.self, from: json).global.threadSummaryModel == .haiku)
  }

  @Test func promptCutsEachOversizedMessage() {
    let long = String(repeating: "a", count: 5000)
    let prompt = SummaryPrompt.prompt(previous: nil, newMessages: [long])
    let body = prompt.split(separator: "<message>\n")[1].split(separator: "\n</message>")[0]
    #expect(body.count <= SummaryPrompt.maxMessageCharacters)
    #expect(body.hasSuffix("…"))
  }

  @Test func parseResultRejectsBannersAndMissingResults() {
    #expect(throws: (any Error).self) { try SummaryPrompt.parseResult(Data("Please log in\n".utf8)) }
    #expect(throws: (any Error).self) { try SummaryPrompt.parseResult(Data()) }
    #expect(throws: ThreadSummaryError.emptyResult) {
      try SummaryPrompt.parseResult(Data(#"{"type":"result"}"#.utf8))
    }
  }

  @Test func threadsFileDecodesWithoutPodSummaries() throws {
    let json = Data(#"{"boxes":[]}"#.utf8)
    let file = try JSONDecoder().decode(ThreadsFile.self, from: json)
    #expect(file.podSummaries.isEmpty)
  }
}

extension [String] {
  fileprivate func contains(_ pair: [String]) -> Bool {
    indices.dropLast().contains { self[$0] == pair[0] && self[$0 + 1] == pair[1] }
  }
}

@MainActor
struct ThreadsSummaryFlowTests {
  private static let worktreeID = WorktreeID("/tmp/threads/wt")

  /// A summariser that records each request and answers only when released.
  private final class Summariser: Sendable {
    let requests = LockIsolated<[SummaryPrompt.Request]>([])
    let reply = LockIsolated<Result<String, ThreadSummaryError>>(.success("Summary"))
    private let gate: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation

    init() {
      (gate, release) = AsyncStream<Void>.makeStream()
    }

    func releaseOne() { release.yield() }

    var client: ThreadSummaryClient {
      ThreadSummaryClient { [self] request in
        requests.withValue { $0.append(request) }
        for await _ in gate { break }
        return try reply.value.get()
      }
    }
  }

  private static func makeStore(_ summariser: Summariser) -> TestStoreOf<ThreadsFeature> {
    let store = TestStore(initialState: ThreadsFeature.State()) {
      ThreadsFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.date.now = Date(timeIntervalSince1970: 1_700_000_000)
      $0[ThreadSummaryClient.self] = summariser.client
    }
    store.exhaustivity = .off
    return store
  }

  private static func deliver(
    _ store: TestStoreOf<ThreadsFeature>, surface: UUID, _ body: String, podID: PodID? = nil
  ) async {
    await store.send(
      .received(surfaceID: surface, worktreeID: worktreeID, agent: .claude, body: body, podID: podID))
  }

  @Test(.dependencies) func deliveriesDuringARunCoalesceIntoTheNextOne() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    await Self.deliver(store, surface: surface, "a")
    #expect(store.state.summariesInFlight == [.session(surface)])
    await Self.deliver(store, surface: surface, "b")
    await Self.deliver(store, surface: surface, "c")
    #expect(store.state.pendingSummaryInput[.session(surface)] == ["Agent: b", "Agent: c"])

    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    #expect(store.state.file.boxes[id: surface]?.summary == "Summary")
    #expect(store.state.summariesInFlight == [.session(surface)])
    #expect(store.state.pendingSummaryInput[.session(surface)] == nil)

    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    #expect(store.state.summariesInFlight.isEmpty)
    let requests = summariser.requests.value
    #expect(requests.count == 2)
    #expect(requests[0].prompt.contains("(none yet)"))
    #expect(requests[0].prompt.contains("<message>\nAgent: a\n</message>"))
    #expect(requests[1].prompt.contains("<previous-summary>\nSummary\n</previous-summary>"))
    #expect(requests[1].prompt.contains("<message>\nAgent: b\n</message>\n<message>\nAgent: c\n</message>"))
  }

  @Test(.dependencies) func aPoddedDeliveryRollsTheSessionAndThePodSummaries() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    let podID = PodID(rawValue: UUID())
    await Self.deliver(store, surface: surface, "a", podID: podID)
    #expect(store.state.summariesInFlight == [.session(surface), .pod(podID)])

    summariser.releaseOne()
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    await store.receive(\.summaryUpdated)
    #expect(store.state.file.boxes[id: surface]?.summary == "Summary")
    #expect(store.state.file.podSummaries[podID.rawValue.uuidString] == "Summary")
    let kinds = Set(summariser.requests.value.map { $0.systemPrompt.contains("pod of coding agents") })
    #expect(kinds == [true, false])

    await store.send(.podRemoved(podID))
    #expect(store.state.file.podSummaries[podID.rawValue.uuidString] == nil)
  }

  @Test(.dependencies) func aPodRemovedMidRunLeavesNoOrphanSummary() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    let podID = PodID(rawValue: UUID())
    await Self.deliver(store, surface: surface, "a", podID: podID)
    await store.send(.podRemoved(podID))
    #expect(store.state.summariesInFlight == [.session(surface)])
    summariser.releaseOne()
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    await store.finish()
    #expect(store.state.file.boxes[id: surface]?.summary == "Summary")
    #expect(store.state.file.podSummaries.isEmpty)
  }

  @Test(.dependencies) func aFailedRunLogsAndRetriesOnlyWhatArrivedMeanwhile() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    summariser.reply.setValue(.failure(.emptyResult))
    await Self.deliver(store, surface: surface, "a")
    summariser.releaseOne()
    await store.receive(\.summaryFailed)
    #expect(store.state.summariesInFlight.isEmpty)
    #expect(store.state.file.boxes[id: surface]?.summary == nil)
    #expect(summariser.requests.value.count == 1)
  }

  @Test(.dependencies) func anEndedSessionDropsItsRunAndItsQueue() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    await Self.deliver(store, surface: surface, "a")
    await Self.deliver(store, surface: surface, "b")
    await store.send(.sessionEnded(surfaceID: surface))
    #expect(store.state.summariesInFlight.isEmpty)
    #expect(store.state.pendingSummaryInput.isEmpty)
    summariser.releaseOne()
    await store.finish()
    #expect(store.state.file.boxes.isEmpty)
  }

  @Test(.dependencies) func aPodMembersLineCarriesItsName() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    let podID = PodID(rawValue: UUID())
    await store.send(
      .received(
        surfaceID: surface, worktreeID: Self.worktreeID, agent: .claude, body: "a", podID: podID, memberName: "Alpha"))
    summariser.releaseOne()
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    await store.receive(\.summaryUpdated)
    #expect(summariser.requests.value.allSatisfy { $0.prompt.contains("<message>\nAlpha: a\n</message>") })
  }

  @Test(.dependencies) func summariesOffQueuesNothing() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    store.state.$settingsFile.withLock { $0.global.threadSummaryModel = .off }
    await Self.deliver(store, surface: UUID(), "a")
    #expect(store.state.summariesInFlight.isEmpty)
    #expect(store.state.pendingSummaryInput.isEmpty)
    #expect(summariser.requests.value.isEmpty)
  }

  @Test(.dependencies) func switchingOffMidRunDropsTheQueue() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    await Self.deliver(store, surface: surface, "a")
    await Self.deliver(store, surface: surface, "b")
    store.state.$settingsFile.withLock { $0.global.threadSummaryModel = .off }
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    #expect(store.state.summariesInFlight.isEmpty)
    #expect(store.state.pendingSummaryInput.isEmpty)
    #expect(summariser.requests.value.count == 1)
  }

  @Test(.dependencies) func aLongReplyIsCappedBeforeItIsStored() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    summariser.reply.setValue(.success(String(repeating: "s", count: 1000)))
    await Self.deliver(store, surface: surface, "a")
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    let summary = store.state.file.boxes[id: surface]?.summary ?? ""
    #expect(summary.count <= SummaryPrompt.cap(for: .session))
    #expect(summary.hasSuffix("…"))
  }

  @Test(.dependencies) func aFailedRunRetriesWithWhatArrivedMeanwhile() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    summariser.reply.setValue(.failure(.emptyResult))
    await Self.deliver(store, surface: surface, "a")
    await Self.deliver(store, surface: surface, "b")
    summariser.releaseOne()
    await store.receive(\.summaryFailed)
    #expect(store.state.summariesInFlight == [.session(surface)])
    #expect(store.state.pendingSummaryInput[.session(surface)] == nil)
    let requests = summariser.requests.value
    #expect(requests.count == 2)
    #expect(requests[1].prompt.contains("Agent: b"))
    #expect(!requests[1].prompt.contains("Agent: a"))
  }

  @Test(.dependencies) func anEmptyReplyLeavesTheSummaryAlone() async {
    let summariser = Summariser()
    let store = Self.makeStore(summariser)
    let surface = UUID()
    summariser.reply.setValue(.success(""))
    await Self.deliver(store, surface: surface, "a")
    summariser.releaseOne()
    await store.receive(\.summaryUpdated)
    #expect(store.state.file.boxes[id: surface]?.summary == nil)
  }
}

struct ThreadSummaryClientTests {
  private static func outcome(_ request: SummaryPrompt.Request) async -> Result<String, any Error> {
    do {
      return .success(try await ThreadSummaryClient.liveValue.summarize(request))
    } catch {
      return .failure(error)
    }
  }

  @Test(.dependencies) func aStalledRunIsKilledAtTheDeadline() async throws {
    let clock = TestClock()
    let terminated = LockIsolated(false)
    let request = SummaryPrompt.request(kind: .session, previous: nil, newMessages: ["m"], model: .haiku, effort: .low)
    let outcome = await withDependencies {
      $0.continuousClock = clock
      $0.shellClient.runLoginProcessImpl = { _, arguments, _, _ in
        let (events, continuation) = AsyncThrowingStream<ShellStreamEvent, Error>.makeStream()
        return StreamingShellProcess(events: events) {
          terminated.setValue(true)
          continuation.finish(
            throwing: ShellClientError(command: arguments.joined(separator: " "), stdout: "", stderr: "", exitCode: 143)
          )
        }
      }
    } operation: {
      async let result = Self.outcome(request)
      await clock.advance(by: ThreadSummaryClient.timeout)
      return await result
    }
    #expect(terminated.value)
    #expect(throws: ThreadSummaryError.timedOut) { try outcome.get() }
  }

  @Test(.dependencies) func aFailedRunReportsStderrNotTheCommand() async {
    let request = SummaryPrompt.request(
      kind: .session, previous: nil, newMessages: ["secret"], model: .haiku, effort: .low)
    let outcome = await withDependencies {
      $0.continuousClock = TestClock()
      $0.shellClient.runLoginProcessImpl = { _, arguments, _, _ in
        let (events, continuation) = AsyncThrowingStream<ShellStreamEvent, Error>.makeStream()
        continuation.finish(
          throwing: ShellClientError(
            command: arguments.joined(separator: " "), stdout: "", stderr: "not logged in", exitCode: 1))
        return StreamingShellProcess(events: events) {}
      }
    } operation: {
      await Self.outcome(request)
    }
    #expect(throws: ThreadSummaryError.claudeFailed(status: 1, detail: "not logged in")) { try outcome.get() }
  }
}
