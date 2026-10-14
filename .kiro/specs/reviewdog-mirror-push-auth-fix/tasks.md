# Implementation Plan

- [x] 1. Write bug condition exploration test for the unauthenticated / mis-scoped mirror push
  - **Property 1: Bug Condition** - Authenticated mirror push to northwood-labs/reviewdog
  - **CRITICAL**: This test MUST FAIL on the unfixed workflow - failure confirms the bug exists
  - **DO NOT attempt to fix the test or the code when it fails**
  - **NOTE**: This test encodes the expected behavior - it will validate the fix when it passes after implementation
  - **GOAL**: Surface counterexamples that demonstrate the bug exists (HTTP 401 no-credential, HTTP 403 wrong-scope)
  - **Scoped PBT Approach**: This is a deterministic config bug. Scope the property to the concrete failing cases rather than fuzzing a live push:
    - Case A (defect 1 - no credential): with only `GH_TOKEN` exported and NO git `insteadOf`/credential config, run `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` → expect HTTP 401 (git transport does not read `GH_TOKEN`).
    - Case B (defect 2 - wrong scope): request an App token with `repositories: git-mirrors` only, attach it to the push, and attempt a write to `northwood-labs/reviewdog` → expect HTTP 403 (token lacks write scope on the target).
    - Case C (latent, same bug - defect 3): after an `actions/checkout` with `persist-credentials: false`, run `git push origin <branch>` with no global credential rewrite → expect HTTP 401/403.
  - Encode these as a parsing/assertion check against the UNFIXED `.github/workflows/reviewdog.yml`: assert the `gh_token` step's `repositories` lists only `git-mirrors` (not `reviewdog`), and assert the "Set Git config" step contains NO `url.*.insteadOf` rewrite — the two preconditions of `isBugCondition` from the design.
  - The test assertions should match the Expected Behavior (Property 1): an HTTPS write to `northwood-labs/reviewdog` presents the App token to git's transport AND the token carries write scope for `northwood-labs/reviewdog`.
  - Run the check on UNFIXED code
  - **EXPECTED OUTCOME**: Test FAILS (this is correct - it proves the bug exists: no `insteadOf` rewrite present and `reviewdog` absent from token scope)
  - Document counterexamples found (e.g., "Sync push → 401 with no credential; 403 when a `git-mirrors`-scoped token is attached"; "`insteadOf` rewrite absent from Set Git config step"; "`reviewdog` absent from `repositories`")
  - Mark task complete when the test is written, run, and the failure is documented
  - _Bug_Condition: isBugCondition(input) where input.operation == "write" AND input.host == "github.com" AND input.targetRepo == "northwood-labs/reviewdog" AND (gitHasCredentialForHost == false OR tokenHasWriteScope("northwood-labs/reviewdog") == false)_
  - _Requirements: 1.1, 1.2_

- [x] 2. Write preservation property tests (BEFORE implementing fix)
  - **Property 2: Preservation** - Non-write and non-reviewdog operations unchanged
  - **IMPORTANT**: Follow observation-first methodology — observe behavior on the UNFIXED workflow for all inputs where `isBugCondition` returns false, then assert that behavior across the input domain
  - Observe on UNFIXED code and record outcomes:
    - Upstream anonymous bare clone `git clone --bare "https://github.com/reviewdog/reviewdog"` succeeds (read, no credential).
    - `gh` CLI calls driven by `GH_TOKEN` succeed: `gh api /repos/reviewdog/reviewdog/releases/latest`, `gh release create`/`view`, `gh release upload`, `gh api /users/...`.
    - Mirror read clone "Clone Reviewdog" `git clone --single-branch ... "https://github.com/northwood-labs/reviewdog.git"` result.
    - Git identity config (`advice.detachedHead`, `user.name`, `user.email`) is applied as before.
    - Harden-runner egress policy: `github.com:443` is the only github host contacted and it is already allowed; no new endpoint is required.
  - Write property-based / assertion tests capturing those observed patterns from the Preservation Requirements:
    - For all anonymous read operations over HTTPS (upstream bare clone, mirror read clone): result == success and is independent of the credential rewrite.
    - For all `gh` CLI operations: unchanged (they consume `GH_TOKEN` directly, not git transport).
    - Static assertion: the Sync push command and target `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` and the identity-config lines are byte-for-byte unchanged between unfixed and fixed workflow (minimal-diff).
    - Static assertion: the harden-runner `allowed-endpoints` block introduces no new host.
  - Run tests on UNFIXED code
  - **EXPECTED OUTCOME**: Tests PASS (this confirms the baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Preservation: Preservation Requirements from design (anonymous reads, gh CLI, identity config, egress policy)_
  - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 3. Fix for unauthenticated / mis-scoped mirror push to northwood-labs/reviewdog

  - [x] 3.1 Widen the GitHub App token scope (Change 1 — fixes root cause 2)
    - In the `gh_token` step (`actions/create-github-app-token`) in `.github/workflows/reviewdog.yml`, change `repositories: git-mirrors` to a multi-line list including both repos:
      ```yaml
      repositories: |
        git-mirrors
        reviewdog
      ```
    - Retain `owner: northwood-labs` and `permission-contents: write` (write is required for the push)
    - **Operational prerequisite to surface to the user**: the GitHub App installation must actually be granted access to `northwood-labs/reviewdog`; otherwise the token request fails or the token omits `reviewdog`
    - _Bug_Condition: isBugCondition where tokenHasWriteScope("northwood-labs/reviewdog") == false_
    - _Expected_Behavior: expectedBehavior(result) — token carries write scope for northwood-labs/reviewdog_
    - _Preservation: `git-mirrors` scope retained; `permission-contents: write` retained_
    - _Requirements: 2.1, 2.2_

  - [x] 3.2 Wire the App token into git's HTTPS transport (Change 2 — fixes root causes 1 and 3)
    - In the existing "Set Git config" step (which already sets `env: GH_TOKEN: ${{ steps.gh_token.outputs.token }}`), add a global `insteadOf` rewrite before the identity config, modeled on `go-x-perf.yml`:
      ```bash
      git config --global \
        url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf \
        "https://github.com/"
      ```
    - Keep all existing identity config lines (`advice.detachedHead`, `user.name`, `user.email`) unchanged
    - Leave the Sync step push command unchanged — the rewrite handles authentication for it and for the later "Disable upstream workflows" push (root cause 3)
    - _Bug_Condition: isBugCondition where gitHasCredentialForHost == false_
    - _Expected_Behavior: expectedBehavior(result) — App token presented to git HTTPS transport for every https://github.com/ operation_
    - _Preservation: identity config unchanged; Sync push command unchanged; no new egress endpoint (host stays github.com:443)_
    - _Requirements: 2.1, 2.2, 3.3_

  - [x] 3.3 Validate the edited workflow (YAML validity + structural assertions)
    - Assert `.github/workflows/reviewdog.yml` parses as valid YAML
    - Assert the `gh_token` step `repositories` block lists BOTH `git-mirrors` and `reviewdog`
    - Assert the "Set Git config" step contains the `url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"` rewrite AND that `GH_TOKEN` is present in that step's `env`
    - Minimal-diff check: assert the Sync push command/target `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` is unchanged and no new harden-runner endpoint was added
    - _Requirements: 2.1, 2.2, 3.4_

  - [x] 3.4 Verify bug condition exploration test now passes
    - **Property 1: Expected Behavior** - Authenticated mirror push to northwood-labs/reviewdog
    - **IMPORTANT**: Re-run the SAME test from task 1 - do NOT write a new test
    - The test from task 1 encodes the expected behavior; when it passes, the expected behavior is satisfied
    - Run the bug condition exploration test from step 1 against the fixed workflow
    - **EXPECTED OUTCOME**: Test PASSES (`insteadOf` rewrite present; `reviewdog` in token scope) — confirms the bug is fixed
    - _Requirements: 2.1, 2.2_

  - [x] 3.5 Verify preservation tests still pass
    - **Property 2: Preservation** - Non-write and non-reviewdog operations unchanged
    - **IMPORTANT**: Re-run the SAME tests from task 2 - do NOT write new tests
    - Run the preservation property tests from step 2 against the fixed workflow
    - **EXPECTED OUTCOME**: Tests PASS (anonymous reads, `gh` CLI, identity config, egress policy, Sync command all unchanged) — confirms no regressions
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 4. End-to-end verification via workflow_dispatch
  - Trigger the `Reviewdog` workflow manually (`workflow_dispatch`) with both changes applied
  - Confirm the Sync step's `git push --force --mirror` completes (HTTP 2xx) and `northwood-labs/reviewdog` reflects the mirrored refs (Fix Checking / Property 1)
  - Confirm the latent "Disable upstream workflows" `git push origin ...` now succeeds (root cause 3 covered by the global rewrite)
  - Confirm preserved operations still succeed in the same run: upstream bare clone, `gh` CLI release/asset steps, "Clone Reviewdog" read clone (Preservation Checking / Property 2)
  - Secret-hygiene check: confirm the App token does not appear in step logs and is not surfaced by any `git remote -v` output
  - _Requirements: 2.1, 2.2, 3.1, 3.2, 3.3, 3.4_

- [~] 5. Checkpoint - Ensure all tests pass
  - Ensure the exploration test (task 1) passes, preservation tests (task 2) pass, structural validations (task 3.3) pass, and the end-to-end `workflow_dispatch` run (task 4) is green
  - Ask the user if questions arise (notably the operational prerequisite: App installation access to `northwood-labs/reviewdog`)
