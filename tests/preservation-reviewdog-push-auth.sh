#!/usr/bin/env bash
#
# Preservation test — reviewdog-mirror-push-auth-fix (Task 2).
#
# Property 2 (Preservation): Non-write and non-reviewdog operations unchanged.
#
# Observation-first methodology: this test observes the behavior of the UNFIXED
# .github/workflows/reviewdog.yml for every input where isBugCondition(input) == false
# (anonymous HTTPS reads, gh CLI operations driven by GH_TOKEN, git identity config, and the
# harden-runner egress decision), records those observations, and asserts them across the input
# domain. On the UNFIXED code these assertions are EXPECTED TO PASS — they capture the baseline
# behavior that the fix must preserve. The same test is re-run after the fix (task 3.5) and must
# still PASS, proving no regression.
#
# isBugCondition(input) is TRUE only for a WRITE to northwood-labs/reviewdog over github.com with
# a missing credential or wrong token scope. Everything asserted below is the complement of that
# set, so none of it may change.
#
# Because the fix is not yet applied, the "byte-for-byte unchanged" (minimal-diff) requirements are
# implemented as SNAPSHOTS: on first run against the unfixed workflow the relevant command /
# identity-config / github-endpoint lines are captured to tests/snapshots/. On every later run
# (including after the fix) the current lines are compared against the stored snapshot and must
# match byte-for-byte. This lets the minimal-diff assertions run meaningfully now and still guard
# the fix later.
#
# Preservation: Preservation Requirements from design (anonymous reads, gh CLI, identity config,
#               egress policy).
# Requirements: 3.1, 3.2, 3.3, 3.4

set -uo pipefail

# Unset CDPATH so `cd` does not echo the target directory into command substitution.
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
WORKFLOW="${REPO_ROOT}/.github/workflows/reviewdog.yml"
SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"

TARGET_REPO="northwood-labs/reviewdog"
UPSTREAM_REPO="reviewdog/reviewdog"

fail_count=0
failures=()

note_pass() {
  printf '  [PASS] %s\n' "$1"
}

note_fail() {
  printf '  [FAIL] %s\n' "$1"
  failures+=("$1")
  fail_count=$((fail_count + 1))
}

if [[ ! -f "${WORKFLOW}" ]]; then
  echo "ERROR: workflow not found at ${WORKFLOW}" >&2
  exit 2
fi

mkdir -p "${SNAPSHOT_DIR}"

echo "== Preservation: ${TARGET_REPO} mirror push auth fix =="
echo "Workflow under test: ${WORKFLOW}"
echo "Snapshot dir:        ${SNAPSHOT_DIR}"
echo ""

# -----------------------------------------------------------------------------
# Helper: compare a freshly-extracted value against a stored snapshot. On first
# run (no snapshot yet) the snapshot is created and the check passes — this is
# the baseline capture against the unfixed workflow. On later runs the value
# must match byte-for-byte.
# -----------------------------------------------------------------------------
assert_snapshot() {
  local label="$1" snapshot_name="$2" current_value="$3"
  local snapshot_file="${SNAPSHOT_DIR}/${snapshot_name}"

  if [[ ! -f "${snapshot_file}" ]]; then
    printf '%s' "${current_value}" > "${snapshot_file}"
    note_pass "${label} — baseline snapshot captured (${snapshot_name})"
    return 0
  fi

  if [[ "$(printf '%s' "${current_value}")" == "$(cat "${snapshot_file}")" ]]; then
    note_pass "${label} — byte-for-byte unchanged vs snapshot (${snapshot_name})"
  else
    note_fail "${label} — differs from snapshot ${snapshot_name}:"
    diff <(cat "${snapshot_file}") <(printf '%s' "${current_value}") | sed 's/^/        /' || true
  fi
}

# -----------------------------------------------------------------------------
# Observed input domain where isBugCondition == false. For each class we assert
# the operation is present/unchanged in the workflow — i.e. the fix leaves it alone.
# -----------------------------------------------------------------------------

# === 3.1 — Anonymous read clones over HTTPS (result independent of any credential rewrite) ===
echo "-- 3.1 Anonymous HTTPS read operations (preserved) --"

# Upstream anonymous bare clone: read of a public repo, no credential required.
if grep -Eq "git clone --bare \"https://github\.com/${UPSTREAM_REPO}\"" "${WORKFLOW}"; then
  note_pass "3.1a upstream bare clone 'git clone --bare https://github.com/${UPSTREAM_REPO}' present (anonymous read, succeeds independent of credential rewrite)"
else
  note_fail "3.1a upstream bare clone of ${UPSTREAM_REPO} not found — read operation must be preserved"
fi

# Mirror read clone ("Clone Reviewdog"): a read; succeeds anonymously if public and is unaffected
# by the (later-added) harmless credential injection.
if grep -Eq 'git clone --single-branch' "${WORKFLOW}" \
  && grep -Eq "\"https://github\.com/${TARGET_REPO}\.git\"" "${WORKFLOW}"; then
  note_pass "3.1b mirror read clone 'git clone --single-branch ... https://github.com/${TARGET_REPO}.git' present (anonymous read, result independent of credential rewrite)"
else
  note_fail "3.1b mirror read clone of ${TARGET_REPO}.git not found — read operation must be preserved"
fi
echo ""

# === 3.2 — gh CLI operations (consume GH_TOKEN directly, not git transport; unchanged) ===
echo "-- 3.2 gh CLI operations (preserved; GH_TOKEN-driven) --"

declare -a gh_ops=(
  "gh api /repos/${UPSTREAM_REPO}/releases/latest"
  "gh api \"/users/"
  "gh release create"
  "gh release view"
  "gh release upload"
)
for op in "${gh_ops[@]}"; do
  if grep -qF "${op}" "${WORKFLOW}"; then
    note_pass "3.2 gh CLI op present and unchanged: '${op}'"
  else
    note_fail "3.2 gh CLI op not found (must be preserved): '${op}'"
  fi
done

# gh CLI is authenticated via GH_TOKEN env, not git's HTTPS transport. Confirm GH_TOKEN is still
# wired from the gh_token step output into the gh-using steps.
if grep -qF 'GH_TOKEN: ${{ steps.gh_token.outputs.token }}' "${WORKFLOW}"; then
  note_pass "3.2 GH_TOKEN sourced from gh_token step output (gh CLI auth unchanged)"
else
  note_fail "3.2 GH_TOKEN wiring from gh_token step output not found — gh CLI auth must be preserved"
fi
echo ""

# === 3.3 — Minimal-diff: Sync push command + git identity config byte-for-byte unchanged ===
echo "-- 3.3 Minimal-diff snapshots (Sync push command + identity config) --"

# Snapshot 1: the Sync mirror push command/target. The design requires this line to be unchanged
# by the fix (the insteadOf rewrite handles auth, so the command itself is not edited).
sync_push_line="$(
  grep -E 'git push --force --mirror "https://github\.com/northwood-labs/reviewdog"' "${WORKFLOW}" \
    | sed 's/^[[:space:]]*//'
)"
if [[ -z "${sync_push_line}" ]]; then
  note_fail "3.3 Sync push command 'git push --force --mirror \"https://github.com/${TARGET_REPO}\"' not found"
else
  assert_snapshot "3.3 Sync push command/target" "sync-push-command.txt" "${sync_push_line}"
fi

# Snapshot 2: the git identity-config lines from the "Set Git config" step. These must remain
# intact across the fix (the fix only ADDS an insteadOf rewrite; it must not touch these lines).
# We capture the exact identity-config statements, independent of surrounding/added lines, so the
# snapshot stays stable when the fix inserts the rewrite elsewhere in the step.
set_git_config_block="$(
  awk '
    /name:[[:space:]]*Set Git config/ { in_step = 1; print; next }
    in_step {
      if ($0 ~ /^[[:space:]]{6}-[[:space:]]/) { exit }
      print
    }
  ' "${WORKFLOW}"
)"

identity_config_lines="$(
  printf '%s\n' "${set_git_config_block}" \
    | grep -E 'git config --global (advice\.detachedHead|user\.name|user\.email)' \
    | sed 's/^[[:space:]]*//'
)"
if [[ -z "${identity_config_lines}" ]]; then
  note_fail "3.3 git identity-config lines (advice.detachedHead/user.name/user.email) not found in 'Set Git config'"
else
  assert_snapshot "3.3 git identity-config lines" "identity-config-lines.txt" "${identity_config_lines}"
fi
echo ""

# === 3.4 — Egress policy: harden-runner allowed-endpoints introduces no new github host ===
echo "-- 3.4 Harden-runner egress policy (no new github host) --"

# Extract the allowed-endpoints block, then isolate every github.com / *.github.* host it lists.
# The fix must not add a new github host; github.com:443 is already allowed and is the only new
# host the credential rewrite could possibly contact (it does not change the host).
allowed_endpoints_block="$(
  awk '
    /allowed-endpoints:[[:space:]]*>/ { in_block = 1; next }
    in_block {
      # The block ends at the next key or a config-manager marker at list/step indentation.
      if ($0 ~ /@config-manager:end/) { exit }
      if ($0 ~ /^[[:space:]]{0,8}[A-Za-z0-9_-]+:[[:space:]]/) { exit }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  ' "${WORKFLOW}"
)"

github_hosts="$(
  printf '%s\n' "${allowed_endpoints_block}" \
    | grep -E '(^|\.)github(\.com|usercontent\.com|app\.com)?(\.|:)' \
    | sort -u
)"

echo "Discovered github-family allowed-endpoints:"
if [[ -z "${github_hosts}" ]]; then
  echo "  (none)"
else
  printf '  - %s\n' ${github_hosts}
fi

# The credential rewrite targets github.com:443 — assert it is already permitted (so no new host
# is needed by the fix).
if printf '%s\n' ${github_hosts} | grep -qx "github.com:443"; then
  note_pass "3.4 github.com:443 already present in allowed-endpoints (credential rewrite needs no new host)"
else
  note_fail "3.4 github.com:443 not found in allowed-endpoints — the fix would require it; preservation would break"
fi

# Snapshot the full github-host set so a later run (after the fix) proves no new github host was
# introduced (minimal-diff on the egress policy).
assert_snapshot "3.4 github-family allowed-endpoints set" "github-allowed-endpoints.txt" "${github_hosts}"
echo ""

# -----------------------------------------------------------------------------
echo ""
if [[ "${fail_count}" -eq 0 ]]; then
  echo "RESULT: PASS — all non-bug-condition behaviors observed and preserved (baseline captured)."
  exit 0
else
  echo "RESULT: FAIL — ${fail_count} preservation assertion(s) violated."
  echo ""
  echo "Violations:"
  for f in "${failures[@]}"; do
    printf '  * %s\n' "${f}"
  done
  exit 1
fi
