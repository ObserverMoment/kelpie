import KelpieSettingsShared
import SwiftUI

struct CLIReferenceView: View {
  var body: some View {
    Form {
      // swiftlint:disable line_length
      Section {
        Text(
          "The \(code("kelpie")) command is available in all Kelpie terminal sessions. Run \(code("kelpie --help")) for built-in usage information."
        )
        .foregroundStyle(.secondary)
        Text(
          "Inside a Kelpie terminal, flags default to the current session's IDs. Outside, pass explicit IDs from \(code("kelpie worktree list")) or \(code("kelpie repo list"))."
        )
        .foregroundStyle(.secondary)
        Text(
          "Commands that create resources (\(code("tab new")), \(code("pane split"))) print the new UUID to stdout. Capture it to target the resource afterward."
        )
        .foregroundStyle(.secondary)
        Text(
          "Pane and tab commands resolve an omitted \(code("-w")) / \(code("-p")) / \(code("-t")) from the focused target. The \(code("$KELPIE_*_ID")) environment variables and the \(code("surface")) commands are deprecated and will be removed in the next release."
        )
        .foregroundStyle(.secondary)
        // swiftlint:enable line_length
      } header: {
        Text("CLI Reference").appFont(.title, weight: .bold)
        Text("Control Kelpie from the terminal.")
      }

      CLISection(title: "App", rows: Self.appRows)
      CLISection(title: "Worktree", rows: Self.worktreeRows)
      CLISection(title: "Pane", rows: Self.paneRows)
      CLISection(title: "Tab", rows: Self.tabRows)
      CLISection(title: "Surface (deprecated)", rows: Self.surfaceRows)
      CLISection(title: "Repository", rows: Self.repoRows)
      CLISection(title: "Settings", rows: Self.settingsRows)
      CLISection(title: "Pod", rows: Self.podRows)
      CLISection(title: "Socket", rows: Self.socketRows)

      CLISection(title: "Flags", rows: Self.flagRows)
    }
    .textSelection(.enabled)
    .formStyle(.grouped)
    .frame(minWidth: 300)
    .navigationTitle("")
  }

  // MARK: - Row data.

  private static let appRows: [CLIEntry] = [
    .init(command: "kelpie", description: "Bring Kelpie to front."),
    .init(command: "kelpie open", description: "Same as above."),
  ]

  private static let worktreeRows: [CLIEntry] = [
    .init(
      command: "kelpie worktree list [-f] [--status <status>] [--not-archived] [--with-status]",
      description:
        "List worktree IDs. -f for focused only; --status main|pinned|unpinned|archived "
        + "or --not-archived filters; --with-status appends a status column."
    ),
    .init(
      command: "kelpie worktree status [-w <id>]",
      description: "Read the worktree's sidebar status, archived flag, and focus."
    ),
    .init(command: "kelpie worktree focus [-w <id>]", description: "Focus a worktree."),
    .init(
      command: "kelpie worktree run [-w <id>] [-c <uuid>]",
      description: "Run a script. Defaults to the primary run-kind script; -c targets a specific one."
    ),
    .init(
      command: "kelpie worktree stop [-w <id>] [-c <uuid>]",
      description: "Stop a script. Defaults to all run-kind scripts; -c targets a specific one."
    ),
    .init(
      command: "kelpie worktree script list [-w <id>]",
      description: "List configured scripts. Underlined rows are currently running."
    ),
    .init(
      command: "kelpie worktree archive [-w <id>]",
      description: "Archive the worktree. Targeting the current worktree closes its terminals."
    ),
    .init(command: "kelpie worktree unarchive [-w <id>]", description: "Unarchive the worktree."),
    .init(
      command: "kelpie worktree delete [-w <id>]",
      description: "Delete the worktree. Targeting the current worktree closes its terminals."
    ),
    .init(command: "kelpie worktree pin [-w <id>]", description: "Pin the worktree."),
    .init(command: "kelpie worktree unpin [-w <id>]", description: "Unpin the worktree."),
    .init(
      command: "kelpie worktree appearance [-w <id>] [--title <title>] [--color <value>]",
      description: "No flags reads stored title/tint overrides plus displayTitle; omitted update flags preserve values."
    ),
  ]

  private static let paneRows: [CLIEntry] = [
    .init(command: "kelpie pane list [-w <id>] [-f]", description: "List pane UUIDs. -f for focused only."),
    .init(
      command: "kelpie pane focus [-w <id>] [-p <id>] [-d l|r|u|d]",
      description: "Focus a pane by id, or its neighbor by direction."
    ),
    .init(
      command: "kelpie pane split [-w <id>] [-p <token>] [-d h|v] [-i <cmd>] [-n <uuid>]",
      description: "Split a pane into a new pane. Defaults to the focused pane. Prints UUID to stdout."
    ),
    .init(
      command: "kelpie pane close [-w <id>] [-p <token>]",
      description: "Close a pane and all its tabs. Defaults to the focused pane."
    ),
    .init(command: "kelpie pane zoom [-w <id>] [-p <token>]", description: "Toggle a pane's zoom."),
    .init(command: "kelpie pane equalize [-w <id>]", description: "Equalize every split ratio."),
    .init(command: "kelpie pane window [-w <id>] [-p <token>]", description: "Toggle a pane's window mode."),
  ]

  private static let tabRows: [CLIEntry] = [
    .init(command: "kelpie tab list [-w <id>] [-f]", description: "List tab UUIDs. -f for focused only."),
    .init(command: "kelpie tab focus [-w <id>] [-t <id>]", description: "Focus a tab."),
    .init(
      command: "kelpie tab new [-w <id>] [-i <cmd>] [-n <uuid>] [--title <title>] [-p <pane-token>]",
      description: "Create a tab in a pane (defaults to the focused pane). Prints UUID to stdout."
    ),
    .init(
      command: "kelpie tab rename [-w <id>] [-t <id>] --title <title>",
      description:
        "Set the persistent title override; an empty title clears it. Script tabs are locked."
    ),
    .init(
      command: "kelpie tab move [-w <id>] [-t <id>] -d l|r|u|d",
      description: "Move a tab into a new split in the given direction."
    ),
    .init(command: "kelpie tab close [-w <id>] [-t <id>]", description: "Close a tab."),
  ]

  private static let surfaceRows: [CLIEntry] = [
    .init(
      command: "kelpie surface split …",
      description: "Deprecated: use `kelpie pane split`."
    ),
    .init(
      command: "kelpie surface focus …",
      description: "Deprecated: use `kelpie tab focus`."
    ),
    .init(
      command: "kelpie surface close …",
      description: "Deprecated: use `kelpie tab close`."
    ),
    .init(
      command: "kelpie surface list …",
      description: "Deprecated: use `kelpie tab list`."
    ),
  ]

  private static let repoRows: [CLIEntry] = [
    .init(command: "kelpie repo list", description: "List repository IDs."),
    .init(command: "kelpie repo open <path>", description: "Open a repository."),
    .init(
      command:
        "kelpie repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] "
        + "[--upstream <ref> | --no-upstream] [--fetch] [--name <folder>] [--location <dir>] [--pin]",
      description: "Create a worktree. Prints the new worktree ID to stdout."
    ),
  ]

  private static let settingsRows: [CLIEntry] = [
    .init(command: "kelpie settings", description: "Open settings."),
    .init(command: "kelpie settings <section>", description: "Open a specific section."),
    .init(command: "kelpie settings repo [-r <id>]", description: "Open repository settings."),
    .init(
      command: "kelpie settings repo scripts [-r <id>]",
      description: "Open repository Scripts settings."
    ),
  ]

  private static let podRows: [CLIEntry] = [
    .init(
      command: "kelpie pod register --name <name> [-s <id>]",
      description: "Report an agent's messaging name to its pod. Kelpie's pod prompt asks agents to run it."
    )
  ]

  private static let socketRows: [CLIEntry] = [
    .init(command: "kelpie socket", description: "List active socket paths.")
  ]

  private static let flagRows: [CLIEntry] = [
    .init(command: "-w, --worktree", description: "Worktree ID. Pane / tab commands default to the focused worktree."),
    .init(command: "-p, --pane", description: "Pane, tab, or content UUID. Defaults to the focused pane."),
    .init(command: "-t, --tab", description: "Tab UUID. Defaults to the focused tab."),
    .init(command: "-c, --script", description: "Script UUID (for `worktree run`/`stop`)."),
    .init(
      command: "--title",
      description: "Tab title for tab new/rename, or sidebar title for worktree appearance; empty clears."),
    .init(command: "--color", description: "Sidebar tint override; pass none to clear."),
    .init(command: "-r, --repo", description: "Repository ID. Defaults to $KELPIE_REPO_ID."),
    .init(command: "-i, --input", description: "Command to run in the terminal."),
    .init(
      command: "-d, --direction",
      description: "Split direction (h/v) for splits; neighbor direction (l/r/u/d) for pane focus and tab move."),
    .init(command: "-n, --id", description: "UUID for a new tab."),
    .init(command: "-f, --focused", description: "Print only the focused item in list commands."),
    .init(
      command: "--background",
      description: "Leave the selection and focus alone; new tabs and splits stay in the background."
    ),
    .init(
      command: "-s, --surface",
      description: "Deprecated. Surface UUID for the deprecated `surface` commands; defaults to $KELPIE_SURFACE_ID."
    ),
  ]
}

// MARK: - Components.

private struct CLIEntry: Identifiable {
  let id = UUID()
  let command: String
  let description: String
}

private struct CLISection: View {
  let title: String
  let rows: [CLIEntry]

  var body: some View {
    Section(title) {
      Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
        ForEach(rows) { row in
          GridRow {
            Text(row.command)
              .appFont(.body, monospaced: true)
              .gridColumnAlignment(.leading)
            Text(row.description)
              .foregroundStyle(.secondary)
              .gridColumnAlignment(.leading)
          }
        }
      }
    }
  }
}

/// Inline code fragment styled as monospaced primary foreground.
private func code(_ value: String) -> Text {
  Text(value).monospaced().foregroundStyle(.primary)
}
