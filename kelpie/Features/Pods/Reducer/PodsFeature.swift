import ComposableArchitecture
import Foundation
import KelpieSettingsShared

/// Agent pods: named groups of Claude Code sessions that know about each other.
/// Owns the pods, the registration handshake, and the per-surface prompt
/// queue. Kelpie only types its own setup prompts, one at a time and only into
/// an idle agent; the agents message each other with Claude's own tools.
@Reducer
struct PodsFeature {
  /// How long a member has to report its session name once the register
  /// prompt is typed in.
  static let registrationTimeout: Duration = .seconds(120)
  /// How long a member's Claude presence may vanish before it leaves the pod.
  /// Covers `/clear`, which ends one session and starts the next.
  static let departureGrace: Duration = .seconds(10)
  /// A delivered prompt normally turns the agent busy within a second. If it
  /// never does, the next prompt goes out after this long anyway.
  static let turnLatchTimeout: Duration = .seconds(30)

  nonisolated enum CancelID: Hashable, Sendable {
    case registrationTimeout(UUID)
    case departure(UUID)
    case turnLatch(UUID)
  }

  @ObservableState
  struct State: Equatable {
    var pods: IdentifiedArrayOf<Pod> = []
    /// Last known Claude activity of every tracked surface.
    var memberActivity: [UUID: AgentPresenceFeature.Activity] = [:]
    /// Prompts waiting for their surface's agent to go idle, oldest first.
    var queue: [UUID: [QueuedPrompt]] = [:]
    /// Surfaces sent a prompt whose agent has not started on it yet. Nothing
    /// else goes to them until they do, so prompts never land back to back.
    var awaitingTurn: Set<UUID> = []
    var structure: PodStructure = .empty
    @Presents var editor: PodEditorFeature.State?

    var memberSurfaceIDs: Set<UUID> { Set(pods.flatMap(\.members.ids)) }

    /// Surfaces whose presence changes matter: members, and former members
    /// still owed a prompt.
    var trackedSurfaceIDs: Set<UUID> { memberSurfaceIDs.union(queue.keys) }

    func podID(containing surfaceID: UUID) -> PodID? {
      pods.first { $0.members[id: surfaceID] != nil }?.id
    }

    /// Stores a freshly computed structure when it changed. Called from the
    /// parent's post-reduce step.
    mutating func applyStructure(_ next: PodStructure) {
      guard next != structure else { return }
      structure = next
    }
  }

  enum Action: Equatable {
    case newPodTapped
    case addMembersTapped(PodID)
    case openTapped(PodID)
    case disbandTapped(PodID)
    case editor(PresentationAction<PodEditorFeature.Action>)
    /// A member reported its session name through `kelpie pod register`.
    case registered(surfaceID: UUID, sessionName: String)
    /// A tracked surface's Claude activity changed; nil when its presence ended.
    case memberActivityChanged(surfaceID: UUID, activity: AgentPresenceFeature.Activity?)
    case promptDelivered(surfaceID: UUID, QueuedPrompt.Kind)
    case promptDeliveryFailed(surfaceID: UUID, QueuedPrompt)
    case registrationTimedOut(surfaceID: UUID)
    case departureGraceElapsed(surfaceID: UUID)
    case turnLatchExpired(surfaceID: UUID)
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case openWorkspace(PodID)
    case podRemoved(PodID)
  }

  @Dependency(\.continuousClock) private var clock
  @Dependency(TerminalClient.self) private var terminalClient
  @Dependency(\.uuid) private var uuid

  private static let logger = KelpieLogger("PodsFeature")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .newPodTapped:
        state.editor = PodEditorFeature.State(mode: .create, candidates: state.structure.candidates)
        return .none

      case .addMembersTapped(let podID):
        guard let pod = state.pods[id: podID] else { return .none }
        state.editor = PodEditorFeature.State(
          mode: .addMembers(podID), podName: pod.name, podDescription: pod.description,
          candidates: state.structure.candidates)
        return .none

      case .openTapped(let podID):
        guard state.pods[id: podID] != nil else { return .none }
        return .send(.delegate(.openWorkspace(podID)))

      case .disbandTapped(let podID):
        return disband(podID, &state)

      case .editor(.presented(.delegate(.create(let name, let description, let drafts)))):
        let podID = PodID(rawValue: uuid())
        state.pods.append(Pod(id: podID, name: name, description: description, members: []))
        return addMembers(drafts, to: podID, &state)

      case .editor(.presented(.delegate(.addMembers(let podID, let drafts)))):
        return addMembers(drafts, to: podID, &state)

      case .editor:
        return .none

      case .registered(let surfaceID, let sessionName):
        guard let podID = state.podID(containing: surfaceID) else { return .none }
        state.pods[id: podID]?.members[id: surfaceID]?.registration = .registered(sessionName: sessionName)
        return .merge(.cancel(id: CancelID.registrationTimeout(surfaceID)), settle(podID, &state))

      case .registrationTimedOut(let surfaceID):
        guard let podID = state.podID(containing: surfaceID),
          state.pods[id: podID]?.members[id: surfaceID]?.registration == .pending
        else { return .none }
        Self.logger.info("Pod member \(surfaceID) did not register in time; marking unreachable.")
        state.pods[id: podID]?.members[id: surfaceID]?.registration = .unreachable
        return settle(podID, &state)

      case .memberActivityChanged(let surfaceID, let activity):
        return reduceActivityChanged(surfaceID, activity, &state)

      case .promptDelivered(let surfaceID, let kind):
        guard state.memberSurfaceIDs.contains(surfaceID) else {
          // A former member got its last prompt; stop tracking it.
          if state.queue[surfaceID] == nil {
            state.awaitingTurn.remove(surfaceID)
            state.memberActivity[surfaceID] = nil
          }
          return .none
        }
        var effects: [Effect<Action>] = [
          .run { [clock] send in
            try await clock.sleep(for: Self.turnLatchTimeout)
            await send(.turnLatchExpired(surfaceID: surfaceID))
          }
          .cancellable(id: CancelID.turnLatch(surfaceID), cancelInFlight: true)
        ]
        if kind == .register,
          let podID = state.podID(containing: surfaceID),
          state.pods[id: podID]?.members[id: surfaceID]?.registration == .pending
        {
          effects.append(
            .run { [clock] send in
              try await clock.sleep(for: Self.registrationTimeout)
              await send(.registrationTimedOut(surfaceID: surfaceID))
            }
            .cancellable(id: CancelID.registrationTimeout(surfaceID), cancelInFlight: true))
        }
        return .merge(effects)

      case .promptDeliveryFailed(let surfaceID, let prompt):
        state.awaitingTurn.remove(surfaceID)
        // A newer roster queued meanwhile supersedes the one that failed.
        var prompts = state.queue[surfaceID] ?? []
        if prompt.kind != .roster || !prompts.contains(where: { $0.kind == .roster }) {
          prompts.insert(prompt, at: 0)
        }
        state.queue[surfaceID] = prompts
        return .none

      case .departureGraceElapsed(let surfaceID):
        guard state.memberActivity[surfaceID] == nil, let podID = state.podID(containing: surfaceID) else {
          return .none
        }
        Self.logger.info("Pod member \(surfaceID) left: its Claude session ended.")
        state.pods[id: podID]?.members.remove(id: surfaceID)
        state.queue[surfaceID] = nil
        state.awaitingTurn.remove(surfaceID)
        return .merge(
          .cancel(id: CancelID.registrationTimeout(surfaceID)),
          .cancel(id: CancelID.turnLatch(surfaceID)),
          settle(podID, &state))

      case .turnLatchExpired(let surfaceID):
        state.awaitingTurn.remove(surfaceID)
        return flush(surfaceID, &state)

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$editor, action: \.editor) {
      PodEditorFeature()
    }
  }

  private func addMembers(_ drafts: [PodMemberDraft], to podID: PodID, _ state: inout State) -> Effect<Action> {
    guard let pod = state.pods[id: podID] else { return .none }
    // A session joins one pod at a time; one picked in a stale sheet is skipped.
    let taken = state.memberSurfaceIDs
    let joining = drafts.filter { !taken.contains($0.id) }
    var effects: [Effect<Action>] = []
    for draft in joining {
      state.pods[id: podID]?.members.append(
        PodMember(id: draft.id, worktreeID: draft.worktreeID, name: draft.name, description: draft.description))
      if let activity = state.structure.candidates.first(where: { $0.id == draft.id })?.activity {
        state.memberActivity[draft.id] = activity
      }
      Self.enqueue(
        QueuedPrompt(
          kind: .register,
          text: PodPrompt.register(podName: pod.name, memberName: draft.name, surfaceID: draft.id)),
        for: draft.id, in: &state)
      effects.append(flush(draft.id, &state))
    }
    // A create that lost its members to another pod leaves nothing to form.
    effects.append(settle(podID, &state))
    return .merge(effects)
  }

  private func reduceActivityChanged(
    _ surfaceID: UUID,
    _ activity: AgentPresenceFeature.Activity?,
    _ state: inout State
  ) -> Effect<Action> {
    let isMember = state.podID(containing: surfaceID) != nil
    guard let activity else {
      state.memberActivity[surfaceID] = nil
      guard isMember else {
        // A former member whose session ended has no one left to tell.
        state.queue[surfaceID] = nil
        state.awaitingTurn.remove(surfaceID)
        return .cancel(id: CancelID.turnLatch(surfaceID))
      }
      return .run { [clock] send in
        try await clock.sleep(for: Self.departureGrace)
        await send(.departureGraceElapsed(surfaceID: surfaceID))
      }
      .cancellable(id: CancelID.departure(surfaceID), cancelInFlight: true)
    }
    guard isMember || state.queue[surfaceID] != nil else { return .none }
    state.memberActivity[surfaceID] = activity
    var effects: [Effect<Action>] = [.cancel(id: CancelID.departure(surfaceID))]
    // The agent started a turn, so the prompt it was sent has landed.
    if activity != .idle, state.awaitingTurn.remove(surfaceID) != nil {
      effects.append(.cancel(id: CancelID.turnLatch(surfaceID)))
    }
    effects.append(flush(surfaceID, &state))
    return .merge(effects)
  }

  /// Sends a surface its next queued prompt when its agent is idle and has
  /// started on the previous one.
  private func flush(_ surfaceID: UUID, _ state: inout State) -> Effect<Action> {
    guard state.memberActivity[surfaceID] == .idle, !state.awaitingTurn.contains(surfaceID),
      var prompts = state.queue[surfaceID], !prompts.isEmpty
    else { return .none }
    let prompt = prompts.removeFirst()
    state.queue[surfaceID] = prompts.isEmpty ? nil : prompts
    state.awaitingTurn.insert(surfaceID)
    return .run { [terminalClient] send in
      let delivered = await terminalClient.deliverPrompt(surfaceID, prompt.text)
      await send(
        delivered
          ? .promptDelivered(surfaceID: surfaceID, prompt.kind)
          : .promptDeliveryFailed(surfaceID: surfaceID, prompt))
    }
  }

  /// Once no member is pending, sends every registered member the roster if it
  /// changed. A pod that can no longer hold two podmates disbands.
  private func settle(_ podID: PodID, _ state: inout State) -> Effect<Action> {
    guard let pod = state.pods[id: podID] else { return .none }
    guard pod.members.count >= 2 else { return disband(podID, &state) }
    guard !pod.hasPendingMembers else { return .none }
    let roster = pod.roster
    guard roster.count >= 2 else { return disband(podID, &state) }
    guard roster != pod.sentRoster else { return .none }
    state.pods[id: podID]?.sentRoster = roster
    let effects = pod.members.compactMap { member -> Effect<Action>? in
      guard let sessionName = member.sessionName else { return nil }
      let you = PodPrompt.Podmate(id: sessionName, name: member.name, description: member.description)
      let text = PodPrompt.roster(
        podName: pod.name, podDescription: pod.description, you: you, podmates: roster.filter { $0 != you })
      Self.enqueue(QueuedPrompt(kind: .roster, text: text), for: member.id, in: &state)
      return flush(member.id, &state)
    }
    return .merge(effects)
  }

  /// Removes the pod and tells every member that heard from it that it is gone.
  private func disband(_ podID: PodID, _ state: inout State) -> Effect<Action> {
    guard let pod = state.pods.remove(id: podID) else { return .none }
    Self.logger.info("Disbanding pod \(pod.name).")
    var effects: [Effect<Action>] = [.send(.delegate(.podRemoved(podID)))]
    for member in pod.members {
      effects.append(.cancel(id: CancelID.registrationTimeout(member.id)))
      effects.append(.cancel(id: CancelID.departure(member.id)))
      let neverHeard = state.queue[member.id]?.contains { $0.kind == .register } ?? false
      guard !neverHeard, state.memberActivity[member.id] != nil else {
        state.queue[member.id] = nil
        state.memberActivity[member.id] = nil
        continue
      }
      state.queue[member.id] = [QueuedPrompt(kind: .disbanded, text: PodPrompt.disbanded(podName: pod.name))]
      effects.append(flush(member.id, &state))
    }
    return .merge(effects)
  }

  /// Queues a prompt. A newer roster replaces one still waiting.
  private static func enqueue(_ prompt: QueuedPrompt, for surfaceID: UUID, in state: inout State) {
    var prompts = state.queue[surfaceID] ?? []
    if prompt.kind == .roster {
      prompts.removeAll { $0.kind == .roster }
    }
    prompts.append(prompt)
    state.queue[surfaceID] = prompts
  }
}
