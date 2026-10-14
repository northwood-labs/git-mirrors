#!/usr/bin/env bash
#
# Bug condition exploration test — reviewdog-mirror-push-auth-fix (Task 1).
#
# Property 1 (Bug Condition): Authenticated mirror push to northwood-labs/reviewdog.
#
# This is a BUGFIX exploration test. On the UNFIXED workflow it is EXPECTED TO FAIL;
# that failure confirms the bug exists. The same test is re-run after the fix (task 3.4),
# where it is expected to PASS — i.e. it encodes the Expected Behavior (Property 1).
#
# The bug is a deterministic GitHub Actions config defect, not a locally runnable git push.
# Per the design's "Scoped PBT Approach", we encode the two preconditions of isBugCondition
# as parsing/assertion checks against .github/workflows/reviewdog.yml:
#
#   isBugCondition(input) is TRUE (bug present) when, for a write to
#   northwood-labs/reviewdog over github.com:
#     - gitHasCredentialForHost == false   (no url.*.insteadOf rewrite in "Set Git config"), OR
#     - tokenHasWriteScope("northwood-labs/reviewdog") == false
#                                          (reviewdog absent from gh_token `repositories`)
#
# The assertions below encode the EXPECTED BEHAVIOR (Property 1), i.e. the NEGATION of the
# bug condition:
#   A1. The gh_token step's `repositories` includes `reviewdog`  (token carries write scope)
#   A2. The "Set Git config" step contains a `url."...@github.com/".insteadOf "https://github.com/"`
#       rewrite                                                   (App token reaches git transport)
#
# Requirements: 1.1, 1.2 (bug), 2.1, 2.2 (expected behavior encoded by the assertions)

set -uo pipefail

# Unset CDPATH so `cd` does not echo the target directory into our command substitution.
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
WORKFLOW="${REPO_ROOT}/.github/workflows/reviewdog.yml"

TARGET_REPO="northwood-labs/reviewdog"

fail_count=0
counterexamples=()

note_pass() {
  printf '  [PASS] %s\n' "$1"
}

note_fail() {
  printf '  [FAIL] %s\n' "$1"
  counterexamples+=("$1")
  fail_count=$((fail_count + 1))
}

if [[ ! -f "${WORKFLOW}" ]]; then
  echo "ERROR: workflow not found at ${WORKFLOW}" >&2
  exit 2
fi

echo "== Bug condition exploration: ${TARGET_REPO} mirror push auth =="
echo "Workflow under test: ${WORKFLOW}"
echo ""

# --- Extract the gh_token (actions/create-github-app-token) step's `repositories` input. ---
# The input may be a single scalar (`repositories: git-mirrors`) or a YAML block scalar
# (`repositories: |` followed by indented repo names). We capture whichever form is present.
#
# Strategy: find the `create-github-app-token` step, then read its `with:` block up to the next
# step boundary, and pull the `repositories` value(s) out of that block.
app_token_block="$(
  awk '
    /uses:[[:space:]]*actions\/create-github-app-token/ { in_step = 1 }
    in_step {
      print
      # A new list item at the step indentation ends the current step.
      if (seen && $0 ~ /^[[:space:]]{6}-[[:space:]]/) { exit }
      if ($0 ~ /^[[:space:]]{6}-[[:space:]]/) { seen = 1 }
    }
  ' "${WORKFLOW}"
)"

# Pull the repositories value whether inline or a block list.
repositories_values="$(
  printf '%s\n' "${app_token_block}" | awk '
    /^[[:space:]]*repositories:[[:space:]]*\|/ { block = 1; next }
    /^[[:space:]]*repositories:[[:space:]]*[^|[:space:]]/ {
      sub(/^[[:space:]]*repositories:[[:space:]]*/, "")
      print
      next
    }
    block {
      # Block scalar lines are more indented than the key; a line that de-indents to another
      # key (contains ":") ends the block.
      if ($0 ~ /^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]/) { block = 0; next }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (length($0) > 0) print
    }
  '
)"

echo "Discovered gh_token 'repositories' scope:"
if [[ -z "${repositories_values}" ]]; then
  echo "  (none found)"
else
  printf '  - %s\n' ${repositories_values}
fi
echo ""

# --- Assertion A1: token scope must include `reviewdog`. ---
if printf '%s\n' ${repositories_values} | grep -qx "reviewdog"; then
  note_pass "A1: gh_token repositories includes 'reviewdog' (token has write scope for ${TARGET_REPO})"
else
  note_fail "A1: tokenHasWriteScope(\"${TARGET_REPO}\") == false — 'reviewdog' absent from gh_token repositories (scope: [${repositories_values//$'\n'/, }]) → push to ${TARGET_REPO} would be rejected HTTP 403"
fi

# --- Extract the "Set Git config" step body. ---
set_git_config_block="$(
  awk '
    /name:[[:space:]]*Set Git config/ { in_step = 1; print; next }
    in_step {
      # The next step (list item at 6-space indent) ends this step.
      if ($0 ~ /^[[:space:]]{6}-[[:space:]]/) { exit }
      print
    }
  ' "${WORKFLOW}"
)"

# --- Assertion A2: a url.*.insteadOf rewrite for github.com must be present. ---
# Match the proven go-x-perf.yml pattern: git config --global url."https://...@github.com/".insteadOf
if printf '%s\n' "${set_git_config_block}" \
  | grep -Eq 'url\."https://[^"]*@github\.com/"\.insteadOf'; then
  note_pass "A2: 'Set Git config' contains a url.*.insteadOf rewrite (App token reaches git HTTPS transport)"
else
  note_fail "A2: gitHasCredentialForHost == false — no 'url.*@github.com/.insteadOf' rewrite in 'Set Git config' step → git transport ignores GH_TOKEN, push to ${TARGET_REPO} would be rejected HTTP 401"
fi

echo ""
if [[ "${fail_count}" -eq 0 ]]; then
  echo "RESULT: PASS — expected behavior satisfied (bug condition NOT present)."
  exit 0
else
  echo "RESULT: FAIL — bug condition present (${fail_count} precondition(s) of isBugCondition hold)."
  echo ""
  echo "Counterexamples demonstrating the bug:"
  for ce in "${counterexamples[@]}"; do
    printf '  * %s\n' "${ce}"
  done
  exit 1
fi
