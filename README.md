# Kelpie

**A native macOS command center for running coding agents in parallel.**

Run several coding agents side by side from one window: each task gets its own git worktree and
its own real terminal. Sessions persist in the background, so quitting the app or dropping an SSH
connection loses nothing.

Kelpie is a fork of [Supacode](https://github.com/supabitapp/supacode) by Supabit, distributed
under the same Functional Source License (see [LICENSE](LICENSE)). It has its own bundle ID,
config directory (`~/.kelpie`), CLI (`kelpie`), and zmx session prefix (`kelp-`), so it runs
alongside an installed Supacode without sharing state.

## Features

### Worktree-first workflow

Each task gets its own git worktree and terminal, so agents run in parallel without colliding.
Create one from the sidebar, a hotkey, the command palette, the CLI, or a deeplink. The sidebar
refreshes branch, file, and pull request state live, nests rows by branch, and hoists the
worktrees that need you (an agent awaiting input, a running script) to the top. Pin, archive,
auto-delete after N days, and jump to any with ⌃1 to ⌃9.

### Background session persistence

Sessions run inside [zmx](https://zmx.sh), a lightweight session daemon, not as children of the
app. Quit and relaunch, and every session reattaches exactly where you left it, scrollback
included. On by default; a quit option tears everything down when you want a clean start.

### Remote SSH repositories (Beta)

Point Kelpie at a repository on a remote host over SSH and it manages that repo's worktrees
like a local one. Every git probe and the terminal share one multiplexed SSH connection, so you
authenticate (or touch your security key) once. When the host has zmx, remote sessions survive
dropped connections and laptop sleep: the connection retries and reattaches instead of
restarting. Beta, with some local-only features reduced.

### Folders and repositories

Git repositories and plain folders are both first-class in the sidebar. A folder gets a real
persistent terminal rooted there, with the same tabs, scripts, pinning, and appearance as a repo,
minus the git-only tools. You can also clone a remote URL straight into a folder.

### Coding agent presence

Kelpie detects the agent in each pane and shows a live badge: busy, awaiting input, or idle. It
supports the common agents (Claude, Codex, Copilot) through hooks it installs, works locally and
over SSH, and drives notifications so you know the moment an agent needs you.

### The CLI and deeplinks

Drive the app from any terminal, script, or other tool. The `kelpie` CLI manages worktrees,
tabs, splits, and repos, and every session exports its repo, worktree, tab, and surface IDs, so
commands default to the session you run them in. Deeplinks (`kelpie://...`) mirror the CLI, so
you can bind an action to a hotkey or fire it from another app.

### More

- **A real terminal.** libghostty renders every session, with tabs, horizontal and vertical
  splits, per-surface backgrounds, and theme sync with the app's appearance.
- **Command palette.** Fuzzy-search and run any action without the mouse: jump to a worktree, open
  or clone a repo, manage worktrees, run scripts, and drive the full set of pull request actions.
- **Pull request tracking.** With GitHub integration on, each worktree's PR state, checks, and
  merge readiness show in the sidebar and refresh live, with configurable merge strategy.
- **Notifications and bells.** In-app and optional system notifications, a selectable sound,
  per-surface muting, and an option to float a notified worktree to the top.
- **Custom scripts.** Named commands with an icon and tint, per repository or global, that run in
  their own tab and appear in the Script Menu, the palette, and as deeplinks. Repositories also
  get setup and archive scripts.
- **Auto-updates** through Sparkle, with a selectable update channel.

## Requirements

- macOS 26.0+
- [mise](https://mise.jdx.dev/) for the pinned toolchain. Add `~/.local/bin` to your `PATH`.
- git submodules: `git submodule update --init --recursive`
- The Xcode Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain`
- On Xcode 26.4+: Command Line Tools with the macOS 26.2 SDK, or Xcode 26.3 (see [below](#building-on-macos-264-tahoe)).

## Quick start

```bash
git clone --recursive git@github.com:ObserverMoment/kelpie.git
cd kelpie
mise install
make doctor    # check every build prerequisite and print fixes for anything missing
make install-dev-build   # build Debug, install to /Applications/kelpie.app, and relaunch
```

To update, pull `main` and run `make install-dev-build` again.

`make doctor` verifies mise, submodules, a Zig-linkable Xcode, the Metal Toolchain, and the
pinned tools, and prints the exact command to fix anything that is missing. The build targets
run it automatically as a quiet preflight.

## Building

```bash
make build-ghostty-xcframework   # build GhosttyKit from Zig source (slow, cached)
make build-app                   # build the macOS app (Debug)
make run-app                     # build and launch
```

### Building on macOS 26.4+ (Tahoe)

GhosttyKit is built with a pinned Zig (`0.15.2`, required exactly by ghostty) that cannot use the
macOS 26.4+ SDK or its tools:

- The SDK dropped the `arm64-macos` slice from `libSystem.tbd`
  ([ziglang/zig#31658](https://github.com/ziglang/zig/issues/31658)), so Zig fails with
  `undefined symbol` errors.
- The newer `libtool` drops Zig's misaligned archive members, so `libghostty.a` loses its
  symbols and the app fails to link.

The build handles this in one of two ways:

- **Command Line Tools fallback (default here).** If Command Line Tools has a macOS SDK of 26.3 or
  older (for example `MacOSX26.2.sdk`), `scripts/zig-sdk-env.sh` keeps your current Xcode for
  `xcodebuild` and Metal, and points only Zig's SDK lookups and `libtool` at Command Line Tools
  through `scripts/zig-sdk-shim/`.
- **Xcode 26.3.** Install [Xcode 26.3](https://developer.apple.com/download/all/?q=Xcode%2026.3)
  next to your current Xcode. The build detects it and pins it for the Zig build only:

  ```bash
  sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
  sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch
  sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
  ```

See [AGENTS.md](AGENTS.md) for the full rationale and the rest of the architecture.

## Staying in sync with Supacode

```bash
scripts/sync-upstream.sh   # merge the latest supabitapp/supacode main
make install-dev-build
```

The script rebrands each upstream snapshot with `scripts/rebrand.py` onto the `upstream-rebranded`
branch and merges that branch, so a merge carries only upstream's own changes. Conflicts appear
only where Kelpie changed the same lines. Add new upstream renames to `scripts/rebrand.py`.

To copy an existing Supacode setup (settings, repositories, sidebar, layouts) into Kelpie, run
`scripts/import-supacode.sh`.

## Development

```bash
make check   # swift-format + swiftlint
make test    # run the tests
make format  # swift-format only
```

## Technical stack

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)
- [libghostty](https://github.com/ghostty-org/ghostty)
- [zmx](https://zmx.sh) for session persistence

## Contributing

Contributions are reviewed personally, line by line, and a clear issue is worth more than a
large pull request. Start by opening an issue, wait for the `ready` label, then open a focused
pull request that links it. The full process, including the rule that a human (never an AI
agent) is the accountable author, is in the [Contributing guide](CONTRIBUTING.md).

- [Contributing guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md)

## License

See [LICENSE](LICENSE).
