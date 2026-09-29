import KelpieSettingsShared
import Sharing

nonisolated extension SharedReaderKey where Self == AppStorageKey<SkillAgent>.Default {
  /// The agent the Fleet View launcher last started; Claude Code until then.
  static var fleetLauncherAgent: Self {
    Self[.appStorage("fleetLauncherAgent"), default: .claude]
  }
}

nonisolated extension SharedReaderKey where Self == AppStorageKey<String?>.Default {
  /// The Claude config folder the launcher last used; nil is the default `~/.claude`.
  static var fleetLauncherClaudeConfigDirectory: Self {
    Self[.appStorage("fleetLauncherClaudeConfigDirectory"), default: nil]
  }
}
