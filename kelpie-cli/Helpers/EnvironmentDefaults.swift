import Foundation

/// Typed accessors for Kelpie environment variables injected into terminal sessions.
nonisolated enum EnvironmentDefaults {
  static var socketPath: String? {
    ProcessInfo.processInfo.environment["KELPIE_SOCKET_PATH"]
  }

  /// Already percent-encoded by the host app.
  static var worktreeID: String? {
    ProcessInfo.processInfo.environment["KELPIE_WORKTREE_ID"]
  }

  static var tabID: String? {
    ProcessInfo.processInfo.environment["KELPIE_TAB_ID"]
  }

  static var surfaceID: String? {
    ProcessInfo.processInfo.environment["KELPIE_SURFACE_ID"]
  }

  /// Already percent-encoded by the host app.
  static var repoID: String? {
    ProcessInfo.processInfo.environment["KELPIE_REPO_ID"]
  }
}
