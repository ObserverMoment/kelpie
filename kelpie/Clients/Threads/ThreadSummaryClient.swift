import ComposableArchitecture
import Foundation
import KelpieSettingsShared

/// Asks Claude Code, headless, for a thread's next summary. It runs through
/// the login shell so `claude` and its login resolve exactly as in a terminal,
/// with every setting source, tool and MCP server off so nothing of the user's
/// own setup runs inside the summariser.
nonisolated struct ThreadSummaryClient: Sendable {
  var summarize: @Sendable (_ request: SummaryPrompt.Request) async throws -> String

  /// A stalled run (login prompt, dead network) is killed after this, so the
  /// thread's queue never waits forever.
  static let timeout: Duration = .seconds(120)

  static func arguments(for request: SummaryPrompt.Request) -> [String] {
    [
      "claude", "-p",
      "--model", request.model.rawValue,
      "--effort", request.effort.rawValue,
      "--no-session-persistence",
      "--tools", "",
      "--setting-sources", "",
      "--strict-mcp-config",
      "--output-format", "json",
      "--system-prompt", request.systemPrompt,
      request.prompt,
    ]
  }
}

extension ThreadSummaryClient: DependencyKey {
  static let liveValue = ThreadSummaryClient(summarize: { request in
    @Dependency(\.shellClient) var shell
    @Dependency(\.continuousClock) var clock
    let process = shell.runLoginProcess(
      URL(fileURLWithPath: "/usr/bin/env"), Self.arguments(for: request), nil, log: false)
    let timedOut = LockIsolated(false)
    let deadline = Task {
      try await clock.sleep(for: Self.timeout)
      timedOut.setValue(true)
      process.terminate()
    }
    defer { deadline.cancel() }
    do {
      for try await event in process.events {
        if case .finished(let output) = event {
          return try SummaryPrompt.parseResult(Data(output.stdout.utf8))
        }
      }
      throw ThreadSummaryError.emptyResult
    } catch let error as ShellClientError {
      // Never rethrow the shell error itself: its description carries the
      // whole command line, prompt and message bodies included.
      guard !timedOut.value else { throw ThreadSummaryError.timedOut }
      throw ThreadSummaryError.claudeFailed(
        status: error.exitCode, detail: error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  })

  /// An empty reply, which the reducer keeps out of the file.
  static let testValue = ThreadSummaryClient(summarize: { _ in "" })
}
