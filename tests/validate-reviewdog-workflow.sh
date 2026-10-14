#!/usr/bin/env bash
#
# Workflow validation — reviewdog-mirror-push-auth-fix (Task 3.3).
#
# Validates the edited .github/workflows/reviewdog.yml after the fix (Changes 1 and 2):
# YAML validity plus the structural assertions that encode the two coordinated fixes and the
# minimal-diff / preservation guarantees.
#
# Assertions:
#   V1. The workflow parses as valid YAML (via yq; python3 yaml fallback).
#   V2. The gh_token step's `repositories` block lists BOTH `git-mirrors` and `reviewdog`
#       (Change 1 — token carries write scope for northwood-labs/reviewdog).
#   V3. The "Set Git config" step contains the
#       url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
#       rewrite AND GH_TOKEN is present in that step's `env`
#       (Change 2 — App token reaches git's HTTPS transport).
#   V4. Minimal-diff: the Sync push command/target
#       git push --force --mirror "https://github.com/northwood-labs/reviewdog"
#       is unchanged, and no NEW harden-runner endpoint was added (github.com:443 already allowed).
#
# Requirements: 2.1, 2.2, 3.4

set -uo pipefail

# Unset CDPATH so `cd` does not echo the target directory into command substitution.
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
WORKFLOW="${REPO_ROOT}/.github/workflows/reviewdog.yml"
SNAPSHOT_DIR="${SCRIPT_DIR}/snapshots"

TARGET_REPO="northwood-labs/reviewdog"

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

echo "== Validate edited workflow: ${TARGET_REPO} mirror push auth fix =="
echo "Workflow under test: ${WORKFLOW}"
echo ""

# === V1 — YAML validity ===
echo "-- V1 YAML validity --"
yaml_ok=0
if command -v yq >/dev/null 2>&1; then
  if yq eval '.' "${WORKFLOW}" >/dev/null 2>yq_err.$$; then
    note_pass "V1 workflow parses as valid YAML (yq)"
    yaml_ok=1
  else
    note_fail "V1 workflow failed to parse as YAML (yq): $(cat yq_err.$$ 2>/dev/null)"
  fi
  rm -f yq_err.$$
elif command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "${WORKFLOW}" 2>py_err.$$; then
    note_pass "V1 workflow parses as valid YAML (python3 yaml)"
    yaml_ok=1
  else
    note_fail "V1 workflow failed to parse as YAML (python3): $(cat py_err.$$ 2>/dev/null)"
  fi
  rm -f py_err.$$
else
  note_fail "V1 neither yq nor python3 available to validate YAML"
fi
echo ""

# === V2 — gh_token repositories scope lists BOTH git-mirrors and reviewdog ===
echo "-- V2 gh_token repositories scope --"

# Prefer a structured query via yq: find the step using actions/create-github-app-token and read
# its `with.repositories` value, which is a newline-separated block scalar.
repositories_values=""
if [[ "${yaml_ok}" -eq 1 ]] && command -v yq >/dev/null 2>&1; then
  repositories_values="$(
    yq eval '
      .jobs[].steps[]
      | select(.uses | test("actions/create-github-app-token"))
      | .with.repositories
    ' "${WORKFLOW}" 2>/dev/null | grep -vE '^(null|---)$' | grep -vE '^[[:space:]]*$'
  )"
fi

# Fallback to a text extraction if yq produced nothing.
if [[ -z "${repositories_values}" ]]; then
  app_token_block="$(
    awk '
      /uses:[[:space:]]*actions\/create-github-app-token/ { in_step = 1 }
      in_step {
        print
        if (seen && $0 ~ /^[[:space:]]{6}-[[:space:]]/) { exit }
        if ($0 ~ /^[[:space:]]{6}-[[:space:]]/) { seen = 1 }
      }
    ' "${WORKFLOW}"
  )"
  repositories_values="$(
    printf '%s\n' "${app_token_block}" | awk '
      /^[[:space:]]*repositories:[[:space:]]*\|/ { block = 1; next }
      /^[[:space:]]*repositories:[[:space:]]*[^|[:space:]]/ {
        sub(/^[[:space:]]*repositories:[[:space:]]*/, ""); print; next
      }
      block {
        if ($0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]/) { block = 0; next }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if (length($0) > 0) print
      }
    '
  )"
fi

echo "Discovered gh_token 'repositories' scope:"
if [[ -z "${repositories_values}" ]]; then
  echo "  (none found)"
else
  printf '  - %s\n' ${repositories_values}
fi

if printf '%s\n' ${repositories_values} | grep -qx "git-mirrors"; then
  note_pass "V2a gh_token repositories includes 'git-mirrors' (retained)"
else
  note_fail "V2a gh_token repositories missing 'git-mirrors'"
fi

if printf '%s\n' ${repositories_values} | grep -qx "reviewdog"; then
  note_pass "V2b gh_token repositories includes 'reviewdog' (write scope for ${TARGET_REPO})"
else
  note_fail "V2b gh_token repositories missing 'reviewdog' — token would lack write scope on ${TARGET_REPO}"
fi
echo ""

# === V3 — "Set Git config" insteadOf rewrite + GH_TOKEN in env ===
echo "-- V3 Set Git config: insteadOf rewrite + GH_TOKEN env --"

# Isolate the "Set Git config" step body (from its name to the next step at 6-space indent).
set_git_config_block="$(
  awk '
    /name:[[:space:]]*Set Git config/ { in_step = 1; print; next }
    in_step {
      if ($0 ~ /^[[:space:]]{6}-[[:space:]]/) { exit }
      print
    }
  ' "${WORKFLOW}"
)"

if [[ -z "${set_git_config_block}" ]]; then
  note_fail "V3 'Set Git config' step not found"
else
  # V3a: exact insteadOf rewrite present. The rewrite is split across lines with shell line
  # continuations (trailing backslash) in the workflow, so strip backslashes and newlines and
  # collapse whitespace before matching the required tokens.
  normalized_block="$(printf '%s' "${set_git_config_block}" | tr '\n' ' ' | sed 's/\\/ /g' | tr -s ' ')"
  if printf '%s' "${normalized_block}" \
    | grep -qF 'url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"'; then
    note_pass "V3a insteadOf rewrite present: url.\"https://x-access-token:\${GH_TOKEN}@github.com/\".insteadOf \"https://github.com/\""
  else
    note_fail "V3a required insteadOf rewrite not found in 'Set Git config' step"
  fi

  # V3b: GH_TOKEN present in the step's env block.
  if printf '%s\n' "${set_git_config_block}" \
    | grep -qE '^[[:space:]]*GH_TOKEN:[[:space:]]*\$\{\{[[:space:]]*steps\.gh_token\.outputs\.token'; then
    note_pass "V3b GH_TOKEN present in 'Set Git config' step env (sourced from gh_token output)"
  else
    note_fail "V3b GH_TOKEN not found in 'Set Git config' step env"
  fi
fi
echo ""

# === V4 — Minimal-diff: Sync push command unchanged + no new harden-runner endpoint ===
echo "-- V4 Minimal-diff (Sync push command + egress endpoints) --"

# V4a: Sync push command/target byte-for-byte unchanged vs the preservation snapshot.
sync_push_line="$(
  grep -E 'git push --force --mirror "https://github\.com/northwood-labs/reviewdog"' "${WORKFLOW}" \
    | sed 's/^[[:space:]]*//'
)"
sync_snapshot="${SNAPSHOT_DIR}/sync-push-command.txt"
if [[ -z "${sync_push_line}" ]]; then
  note_fail "V4a Sync push command 'git push --force --mirror \"https://github.com/${TARGET_REPO}\"' not found"
elif [[ -f "${sync_snapshot}" ]]; then
  if [[ "${sync_push_line}" == "$(cat "${sync_snapshot}")" ]]; then
    note_pass "V4a Sync push command/target unchanged (byte-for-byte vs snapshot)"
  else
    note_fail "V4a Sync push command differs from snapshot:"
    diff <(cat "${sync_snapshot}") <(printf '%s' "${sync_push_line}") | sed 's/^/        /' || true
  fi
else
  # No snapshot to compare against; still confirm the exact expected command is present.
  if [[ "${sync_push_line}" == 'git push --force --mirror "https://github.com/northwood-labs/reviewdog"' ]]; then
    note_pass "V4a Sync push command/target matches expected (no snapshot present)"
  else
    note_fail "V4a Sync push command unexpected: '${sync_push_line}'"
  fi
fi

# V4b: harden-runner github-family endpoints introduce no new host vs the preservation snapshot.
allowed_endpoints_block="$(
  awk '
    /allowed-endpoints:[[:space:]]*>/ { in_block = 1; next }
    in_block {
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

if printf '%s\n' ${github_hosts} | grep -qx "github.com:443"; then
  note_pass "V4b github.com:443 already present in allowed-endpoints (fix adds no new host)"
else
  note_fail "V4b github.com:443 missing from allowed-endpoints"
fi

endpoints_snapshot="${SNAPSHOT_DIR}/github-allowed-endpoints.txt"
if [[ -f "${endpoints_snapshot}" ]]; then
  if [[ "$(printf '%s' "${github_hosts}")" == "$(cat "${endpoints_snapshot}")" ]]; then
    note_pass "V4b github-family allowed-endpoints unchanged (no new endpoint added vs snapshot)"
  else
    note_fail "V4b github-family allowed-endpoints changed vs snapshot:"
    diff <(cat "${endpoints_snapshot}") <(printf '%s' "${github_hosts}") | sed 's/^/        /' || true
  fi
else
  echo "  [INFO] no egress snapshot to compare against (skipping diff portion of V4b)"
fi
echo ""

# -----------------------------------------------------------------------------
echo ""
if [[ "${fail_count}" -eq 0 ]]; then
  echo "RESULT: PASS — edited workflow is valid YAML and all structural/minimal-diff assertions hold."
  exit 0
else
  echo "RESULT: FAIL — ${fail_count} validation assertion(s) violated."
  echo ""
  echo "Violations:"
  for f in "${failures[@]}"; do
    printf '  * %s\n' "${f}"
  done
  exit 1
fi
