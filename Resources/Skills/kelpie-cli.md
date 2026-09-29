---
name: kelpie-cli
description: Control Kelpie from the terminal. Use when running Kelpie CLI commands, managing worktrees, panes, and tabs programmatically, or when inside a Kelpie terminal session.
---

# Kelpie CLI

Control Kelpie from the terminal. The `kelpie` command is available in all Kelpie terminal sessions.

A worktree's layout is a split tree of **panes**; each pane holds a strip of
**tabs**; each tab is one terminal. Split a pane to grow the tree; add a tab to
a pane to stack terminals in the same split.

## CRITICAL: ID Tracking

**NEVER call `kelpie tab new` or `kelpie pane split` without capturing the
output.** These commands print the new tab's UUID to stdout. You MUST capture
it into a variable, or you cannot target the tab afterward.

Pane and tab commands resolve an omitted `-w` / `-p` / `-t` from the **focused**
worktree / pane / tab. That is the target the user is currently looking at, so
when you act on something you created, **pass its id explicitly.**

### Correct pattern — ALWAYS follow this:

**Run all related commands in a SINGLE Bash call** so captured variables
are available to subsequent commands. If you split across tool calls,
variables like `$TAB_ID` will be lost.

```sh
# 1. ALWAYS capture the UUID from tab new / pane split.
TAB_ID=$(kelpie tab new -i "npm start")

# 2. pane split opens a new pane; -p accepts a pane, tab, or content UUID.
SPLIT_ID=$(kelpie pane split -p "$TAB_ID" -d v -i "npm test")

# 3. ALWAYS use captured IDs for subsequent operations.
kelpie tab focus -t "$SPLIT_ID"
kelpie tab close -t "$SPLIT_ID"
kelpie tab close -t "$TAB_ID"
```

### WRONG — never do this:

```sh
# BAD: not capturing the UUID: you lose the reference.
kelpie tab new -i "npm start"

# BAD: relying on the focused default for something you created: it targets
# whatever the user is looking at, not your new pane.
kelpie pane split -d v -i "npm test"

# BAD: splitting commands across separate Bash calls — variables are lost.
# Call 1: TAB_ID=$(kelpie tab new)
# Call 2: kelpie pane split -p "$TAB_ID" ...  ← $TAB_ID is empty!
```

## CRITICAL: Archiving or Deleting the Current Worktree

`kelpie worktree archive` and `kelpie worktree delete` remove the worktree
from Kelpie's active terminals. Run against the worktree you are working in,
they close your own terminal: commands after the call do not run. Worktrees
removed directly through Git disappear the same way once Kelpie refreshes.
`--background` does not change this; it only leaves focus untouched.

Make archiving or deleting your own worktree your FINAL operation. Finish all
edits, checks, commits, integration, and reporting first, and do not chain or
schedule follow-up commands after it.

## Sandboxed Harnesses

`kelpie` talks to the app over a Unix domain socket. Sandboxes that deny
socket connections fail every command with "Operation not permitted"; that is
the sandbox, not Kelpie. Re-run the command with escalated permissions
(approve the elevation prompt) or from an unsandboxed shell.

## Environment

Inside Kelpie terminals, these environment variables are set automatically:

| Variable | Description |
|----------|-------------|
| `KELPIE_SOCKET_PATH` | Socket for app communication. |
| `KELPIE_WORKTREE_ID` | Deprecated. Current worktree (percent-encoded path). |
| `KELPIE_TAB_ID` | Deprecated. Current tab UUID. |
| `KELPIE_SURFACE_ID` | Deprecated. Current content UUID (used by `surface` commands). |
| `KELPIE_REPO_ID` | Deprecated. Current repository (percent-encoded path). |

The id variables are **deprecated and will be removed in the next release**:
new pane/tab commands ignore them and resolve an omitted worktree/pane/tab from
the focused target instead. Only the deprecated `surface` commands still read
them.

## Commands

### App

```
kelpie                          # Bring Kelpie to front.
kelpie open                     # Same as above.
```

### Worktree

```
kelpie worktree list [-f] [--status <status>] [--not-archived] [--with-status]  # List worktree IDs (-f = focused only).
kelpie worktree status [-w <id>]                  # Read status/archived/focused for one worktree.
kelpie worktree focus [-w <id>]                   # Focus worktree.
kelpie worktree run [-w <id>] [-c <uuid>] [--background]         # Run script (default: primary run-kind; -c for a specific UUID).
kelpie worktree stop [-w <id>] [-c <uuid>] [--background]        # Stop script (default: all run-kind; -c for a specific UUID).
kelpie worktree script list [-w <id>]             # List configured scripts (id / kind / name).
kelpie worktree archive [-w <id>] [--background]                 # Archive worktree.
kelpie worktree unarchive [-w <id>] [--background]               # Unarchive worktree.
kelpie worktree delete [-w <id>] [--background]                  # Delete worktree.
kelpie worktree pin [-w <id>] [--background]                     # Pin worktree.
kelpie worktree unpin [-w <id>] [--background]                   # Unpin worktree.
kelpie worktree appearance [-w <id>] [--title <title>] [--color <value>]  # Read stored title/tint overrides; flags update them (empty title or color none clears).
```

### Pane

A pane is a split-tree leaf holding a strip of tabs. `-w` defaults to the
focused worktree; `-p` defaults to the focused pane. `-p` accepts a pane, tab,
or content UUID.

```
kelpie pane list [-w <id>] [-f]                                   # List pane UUIDs (-f = focused only).
kelpie pane focus [-w <id>] [-p <id>] [-d l|r|u|d]                # Focus a pane by id, or its neighbor by direction.
kelpie pane split [-w <id>] [-p <token>] [-d h|v] [-i <cmd>] [-n <uuid>] [--background]  # Split into a new pane (prints the new tab UUID).
kelpie pane close [-w <id>] [-p <token>] [--background]           # Close a pane and all its tabs.
kelpie pane zoom [-w <id>] [-p <token>]                           # Toggle a pane's zoom.
kelpie pane equalize [-w <id>]                                    # Equalize every split ratio.
kelpie pane window [-w <id>] [-p <token>]                         # Toggle a pane's window mode.
```

### Tab

`-t` defaults to the focused tab.

```
kelpie tab list [-w <id>] [-f]                                    # List tab UUIDs in worktree (-f = focused only).
kelpie tab focus [-w <id>] [-t <id>]                              # Focus tab.
kelpie tab new [-w <id>] [-i <cmd>] [-n <uuid>] [--title <title>] [-p <pane-token>] [--background]  # Create tab in a pane (prints UUID to stdout).
kelpie tab rename [-w <id>] [-t <id>] --title <title>             # Rename tab (empty title clears override; script tabs are locked).
kelpie tab move [-w <id>] [-t <id>] -d l|r|u|d [--background]     # Move a tab into a new split.
kelpie tab close [-w <id>] [-t <id>] [--background]               # Close tab.
```

### Surface (deprecated)

A surface is now a tab's content. These commands still work and still read the
deprecated `$KELPIE_TAB_ID` / `$KELPIE_SURFACE_ID`, but they are deprecated
and **will be removed in the next release**; prefer the pane/tab equivalents.

```
kelpie surface split …   # Deprecated: use `kelpie pane split`.
kelpie surface focus …   # Deprecated: use `kelpie tab focus`.
kelpie surface close …   # Deprecated: use `kelpie tab close`.
kelpie surface list …    # Deprecated: use `kelpie tab list`.
```

### Repository

```
kelpie repo list                                                     # List repository IDs.
kelpie repo open <path>                                              # Open repository.
kelpie repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--upstream <ref> | --no-upstream] [--fetch] [--name <folder>] [--location <dir>] [--pin] [--background]  # Create worktree (prints the new worktree ID to stdout; --upstream sets the new branch's tracking branch, --no-upstream clears it; --pin pins it as soon as creation starts, local repositories only).
```

### Settings

```
kelpie settings [<section>]        # Open settings (general|notifications|worktrees|developer|shortcuts|scripts|updates|github).
kelpie settings repo [-r <id>]     # Open repository settings.
kelpie settings repo scripts [-r <id>]  # Open repository Scripts settings.
```

### Pod

```
kelpie pod register --name <session name> [-s <id>]  # Report your messaging name to your agent pod.
```

Run `pod register` only when a `[Kelpie]` pod prompt asks you to. Kelpie then sends every member the pod roster.

### Socket

```
kelpie socket                      # List active socket paths.
```

## Output Formats

`list` commands output one ID per line: percent-encoded paths for worktrees and
repositories, UUIDs for panes and tabs. Use these IDs directly as `-w`, `-p`,
`-t`, `-r`, `-c` flag values.

`worktree list` filters with `--status main|pinned|unpinned|archived`
(comma-separated) or `--not-archived` (not both); `--with-status` appends a
tab-separated status column.

`worktree status` outputs `status=<value>`, `archived=<true|false>`, and
`focused=<true|false>` for a single worktree.

`worktree script list` outputs tab-separated `<uuid>\t<kind>\t<displayName>`
rows. When stdout is a TTY, running scripts are ANSI-underlined; captured or
piped output carries no running indicator.

`worktree appearance` with no flags outputs `title=<stored override>`,
`color=<stored override or none>`, and `displayTitle=<effective title>`.
With `--title` / `--color`, omitted update flags preserve existing values;
`--title ""` clears the title override and `--color none` clears the tint.

## Background Mode

Pass `--background` when acting on behalf of a user working elsewhere: it
leaves the sidebar selection and keyboard focus untouched, and new panes and
tabs stay in the background instead of becoming active. It is accepted by every
action that would otherwise focus its target (`tab new`, `tab move`,
`pane split`, `pane close`, `repo worktree-new`, `worktree run`/`stop`/
`archive`/`unarchive`/`delete`/`pin`/`unpin`, and `tab close`); the `focus`,
`zoom`, `equalize`, and `window` commands do not accept it.

## Flag Reference

| Flag | Short | Default | Description |
|------|-------|---------|-------------|
| `--worktree` | `-w` | focused worktree | Worktree ID. |
| `--pane` | `-p` | focused pane | Pane token: a pane, tab, or content UUID. |
| `--tab` | `-t` | focused tab | Tab UUID. |
| `--script` | `-c` | - | Script UUID (for `worktree run`/`stop`). |
| `--title` | - | - | Tab title for `tab new`/`rename`, or sidebar title for `worktree appearance`; an empty string clears it for `rename` and `appearance` (rejected by `tab new`). |
| `--color` | - | - | Sidebar tint override; pass `none` to clear. |
| `--repo` | `-r` | `$KELPIE_REPO_ID` | Repository ID. |
| `--input` | `-i` | - | Command to run in the terminal. |
| `--direction` | `-d` | `horizontal` | Split direction (`h`/`v`) for splits; neighbor direction (`l`/`r`/`u`/`d`) for `pane focus` and `tab move`. |
| `--id` | `-n` | random | UUID for a new tab. |
| `--focused` | `-f` | - | Print only the focused item in `list` commands. |
| `--background` | - | - | Do not move the selection or focus; see Background Mode. |
| `--surface` | `-s` | `$KELPIE_SURFACE_ID` | Deprecated. Surface UUID for the deprecated `surface` commands. |
| `--timeout` | - | app default | Seconds to wait for the app's response; `0` waits indefinitely. |
