/// Hook events emitted via the JSON envelope path. Activity events
/// (`busy`, `awaitingInput`, `idle`, `error`, `compacting`) are atomic
/// state-set. Each fires the corresponding (surface, agent) activity
/// directly; repeated events are idempotent. The notification leg is composed
/// in alongside an envelope by `compositeCommand(forwardStdinAsNotification:)`.
nonisolated enum HookEvent: String, CaseIterable {
  case sessionStart = "session_start"
  case sessionEnd = "session_end"
  case busy
  case awaitingInput = "awaiting_input"
  case idle
  /// Turn ended in an API / connection error, read from the transcript rather
  /// than from terminal text.
  case error
  /// Context compaction started (Claude `PreCompact`).
  case compacting
}

nonisolated enum AgentHookSettingsCommand {
  /// Kelpie hooks only emit a small OSC payload, so a longer deadline buys the
  /// healthy path nothing and turns a wedged stdin or PTY into a visible agent stall.
  static let timeoutSeconds = 2

  static let timeoutMilliseconds = timeoutSeconds * 1_000

  /// Sentinel comment appended to every Kelpie-installed hook command.
  /// `AgentHookCommandOwnership` uses this (and ONLY this) to identify
  /// managed commands. `KELPIE_SOCKET_PATH` is documented public API
  /// (CLI skill env table, Pi extension example, deeplink reference), so
  /// matching on the env-var name alone would silently strip user-authored
  /// hooks that legitimately reference it.
  static let ownershipMarker = "# kelpie-managed-hook"

  /// Documented public env var. Used as ONE half of the legacy CLI-shim
  /// fingerprint (paired with `kelpie integration event`); never matched
  /// alone. User-authored hooks reference it legitimately.
  static let socketPathEnvVar = "KELPIE_SOCKET_PATH"

  /// Markers present in legacy Kelpie hook commands (pre-socket).
  static let legacyCLIPathEnvVar = "KELPIE_CLI_PATH"
  static let legacyAgentHookMarker = "agent-hook"

  /// Verbatim 4-var presence-guard at the head of every Kelpie-installed
  /// hook. Carried forward unchanged across every command-shape revision,
  /// so it doubles as the pre-sentinel legacy fingerprint. A user-authored
  /// hook following the documented `KELPIE_SOCKET_PATH`-only pattern
  /// (single-var check) does not match. A user who copied this guard
  /// verbatim AND removed the trailing sentinel intentionally would be
  /// treated as legacy. That's the deliberate trade for catching every
  /// pre-envelope shape of older Kelpie hook.
  static let envCheck =
    #"[ -n "${KELPIE_SOCKET_PATH:-}" ]"#
    + #" && [ -n "${KELPIE_WORKTREE_ID:-}" ]"#
    + #" && [ -n "${KELPIE_TAB_ID:-}" ]"#
    + #" && [ -n "${KELPIE_SURFACE_ID:-}" ]"#

  /// Composes the OSC 3008 hook command: one guard, then (once that passes) the
  /// tty resolve plus a presence emit per event and/or a notify emit, all in a
  /// single brace group whose output is suppressed. Guarding first keeps the
  /// command truly inert outside Kelpie (no `ps` runs when the surface id is
  /// unset). The precondition rejects a no-op invocation that would emit nothing.
  static func compositeCommand(
    events: [HookEvent],
    forwardStdinAsNotification: Bool,
    agent: SkillAgent
  ) -> String {
    precondition(
      !events.isEmpty || forwardStdinAsNotification,
      "compositeCommand needs at least one side-effect (events or stdin forward).",
    )
    var steps: [String] = [AgentPresenceOSC.ttyResolveSnippet]
    steps += events.map { AgentPresenceOSC.emitShell(event: $0, agent: agent) }
    if forwardStdinAsNotification { steps.append(AgentPresenceOSC.emitNotifyShell(agent: agent)) }
    return guardedCommand(steps: steps)
  }

  /// The one hook command shape: guard, then the steps in a brace group with all
  /// output suppressed, then the ownership marker.
  private static func guardedCommand(steps: [String]) -> String {
    "\(oscGuardExpr) && { \(steps.joined(separator: "; ")); } >/dev/null 2>&1 || true \(ownershipMarker)"
  }

  /// Shell variable the Claude transcript probe fills with the `;model=…;effort=…`
  /// presence-metadata suffix (empty when unknown).
  private static let sessionMetadataVariable = "$__me"

  /// Claude `Stop`: probes the transcript for a current-turn API error and emits
  /// `.error` plus a fixed restart notify when it finds one, else `.idle` plus the
  /// usual stdin-sourced notify. Claude reports an API error through a plain `Stop`,
  /// so without the probe a dead turn is indistinguishable from a completed one.
  /// Both presence emits carry the session model / effort the probe read.
  static func claudeStopCommand(agent: SkillAgent) -> String {
    let errorBranch =
      "\(AgentPresenceOSC.emitShell(event: .error, agent: agent, metadataSuffixVariable: sessionMetadataVariable)); "
      + AgentPresenceOSC.emitFixedNotifyShell(
        agent: agent, title: Self.errorNotifyTitle, body: Self.errorNotifyBody)
    let idleBranch =
      "\(AgentPresenceOSC.emitShell(event: .idle, agent: agent, metadataSuffixVariable: sessionMetadataVariable)); "
      + AgentPresenceOSC.emitNotifyShell(agent: agent, readsStdin: false)
    let steps: [String] = [
      AgentPresenceOSC.ttyResolveSnippet,
      AgentPresenceOSC.stopTranscriptProbeShell(),
      #"if [ -n "$__apierr" ]; then \#(errorBranch); else \#(idleBranch); fi"#,
    ]
    return guardedCommand(steps: steps)
  }

  /// Claude `SessionStart`: probes the transcript named in the hook payload for
  /// the session's model / effort and emits `.sessionStart` carrying them, so a
  /// resumed session shows its model before its first turn. A fresh session has
  /// no transcript yet and emits the plain event.
  static func claudeSessionStartCommand(agent: SkillAgent) -> String {
    let steps: [String] = [
      AgentPresenceOSC.ttyResolveSnippet,
      AgentPresenceOSC.sessionStartProbeShell(),
      AgentPresenceOSC.emitShell(
        event: .sessionStart, agent: agent, metadataSuffixVariable: sessionMetadataVariable),
    ]
    return guardedCommand(steps: steps)
  }

  /// Fixed headline / body for the error notification the Stop hook raises.
  static let errorNotifyTitle = "Agent error"
  static let errorNotifyBody = "Session stopped on an error"

  /// Guard for the OSC command: a surface id present (the no-op-outside-Kelpie
  /// gate). Fires both locally and over SSH; the pid suffix inside the presence
  /// emit is what's gated on the socket path, not the emission itself.
  private static var oscGuardExpr: String {
    #"[ -n "${\#(AgentPresenceOSC.surfaceEnvVar):-}" ]"#
  }

  /// Env vars Grok must forward into hook subprocesses. Grok spawns hooks without
  /// inheriting the terminal's `KELPIE_*` env; `${VAR}` expansion copies from
  /// the parent Grok process at spawn time. Presence strictly needs
  /// `KELPIE_SURFACE_ID` (OSC guard) and uses `KELPIE_SOCKET_PATH` for the
  /// local pid suffix; the remaining vars match the terminal env for parity
  /// with other agents / future hooks.
  static let grokHookEnvPassthrough: [String: String] = [
    "KELPIE_SURFACE_ID": "${KELPIE_SURFACE_ID}",
    "KELPIE_SOCKET_PATH": "${KELPIE_SOCKET_PATH}",
    "KELPIE_TAB_ID": "${KELPIE_TAB_ID}",
    "KELPIE_WORKTREE_ID": "${KELPIE_WORKTREE_ID}",
    "KELPIE_REPO_ID": "${KELPIE_REPO_ID}",
    "KELPIE_ROOT_PATH": "${KELPIE_ROOT_PATH}",
    "KELPIE_WORKTREE_PATH": "${KELPIE_WORKTREE_PATH}",
  ]
}
