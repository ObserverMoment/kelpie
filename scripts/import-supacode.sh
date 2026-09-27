#!/usr/bin/env bash
# Imports an existing Supacode setup into Kelpie: settings, open repositories
# and folders, sidebar, terminal layouts, and UI state. Supacode's own files
# and preferences are only read.
#
# Kelpie's SettingsRelocationMigrator converts the legacy ~/.kelpie files on
# the next launch, but it only seeds stores Kelpie hasn't written yet. So this
# script first moves Kelpie's own config files and sidebar/layout defaults into
# ~/.kelpie/.backup/pre-import-<timestamp>.
#
# Restored terminal tabs open fresh shells in their saved directories:
# Supacode's running sessions stay with Supacode.
#
# Usage: scripts/import-supacode.sh
set -euo pipefail

supacode_dir="${HOME}/.supacode"
supacode_domain="app.supabit.supacode"
kelpie_dir="${HOME}/.kelpie"
kelpie_domain="com.observermoment.kelpie"
kelpie_app="/Applications/kelpie.app"
config_root="${HOME}/.config"
[[ "${XDG_CONFIG_HOME:-}" == /* ]] && config_root="${XDG_CONFIG_HOME}"
kelpie_config_dir="${config_root}/kelpie"
backup_dir="${kelpie_dir}/.backup/pre-import-$(date +%Y%m%d%H%M%S)"

if [ ! -f "${supacode_dir}/settings.json" ]; then
  echo "error: no Supacode settings at ${supacode_dir}/settings.json" >&2
  exit 1
fi

# Kelpie rewrites its stores on quit, so it must not be running.
if pgrep -f "${kelpie_app}/Contents/MacOS/" >/dev/null; then
  echo "quitting Kelpie"
  osascript -e "quit app id \"${kelpie_domain}\"" >/dev/null 2>&1 || pkill -f "${kelpie_app}/Contents/MacOS/"
  while pgrep -f "${kelpie_app}/Contents/MacOS/" >/dev/null; do sleep 0.2; done
fi

mkdir -p "${backup_dir}"
defaults export "${kelpie_domain}" "${backup_dir}/${kelpie_domain}.plist" 2>/dev/null || true
for name in config.json routes.json repos.json .relocated; do
  if [ -e "${kelpie_config_dir}/${name}" ]; then
    mv "${kelpie_config_dir}/${name}" "${backup_dir}/"
  fi
done

python3 - "${supacode_dir}" "${kelpie_dir}" <<'EOF'
import json
import pathlib
import shutil
import sys

src_dir, dst_dir = map(pathlib.Path, sys.argv[1:3])

# Legacy files, at the names Kelpie's relocation migrator looks for.
dst_dir.mkdir(exist_ok=True)
copied = [name for name in ("settings.json", "sidebar.json", "ghostty.config") if (src_dir / name).exists()]
for name in copied:
    shutil.copy2(src_dir / name, dst_dir / name)


def without_agents(node):
    """Drop saved agent records: those agents belong to Supacode's sessions."""
    if isinstance(node, dict):
        return {k: without_agents(v) for k, v in node.items() if not (k == "agents" and isinstance(v, list))}
    if isinstance(node, list):
        return [without_agents(v) for v in node]
    return node


layouts = src_dir / "layouts.json"
if layouts.exists():
    (dst_dir / "layouts.json").write_text(json.dumps(without_agents(json.loads(layouts.read_text()))))
    copied.append("layouts.json")


print(f"copied {', '.join(copied)}")
EOF

# Preferences go through UserDefaults itself: its plists hold dates (such as
# distantPast) that plist libraries outside Foundation can't round-trip.
swift_script="$(mktemp -d)/import-defaults.swift"
cat > "${swift_script}" <<EOF
import Foundation

let defaults = UserDefaults.standard
let source = defaults.persistentDomain(forName: "${supacode_domain}") ?? [:]
// App keys only: system, Sparkle, and PostHog keys stay per app.
let systemPrefixes = ["NS", "SU", "PHG", "Apple", "com.apple"]
let imported = source.filter { key, _ in !systemPrefixes.contains { key.hasPrefix(\$0) } }
// Kelpie's sidebar and layout keys are cleared so the migrator seeds them.
let reseeded: Set<String> = ["sidebarState", "layoutsFile", "settingsRelocationPendingNotified"]
let kept = (defaults.persistentDomain(forName: "${kelpie_domain}") ?? [:]).filter { !reseeded.contains(\$0.key) }
defaults.setPersistentDomain(kept.merging(imported) { _, new in new }, forName: "${kelpie_domain}")
print("imported \(imported.count) preference keys")
EOF
swift "${swift_script}"
rm -rf "$(dirname "${swift_script}")"

echo "Kelpie's previous state is backed up in ${backup_dir}"
open "${kelpie_app}"
