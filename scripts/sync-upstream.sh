#!/usr/bin/env bash
# Merges the latest Supacode (supabitapp/supacode) into the current branch.
#
# Kelpie follows upstream through the `upstream-rebranded` branch. Each commit
# on it is an upstream snapshot passed through scripts/rebrand.py, with the
# upstream commit as its second parent. Merging that branch instead of
# upstream/main means a merge carries only upstream's real changes, not
# thousands of supacode-to-kelpie renames, so conflicts appear only where
# Kelpie changed the same lines.
#
# Usage:
#   scripts/sync-upstream.sh [upstream-ref]   sync and merge (default: upstream/main)
#   scripts/sync-upstream.sh --init <sha>     create upstream-rebranded from the
#                                             upstream commit Kelpie was forked from
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

upstream_url="https://github.com/supabitapp/supacode.git"
vendor_branch="upstream-rebranded"
git_dir="$(git rev-parse --absolute-git-dir)"

# Builds the rebranded tree of an upstream commit in a scratch directory with
# its own index, so the checkout, its index, and git hooks are never touched.
# Prints the new commit; extra arguments are passed to commit-tree (parents).
rebranded_commit() {
  local upstream_sha="$1"
  shift
  local tmp
  tmp="$(mktemp -d)"
  mkdir "${tmp}/tree"
  vendor_git() { GIT_INDEX_FILE="${tmp}/index" git --git-dir="${git_dir}" --work-tree="${tmp}/tree" -C "${tmp}/tree" "$@"; }
  vendor_git read-tree -u --reset "${upstream_sha}"
  python3 "${repo_root}/scripts/rebrand.py" "${tmp}/tree"
  vendor_git add -A -f
  local tree
  tree="$(vendor_git write-tree)"
  rm -rf "${tmp}"
  git commit-tree "${tree}" "$@" -m "Rebrand supabitapp/supacode@${upstream_sha:0:8}" -m "Upstream: ${upstream_sha}"
}

git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "${upstream_url}"

if [ "${1:-}" = "--init" ]; then
  upstream_sha="$(git rev-parse "${2:?usage: --init <upstream-sha>}^{commit}")"
  if git rev-parse --verify --quiet "refs/heads/${vendor_branch}" >/dev/null; then
    echo "error: ${vendor_branch} already exists" >&2
    exit 1
  fi
  commit="$(rebranded_commit "${upstream_sha}" -p "${upstream_sha}")"
  git update-ref "refs/heads/${vendor_branch}" "${commit}"
  echo "created ${vendor_branch} at ${commit:0:8} (upstream ${upstream_sha:0:8})"
  exit 0
fi

if ! git rev-parse --verify --quiet "refs/heads/${vendor_branch}" >/dev/null; then
  echo "error: ${vendor_branch} is missing; create it with --init <forked-from upstream sha>" >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "error: commit or stash your changes before syncing" >&2
  exit 1
fi

git fetch upstream
upstream_sha="$(git rev-parse "${1:-upstream/main}^{commit}")"

if git merge-base --is-ancestor "${upstream_sha}" "${vendor_branch}"; then
  echo "${vendor_branch} already includes upstream ${upstream_sha:0:8}"
else
  commit="$(rebranded_commit "${upstream_sha}" -p "${vendor_branch}" -p "${upstream_sha}")"
  git update-ref "refs/heads/${vendor_branch}" "${commit}"
  echo "${vendor_branch} now at ${commit:0:8} (upstream ${upstream_sha:0:8})"
fi

if git merge-base --is-ancestor "${vendor_branch}" HEAD; then
  echo "Nothing to merge."
  exit 0
fi

if ! git merge --no-ff --no-edit -m "Merge upstream Supacode ${upstream_sha:0:8}" "${vendor_branch}"; then
  echo "Resolve the conflicts, run 'git commit', then 'git submodule update --init --recursive'." >&2
  exit 1
fi
git submodule update --init --recursive
echo "Merged upstream ${upstream_sha:0:8}. Rebuild and reinstall with: make install-dev-build"
