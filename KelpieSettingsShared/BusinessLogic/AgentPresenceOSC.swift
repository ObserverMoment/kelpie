import Foundation

/// OSC 3008 (UAPI hierarchical context signal) wire format that carries the
/// agent-presence event lifecycle over the terminal stream, so the badge tracks
/// state over SSH where the local Unix socket can't be reached. The sequence is
/// inert in any terminal that doesn't handle OSC 3008 (no toast, no side effect).
///
/// Emit shape: `OSC 3008 ; <action>=<agent> ; event=<event>[ ; pid=<pid>] ST`.
/// libghostty splits that into `id = <agent>` (the context id, up to the first
/// `;`) and `metadata = "event=<event>[;pid=<pid>]"`, which is what `parse`
/// receives. `parse` derives the event solely from the `event=` field and ignores
/// the start/end action byte.
/// - attribution is by the receiving surface, so no surface id is carried;
/// - `event` is the `HookEvent` rawValue;
/// - `pid` is the agent's LOCAL process id, present only when the hook ran on the
///   same host (gated on `KELPIE_SOCKET_PATH`); it feeds the app's liveness
///   sweep so a crashed local agent is reaped. Omitted over SSH.
///
/// The same transport also carries the rich notification leg
/// (`kind=notify;title=<base64>;body=<base64>`); the emitter extracts the display
/// title/body so the wire stays small and the app carries no agent-specific JSON
/// shape. Presence and notify are disjoint metadata shapes.
///
/// Signals are unauthenticated: anything that can write to the terminal can emit
/// one, and the worst case is a spurious badge or notification (text is
/// control-char-sanitized and length-capped app-side). Emission is gated on
/// `KELPIE_SURFACE_ID` so it no-ops outside a Kelpie surface.
///
/// Single source of truth for both the emit side (the agent hook) and the parse
/// side (the app), so the field names can't drift.
public nonisolated enum AgentPresenceOSC {
  /// Env var present only on Kelpie surfaces, so its presence is the
  /// no-op-outside-Kelpie emit gate.
  public static let surfaceEnvVar = "KELPIE_SURFACE_ID"

  static let eventField = "event"
  static let pidField = "pid"
  /// Claude session metadata (`model=` / `effort=`), read from the transcript
  /// in shell by the SessionStart and Stop hooks. Public so the app-side
  /// event payload uses the same keys.
  public static let modelField = "model"
  public static let effortField = "effort"
  static let kindField = "kind"
  static let titleField = "title"
  static let bodyField = "body"
  static let notifyKind = "notify"

  /// Notify body source keys, in display precedence. Used by the shell extractor
  /// (`emitNotifyShell`); the Pi extension sends its body directly.
  public static let notifyBodyKeys = ["message", "last_assistant_message", "assistant_response"]

  /// Emit-side byte caps. Keep the notify metadata under libghostty's 2048-byte
  /// OSC buffer, over which the whole sequence is discarded (not truncated).
  static let notifyBodyByteBudget = 1000
  static let notifyTitleByteBudget = 160

  /// A parsed presence signal.
  public struct Signal: Equatable, Sendable {
    /// Context id, i.e. the agent rawValue.
    public let agent: String
    /// A known HookEvent rawValue. Parse rejects unknown values; stored as
    /// String so wire concerns don't leak into the enum.
    public let eventRawValue: String
    /// The agent's LOCAL process id. The emit gates it on `KELPIE_SOCKET_PATH`
    /// so a local hook carries it and a remote one omits it; a forged positive
    /// pid at worst pins a live-looking badge until surface close.
    public let pid: pid_t?
    /// Claude's session model / effort as the hook read them from the
    /// transcript. nil when the emitter had none or the value falls outside the
    /// `[A-Za-z0-9._-]{1,64}` wire alphabet; a bad value never fails the signal.
    public let model: String?
    public let effort: String?
  }

  /// Parse the OSC 3008 context id + raw key=value metadata (as surfaced by
  /// libghostty) into a `Signal`. Returns nil for anything that isn't a
  /// well-formed presence signal with a known event.
  public static func parse(id: String, metadata: String) -> Signal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard
      let rawEvent = fields[Substring(eventField)],
      HookEvent(rawValue: String(rawEvent)) != nil
    else { return nil }
    return Signal(
      agent: id,
      eventRawValue: String(rawEvent),
      pid: parsePid(fields[Substring(pidField)]),
      model: parseSessionToken(fields[Substring(modelField)]),
      effort: parseSessionToken(fields[Substring(effortField)]),
    )
  }

  /// Parse an optional `model=` / `effort=` token: 1...`sessionTokenByteCap`
  /// bytes of `[A-Za-z0-9._-]`. Anything else reads as absent so the presence
  /// event still lands when a suffix is mangled.
  private static func parseSessionToken(_ raw: Substring?) -> String? {
    guard let raw, (1...sessionTokenByteCap).contains(raw.utf8.count),
      raw.utf8.allSatisfy(isSessionTokenByte)
    else { return nil }
    return String(raw)
  }

  private static func isSessionTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
      UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
      return true
    default:
      return false
    }
  }

  /// Parse the optional `pid=` field. Rejects non-numeric and non-positive
  /// values: a 0 / negative pid would let `kill(_:0)` match the caller's process
  /// group and pin a permanent badge in the liveness sweep.
  private static func parsePid(_ raw: Substring?) -> pid_t? {
    guard let raw, let value = pid_t(raw), value > 0 else { return nil }
    return value
  }

  /// True when the metadata carries `kind=notify`. Cheap routing check (presence
  /// vs notify) that inspects the `kind` field, not a raw substring, so a base64
  /// `body` value that happens to contain "kind=notify" can't misroute.
  public static func isNotifyMetadata(_ metadata: String) -> Bool {
    parseFields(metadata)?[Substring(kindField)] == Substring(notifyKind)
  }

  /// Split the OSC 3008 raw metadata into its `key=value` fields. Standard base64
  /// values are framing-safe here: their alphabet (A-Za-z0-9+/=) has no `;`, and
  /// the value keeps everything after the FIRST `=` (`firstIndex(of:)`), so base64
  /// `=` padding survives intact.
  ///
  /// Duplicate `event` / `kind` keys are rejected: a repeated key would otherwise
  /// pin perceived state to the last occurrence, which a splice into the wire
  /// could exploit to flip `event=` or inject `kind=notify`. All other duplicate
  /// keys keep the historical last-write-wins behavior.
  public static func parseFields(_ metadata: String) -> [Substring: Substring]? {
    var fields: [Substring: Substring] = [:]
    for pair in metadata.split(separator: ";", omittingEmptySubsequences: true) {
      guard let equalsIndex = pair.firstIndex(of: "=") else { continue }
      let key = pair[..<equalsIndex]
      if fields[key] != nil, Self.dedupedFields.contains(key) {
        return nil
      }
      fields[key] = pair[pair.index(after: equalsIndex)...]
    }
    return fields
  }

  private static let dedupedFields: Set<Substring> = [
    Substring(eventField), Substring(kindField),
  ]

  /// A parsed notification signal with already-decoded display text.
  public struct NotifySignal: Equatable, Sendable {
    public let agent: String
    /// Both nil-on-empty; the caller falls back to the agent name for a missing
    /// title and shows a title-only toast for a missing body.
    public let title: String?
    public let body: String?
    /// Raw base64 byte count of the body field on the wire, before decode. A
    /// non-zero count alongside a nil `body` means a truncation the shed loop
    /// couldn't recover, so the caller can log the silent-failure case.
    public let wireBodyByteCount: Int
  }

  /// Parse `kind=notify;title=<base64>;body=<base64>`. Requires the notify kind;
  /// title/body are optional.
  public static func parseNotify(id: String, metadata: String) -> NotifySignal? {
    guard !id.isEmpty else { return nil }
    guard let fields = parseFields(metadata) else { return nil }
    guard fields[Substring(kindField)] == Substring(notifyKind) else { return nil }
    return NotifySignal(
      agent: id,
      title: decodedNotifyField(fields[Substring(titleField)]),
      body: decodedNotifyField(fields[Substring(bodyField)]),
      wireBodyByteCount: fields[Substring(bodyField)]?.utf8.count ?? 0,
    )
  }

  private static func decodedNotifyField(_ raw: Substring?) -> String? {
    guard let raw, let text = decodeNotifyValue(String(raw)), !text.isEmpty else { return nil }
    return text
  }

  /// Reverse one base64 notify field back to display text. A field byte-capped at
  /// emit can end mid-escape or mid-UTF8, so trailing bytes are shed until the
  /// quoted value parses as a JSON string (`JSONDecoder` rejects both an invalid
  /// UTF-8 tail and a dangling escape). nil only on non-base64 input; an
  /// undecodable-but-base64 field collapses to "" (treated as absent, not a
  /// parse failure).
  static func decodeNotifyValue(_ base64: String) -> String? {
    guard var data = Data(base64Encoded: base64) else { return nil }
    let quote = Data([0x22])
    let decoder = JSONDecoder()
    // 12 = full `\uXXXX\uXXXX` surrogate-pair length; covers any mid-pair cut (worst dangling tail is 11 bytes).
    for _ in 0...min(12, data.count) {
      if let text = try? decoder.decode(String.self, from: quote + data + quote) {
        return text
      }
      if data.isEmpty { break }
      data.removeLast()
    }
    return ""
  }

  /// The OSC 3008 action for an event: session_end ends a context, everything
  /// else starts / updates one. The app keys off `event=` in the metadata, not
  /// this action, so it is descriptive rather than load-bearing.
  static func action(for event: HookEvent) -> String {
    event == .sessionEnd ? "end" : "start"
  }

  /// The `key=value` metadata a PRESENCE signal carries (everything after the
  /// context id). `parse` recovers the event from this exact shape. `pidSuffix`
  /// is appended verbatim (e.g. `;pid=123`) so the emit can splice in a
  /// shell-built, conditionally-empty suffix. See `notifyMetadata` for the
  /// notify counterpart.
  static func metadata(event: HookEvent, pidSuffix: String = "") -> String {
    "\(eventField)=\(event.rawValue)\(pidSuffix)"
  }

  /// Shell that resolves `$__ppid` (the hook's parent agent) and its `$__tty`, since
  /// hooks run with no controlling terminal and `ps` reports a bare tty name (`??`
  /// falls back to `/dev/tty`). `set -f` is load-bearing: that `??` is a glob.
  ///
  /// Neither `ps -o ppid= -p $$` (Grok collapses `$$` to a bare `$` when it rewrites
  /// the command) nor a bare `$PPID` (Grok preflights it as required env and skips
  /// the hook, #704) works; only the `:-` form survives to the runtime shell.
  /// A ppid of 0 or 1 is dropped: `kill(1, 0)`'s `EPERM` reads as alive to the
  /// liveness sweep and would pin the badge until surface close.
  static let ttyResolveSnippet =
    #"__ppid=${PPID:-}; "#
    + #"set -f; set -- $(ps -o tty= -p "$__ppid" 2>/dev/null); __tty=${1:-}; set +f; "#
    + #"case "$__ppid" in 0|1) __ppid="";; esac; "#
    + #"case "$__tty" in *[0-9]*) __tty="/dev/${__tty#/dev/}";; *) __tty="/dev/tty";; esac"#

  /// Shell `printf` that emits the OSC 3008 presence sequence for `event`. Written
  /// to the `$__tty` device resolved by `ttyResolveSnippet` so it reaches the
  /// terminal even though the hook has no controlling terminal and captured
  /// stdout. The caller guards emission on `KELPIE_SURFACE_ID` and runs
  /// `ttyResolveSnippet` first.
  ///
  /// The pid suffix is gated on `KELPIE_SOCKET_PATH` (set only on the local host)
  /// and on `$__ppid` having resolved, so a remote hook or a reparented shell leaves
  /// the field off the wire instead of sending a dangling `pid=`. Both shapes parse to
  /// `pid: nil` today, so this is wire hygiene, not a behavior fix: a local agent
  /// with no resolvable parent stays untracked by the liveness sweep either way. A
  /// forged positive pid at worst pins a live-looking badge until surface close. The
  /// suffix is built in shell and filled into a trailing `%s`.
  static func emitShell(event: HookEvent, agent: SkillAgent) -> String {
    presenceEmitShell(event: event, agent: agent, suffixArguments: [])
  }

  /// `emitShell` plus one more shell-built metadata suffix, spliced after the pid
  /// suffix from the expansion of `metadataSuffixVariable` (e.g. `"$__me"`, the
  /// transcript probe's `;model=…;effort=…`). It is a `printf` argument, never
  /// part of the format, so its bytes are inert to `printf`. A separate overload
  /// so every template built on `emitShell(event:agent:)` stays byte-identical.
  static func emitShell(event: HookEvent, agent: SkillAgent, metadataSuffixVariable: String) -> String {
    presenceEmitShell(event: event, agent: agent, suffixArguments: [metadataSuffixVariable])
  }

  private static func presenceEmitShell(
    event: HookEvent, agent: SkillAgent, suffixArguments: [String]
  ) -> String {
    // One trailing %s per shell-built, conditionally-empty suffix: the pid first.
    let arguments = ["$__sp"] + suffixArguments
    let meta = metadata(event: event, pidSuffix: String(repeating: "%s", count: arguments.count))
    let payload = #"\033]3008;\#(action(for: event))=\#(agent.rawValue);\#(meta)\033\\"#
    let quotedArguments = arguments.map { "\"\($0)\"" }.joined(separator: " ")
    return #"__sp=""; [ -n "${KELPIE_SOCKET_PATH:-}" ] && [ -n "$__ppid" ] "#
      + #"&& __sp=";\#(pidField)=$__ppid"; "#
      + #"printf '\#(payload)' \#(quotedArguments) > "$__tty""#
  }

  /// The `key=value` metadata a notify signal carries; `title` / `body` are base64.
  static func notifyMetadata(title: String, body: String) -> String {
    "\(kindField)=\(notifyKind);\(titleField)=\(title);\(bodyField)=\(body)"
  }

  /// Notify OSC whose `title` / `body` are base64-encoded when the command is
  /// composed, so the hook needs no runtime `base64` / `awk`. Standard base64
  /// carries no `;` or `%`, so it is framing- and `printf`-safe with no format args.
  static func emitFixedNotifyShell(agent: SkillAgent, title: String, body: String) -> String {
    let encodedTitle = Data(title.utf8).base64EncodedString()
    let encodedBody = Data(body.utf8).base64EncodedString()
    let payload =
      #"\033]3008;start=\#(agent.rawValue);\#(notifyMetadata(title: encodedTitle, body: encodedBody))\033\\"#
    return #"printf '\#(payload)' > "$__tty""#
  }

  /// Portable awk that extracts one JSON string value from the agent's hook JSON
  /// on stdin. `keys` is a comma-separated precedence list (first non-empty wins);
  /// the raw escaped value is copied verbatim up to the first unescaped `"` and
  /// capped to `budget` (a mid-escape cut is tolerated by `decodeNotifyValue`).
  /// Matches the first `"key":` occurrence, assuming a flat top-level payload.
  /// No `RS`/`\x` tricks and no single quote, so it is portable and shell-safe.
  /// The caller runs it under `LC_ALL=C` so `length`/`substr` are byte-based
  /// (gawk in a UTF-8 locale would otherwise count characters and overshoot 2048).
  /// Best-effort by design: a body nested inside an object (e.g. the key appears
  /// in an inner object before the top-level one) is not extracted correctly. The
  /// agents we target emit flat payloads; the structured Pi extension path is the
  /// canonical one when a nested shape is needed.
  static let notifyExtractAwk =
    #"function ws(c){return c==" "||c=="\t"||c=="\n"||c=="\r"}"#
    + #"function fv(s,key,  p,i,n,c,o,e){p="\""key"\"";i=index(s,p);if(i==0)return "";"#
    + #"i+=length(p);n=length(s);while(i<=n){if(ws(substr(s,i,1)))i++;else break}"#
    + #"if(substr(s,i,1)!=":")return "";i++;while(i<=n){if(ws(substr(s,i,1)))i++;else break}"#
    + #"if(substr(s,i,1)!="\"")return "";i++;o="";e=0;while(i<=n){c=substr(s,i,1);"#
    + #"if(e){o=o c;e=0;i++;continue}if(c=="\\"){o=o c;e=1;i++;continue}if(c=="\"")break;o=o c;i++}return o}"#
    + #"{d=d $0}END{n=split(keys,ks,",");v="";for(j=1;j<=n;j++){v=fv(d,ks[j]);if(v!="")break}"#
    + #"if(length(v)>budget+0)v=substr(v,1,budget+0);printf "%s",v}"#

  /// Captures the hook's JSON payload from stdin into `$__in`. One `read` returns at
  /// the newline terminating the single-line object every agent we target writes, so
  /// a host holding the pipe open does not wedge the hook; a payload with no trailing
  /// newline still blocks to the deadline, which no portable shell read avoids. A
  /// line not ending in `}` (pretty-printed JSON) drains the rest, since a truncated
  /// payload silently empties every extracted field.
  static let readStdinSnippet =
    #"IFS= read -r __in || true; case "$__in" in *"}") ;; *) __in=$__in$(cat) ;; esac"#

  /// Reads the hook JSON from stdin once, extracts a bounded title/body via a
  /// portable `awk` pass (no `jq`/`python`, so it works over SSH), base64s each,
  /// and emits the OSC 3008 notify. Sending only the display fields keeps the wire
  /// under libghostty's 2048-byte OSC ceiling. Locked to STANDARD base64.
  /// `readsStdin: false` skips the capture when the caller already set `$__in`.
  ///
  /// Emission is gated on a non-empty extraction: a content-free notify still
  /// displays (the app falls back to the agent name for a missing title) and
  /// supersedes the agent's own OSC 9, so it is worse than sending nothing.
  static func emitNotifyShell(agent: SkillAgent, readsStdin: Bool = true) -> String {
    let payload = #"\033]3008;start=\#(agent.rawValue);\#(notifyMetadata(title: "%s", body: "%s"))\033\\"#
    let bodyKeys = notifyBodyKeys.joined(separator: ",")
    return (readsStdin ? "\(readStdinSnippet); " : "")
      + #"__t=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(titleField)" "#
      + #"-v budget=\#(notifyTitleByteBudget) '\#(notifyExtractAwk)' | base64 | tr -d '\n'); "#
      + #"__b=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="\#(bodyKeys)" "#
      + #"-v budget=\#(notifyBodyByteBudget) '\#(notifyExtractAwk)' | base64 | tr -d '\n'); "#
      + #"[ -n "$__t$__b" ] && printf '\#(payload)' "$__t" "$__b" > "$__tty""#
  }

  // MARK: - Transcript probe (Stop-hook API error, session model / effort).

  /// Bytes of the transcript tail the probe reads. Bounded so the hook
  /// stays cheap. Sized well above the largest realistic entry, since a single
  /// tool-result line can run to tens of kilobytes.
  static let transcriptTailBytes = 262_144

  /// Byte cap on a `model` / `effort` token, enforced by the probe awk on the way
  /// out and by `parse` on the way in.
  static let sessionTokenByteCap = 64

  /// One pass over the transcript JSONL tail (compact, one object per line,
  /// oldest-first) that prints a single line `<apierr> <model> <effort>`:
  /// - `apierr` is `1` when the last message entry for `sid` is an API error (a
  ///   later `type:"user"` or non-error `type:"assistant"` line means the turn
  ///   moved on), else `0`. An empty `sid` never matches, so a hook payload
  ///   without `session_id` degrades to idle rather than to another session's
  ///   stale error.
  /// - `model` / `effort` are the `"model":"…"` / `"effort":"…"` values on the
  ///   last `type:"assistant"` line carrying a valid one (Claude writes the model
  ///   on every assistant entry, `<synthetic>` on its API-error entries; effort
  ///   only where it applied), or `-` when none is valid. Validity is the
  ///   `[A-Za-z0-9._-]{1,64}` wire alphabet, checked before a value can replace
  ///   an earlier good one, so a `;` or `"` in a transcript can never splice a
  ///   field into the OSC frame and a synthetic entry never hides the real model.
  /// Substring matching assumes compact JSON; anything else fails to match and
  /// yields idle / `-`, never a spurious error. Portable awk only and no single
  /// quote, so it survives single-quoting in shell. Always prints three fields
  /// (also on empty input) so the shell's `set --` split is total.
  static let transcriptProbeAwk =
    #"function fv(s,k,  p,i,j){p="\"" k "\":\"";i=index(s,p);if(i==0)return "";i+=length(p);"#
    + #"j=index(substr(s,i),"\"");if(j==0)return "";return substr(s,i,j-1)}"#
    + #"function tok(v){if(v==""||length(v)>\#(sessionTokenByteCap)||v!~/^[A-Za-z0-9._-]+$/)return "-";return v}"#
    + #"{if(index($0,"\"type\":\"assistant\"")>0){v=tok(fv($0,"\#(modelField)"));if(v!="-")m=v;"#
    + #"v=tok(fv($0,"\#(effortField)"));if(v!="-")e=v}"#
    + #"if(index($0,"\"isApiErrorMessage\":true")>0){if(sid!=""&&index($0,"\"sessionId\":\"" sid "\"")>0)c=1;next}"#
    + #"if(index($0,"\"type\":\"user\"")>0){c=0;next}"#
    + #"if(index($0,"\"type\":\"assistant\"")>0){c=0;next}}"#
    + #"END{printf "%s %s %s",(c?"1":"0"),tok(m),tok(e)}"#

  /// Extracts `transcript_path` into `$__tp` from the hook JSON already captured
  /// in `$__in`.
  private static let transcriptPathSnippet =
    #"__tp=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="transcript_path" "#
    + #"-v budget=4096 '\#(notifyExtractAwk)')"#

  /// Runs `transcriptProbeAwk` over the tail of `$__tp` (with `$__sid` as the
  /// error session filter) and splits its one output line into `$__apierr` (`1`
  /// or empty) and `$__me`, the `;model=…;effort=…` presence-metadata suffix with
  /// each part omitted when unknown. A missing transcript reads as `0 - -`.
  /// `set -f` scopes the split so a `*` in the output can never glob. `awk` and
  /// `tail` only, so it works on a bare SSH host.
  private static let transcriptProbeSnippet =
    #"__probe=""; [ -n "$__tp" ] && [ -f "$__tp" ] && "#
    + #"__probe=$(tail -c \#(transcriptTailBytes) "$__tp" 2>/dev/null "#
    + #"| LC_ALL=C awk -v sid="$__sid" '\#(transcriptProbeAwk)'); "#
    + #"set -f; set -- $__probe; set +f; [ $# -eq 3 ] || set -- 0 - -; "#
    + #"__apierr=""; [ "$1" = 1 ] && __apierr=1; "#
    + #"__me=""; [ "$2" != - ] && __me="$__me;\#(modelField)=$2"; "#
    + #"[ "$3" != - ] && __me="$__me;\#(effortField)=$3""#

  /// Stop hook: reads stdin once (leaving `$__in` set so a following
  /// `emitNotifyShell(readsStdin: false)` reuses it), then probes the transcript
  /// for the current turn's API error (`$__apierr`) and the session's model /
  /// effort suffix (`$__me`).
  static func stopTranscriptProbeShell() -> String {
    "\(readStdinSnippet); \(transcriptPathSnippet); "
      + #"__sid=$(printf '%s' "$__in" | LC_ALL=C awk -v keys="session_id" "#
      + #"-v budget=256 '\#(notifyExtractAwk)'); "#
      + transcriptProbeSnippet
  }

  /// SessionStart hook: the same probe, so a resumed session reports its model
  /// before its first turn. `$__sid` is left empty so the error flag never sets;
  /// the caller ignores `$__apierr` and emits `$__me`.
  static func sessionStartProbeShell() -> String {
    "\(readStdinSnippet); \(transcriptPathSnippet); __sid=\"\"; " + transcriptProbeSnippet
  }
}
