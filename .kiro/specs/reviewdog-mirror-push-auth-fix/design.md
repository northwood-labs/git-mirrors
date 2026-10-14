# Reviewdog Mirror Push Auth Fix Bugfix Design

## Overview

The `Reviewdog` workflow (`.github/workflows/reviewdog.yml`) mirrors the public upstream `reviewdog/reviewdog` repository into `northwood-labs/reviewdog`. The "Sync" step bare-clones the upstream repo (anonymous HTTPS read, which works) and then runs `git push --force --mirror "https://github.com/northwood-labs/reviewdog"`. That push fails with HTTP 401/403 because git's HTTPS transport never receives a credential.

There are **two distinct defects** behind the failure, and the fix must address both:

1. **No credential reaches git's HTTPS transport.** A GitHub App token is generated (step id `gh_token`) and exported as the `GH_TOKEN` env var, but `GH_TOKEN` is only consumed by the `gh` CLI — a bare `git push` over HTTPS ignores it. So the push is unauthenticated (401).

2. **The token is scoped to the wrong repository.** The `actions/create-github-app-token` step is configured with `owner: northwood-labs` and `repositories: git-mirrors`. The resulting installation token only has write access to `northwood-labs/git-mirrors`, not to the push target `northwood-labs/reviewdog`. Even once a credential is wired into git, the push would still be rejected (403) until the token is scoped to the target repo.

The fix strategy mirrors the proven, already-working pattern in the sibling `go-x-perf.yml` workflow in this same repo: it configures git globally with a `url.<auth>.insteadOf` rewrite so every `https://github.com/` operation carries the credential, and its mirror push succeeds. We apply the same `insteadOf` approach here (using the GitHub App token instead of a PAT), and we widen the App token's `repositories` scope to include `reviewdog`.

Choosing the global `insteadOf` rewrite (option b) over embedding the token only in the single Sync push URL (option a) also repairs a latent instance of the same bug in the later "Disable upstream workflows" step, which runs a bare `git push origin ...` after an `actions/checkout` that was configured with `persist-credentials: false` (so it, too, has no credential wired into git).

## Glossary

- **Bug_Condition (C)**: The condition that triggers the bug — a `git` HTTPS write (push) to `northwood-labs/reviewdog` is attempted while git's HTTPS transport has no credential configured for `github.com`, and/or while the available token lacks write scope on the target repo.

- **Property (P)**: The desired behavior — the push authenticates with the GitHub App token and completes successfully against `northwood-labs/reviewdog`.

- **Preservation**: Behaviors that must remain unchanged — the anonymous upstream read clone of `reviewdog/reviewdog`, the `gh` CLI operations driven by `GH_TOKEN`, the anonymous read clone in "Clone Reviewdog", and the harden-runner egress policy (no new endpoints; `github.com:443` is already allowed).

- **GH_TOKEN**: Env var holding `${{ steps.gh_token.outputs.token }}`, the GitHub App installation token. Consumed by the `gh` CLI only — NOT by git's native HTTPS transport unless git is explicitly configured to use it.

- **gh_token step**: The `actions/create-github-app-token` step whose `repositories` input determines which repos the installation token can write to.

- **Sync step**: The step `Sync https://github.com/reviewdog/reviewdog → github.com/northwood-labs/reviewdog` that performs the bare clone and the failing mirror push.

- **insteadOf rewrite**: A `git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"` rule that transparently injects credentials into every `https://github.com/` URL git touches.

## Bug Details

### Bug Condition

The bug manifests whenever the Sync step performs its mirror push: the push URL `https://github.com/northwood-labs/reviewdog` carries no credentials, git's global config has no rewrite/header that injects one, and the only token present (`GH_TOKEN`) is invisible to git's transport. Compounding this, the App installation token is scoped only to `git-mirrors`, so even an authenticated request would lack write permission on `reviewdog`.

#### Formal Specification

```plain
FUNCTION isBugCondition(input)
  INPUT: input of type GitHttpsOperation
    // fields: operation ("read" | "write"), host, targetRepo,
    //         gitHasCredentialForHost (boolean), tokenHasWriteScope(repo) (boolean)
  OUTPUT: boolean

  RETURN input.operation == "write"
         AND input.host == "github.com"
         AND input.targetRepo == "northwood-labs/reviewdog"
         AND (
               input.gitHasCredentialForHost == false      // defect 1: no credential in git transport
               OR input.tokenHasWriteScope("northwood-labs/reviewdog") == false  // defect 2: wrong scope
             )
END FUNCTION
```

### Examples

- **Sync mirror push (primary):** `cd .reviewdog && git push --force --mirror "https://github.com/northwood-labs/reviewdog"`. Expected: push succeeds and the mirror is updated. Actual: HTTP 401 (no credential) — and even if a credential were present, HTTP 403 because the token is scoped to `git-mirrors`, not `reviewdog`.

- **"Disable upstream workflows" push (latent, same bug):** after `actions/checkout` with `persist-credentials: false`, the step runs `git push origin "$(git rev-parse --abbrev-ref HEAD)"`. Expected: the commit disabling upstream workflows is pushed. Actual: no credential wired into git → 401/403.

- **Upstream bare clone (NOT the bug — read, preserved):** `git clone --bare "https://github.com/reviewdog/reviewdog"`. Expected and actual: succeeds via anonymous public read. `isBugCondition` returns false (operation is "read").

- **Edge case — "Clone Reviewdog" anonymous read:** `git clone ... "https://github.com/northwood-labs/reviewdog.git"`. This is a read; if the mirror repo is public it succeeds anonymously. `isBugCondition` returns false. (After the fix it will carry credentials harmlessly via the `insteadOf` rewrite, which is still a valid read.)

## Expected Behavior

### Preservation Requirements

#### Unchanged Behaviors

- The anonymous upstream read clone `git clone --bare "https://github.com/reviewdog/reviewdog"` must continue to complete successfully (requirement 3.1).

- `gh` CLI commands driven by `GH_TOKEN` (latest-release lookup, release create/view, asset upload, `gh api`) must continue to authenticate and function as before (requirement 3.2).

- Later operations against `northwood-labs/reviewdog` ("Disable upstream workflows" push, "Clone Reviewdog" clone) must continue to succeed — and in fact the "Disable upstream workflows" push, which shares defect 1, must now succeed rather than silently depend on it (requirement 3.3).

- The harden-runner egress policy must continue to permit only already-allowed endpoints; `github.com:443` is already allowed and no new endpoint is introduced (requirement 3.4).

#### Scope

All inputs that do NOT satisfy the bug condition must be completely unaffected by this fix. This includes:

- Anonymous read clones over HTTPS (upstream bare clone, mirror read clone).
- `gh` CLI operations (they already consume `GH_TOKEN` directly and are unchanged).
- Git identity config (`user.name`, `user.email`, `advice.detachedHead`) set in the "Set Git config" step, which remains intact.

**Note:** The expected correct behavior (authenticated, successful push) is defined precisely in the Correctness Properties section (Property 1). This section captures what must NOT change.

## Hypothesized Root Cause

Based on the bug description and the real workflow code, the root causes are:

1. **Credential not wired into git's HTTPS transport (primary).** `GH_TOKEN` is set in the step env, but git's native HTTPS transport does not read `GH_TOKEN`. Only the `gh` CLI does. The Sync push therefore goes out unauthenticated and GitHub returns 401. This is confirmed by contrast with the sibling `go-x-perf.yml`, whose mirror push works precisely because it runs `git config --global url."https://<token>@github.com/".insteadOf "https://github.com/"` first.

1. **GitHub App token scoped to the wrong repository (secondary, blocks even an authenticated push).** `actions/create-github-app-token` is configured with `repositories: git-mirrors`. The installation token has write access only to `northwood-labs/git-mirrors`, not to the push target `northwood-labs/reviewdog`. Pushing to `reviewdog` with this token would yield HTTP 403 even once a credential is attached.

1. **Latent duplicate of root cause 1 in a later step.** "Disable upstream workflows" uses `actions/checkout` with `persist-credentials: false` and then `git push origin ...`. With no global credential rewrite, this push has no credential either. A URL-embedding fix limited to the single Sync command (option a) would leave this step broken; a global `insteadOf` fix (option b) covers it.

1. **Not a cause — anonymous read works.** The upstream clone and the mirror read clone succeed via public anonymous read, which is why only the write operations fail. No fix is needed for reads.

## Correctness Properties

### Property 1: Bug Condition - Authenticated mirror push to northwood-labs/reviewdog

_For any_ input where the bug condition holds (`isBugCondition` returns true — an HTTPS write to `northwood-labs/reviewdog`), the fixed workflow SHALL present the GitHub App token to git's HTTPS transport and the token SHALL carry write scope for `northwood-labs/reviewdog`, so that the `git push --force --mirror` completes successfully (HTTP 2xx) and the mirror is updated.

**Validates: Requirements 2.1, 2.2**

### Property 2: Preservation - Non-write and non-reviewdog operations unchanged

_For any_ input where the bug condition does NOT hold (`isBugCondition` returns false — anonymous read clones over HTTPS, `gh` CLI operations driven by `GH_TOKEN`, and the harden-runner egress decision), the fixed workflow SHALL produce the same result as the original workflow, preserving the upstream bare clone, the mirror read clone, all `gh` CLI behavior, git identity configuration, and the set of allowed network endpoints.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

## Fix Implementation

### Changes Required

The fix has two coordinated changes in `.github/workflows/reviewdog.yml`, modeled on the proven `go-x-perf.yml` pattern already present in this repository.

**File**: `.github/workflows/reviewdog.yml`

#### Change 1 — Widen the GitHub App token scope (fixes root cause 2)

In the `gh_token` step (`actions/create-github-app-token`), add the mirror target repository to the `repositories` list so the installation token has write access to it:

```yaml
      - name: Fetch temporary app token for job
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        id: gh_token
        with:
          client-id: ${{ vars.MIRRORING_CLIENT_ID }}
          private-key: ${{ secrets.MIRRORING_PRIVATE_KEY }}
          owner: northwood-labs
          repositories: |
            git-mirrors
            reviewdog
          permission-contents: write
```

- The App installation must actually be granted access to `northwood-labs/reviewdog` for this to take effect; if the installation does not include that repo, the token request itself will fail or the token will not include it. This is an operational prerequisite to call out to the user.

- `permission-contents: write` is retained — it is required for the push.

#### Change 2 — Wire the token into git's HTTPS transport (fixes root causes 1 and 3)

In the existing "Set Git config" step, add a global `insteadOf` rewrite so every
`https://github.com/` operation git performs carries the App token. The token must be available to
this step via the step `env` (it currently only sets `GH_TOKEN`, which is reused here):

```yaml
      - name: Set Git config
        env:
          GH_TOKEN: ${{ steps.gh_token.outputs.token }}
        run: |
          git config --global advice.detachedHead false

          # Authenticate all github.com HTTPS operations with the GitHub App token.
          git config --global \
            url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf \
            "https://github.com/"

          USERNAME='${{ steps.gh_token.outputs.app-slug }}[bot]'
          git config --global user.name "${USERNAME}"
          # ... (unchanged identity config) ...
```

#### Rationale and detail

1. **Transport authentication**: `x-access-token:<token>` is GitHub's documented basic-auth form for App installation tokens over HTTPS; the `insteadOf` rewrite transparently injects it into every `https://github.com/...` URL, including the Sync mirror push and the "Disable upstream workflows" push.

1. **Covers the latent bug**: because the rewrite is global and set before any git write, the later "Disable upstream workflows" `git push origin ...` is authenticated too (root cause 3).

1. **Reads still work**: the rewrite also applies to the upstream bare clone and the mirror read clone. Adding credentials to a public read is harmless and does not change the result, so preservation holds.

1. **No new endpoints**: the host remains `github.com:443`, already in the harden-runner allow-list; requirement 3.4 is satisfied.

1. **Sync step left as-is**: the push command `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` does not need editing — the rewrite handles authentication. This keeps the Sync step diff minimal and consistent with `go-x-perf.yml`.

#### Options considered and rejected

- **Embed the token only in the Sync push URL** (`https://x-access-token:${GH_TOKEN}@github.com/northwood-labs/reviewdog`): fixes the Sync push but leaves the "Disable upstream workflows" push broken (root cause 3), and risks leaking the token into logs/`git remote -v`. Rejected as incomplete and less consistent.

- **`http.extraheader` with an `Authorization: Bearer`/`Basic` header**: workable, but diverges from the established repo pattern in `go-x-perf.yml` and is easier to get subtly wrong (base64 encoding, per-remote scoping). Rejected in favor of consistency.

- **Global `insteadOf` rewrite (CHOSEN)**: matches the proven sibling workflow, fixes both the Sync push and the latent "Disable upstream workflows" push, introduces no new endpoints, and leaves reads and `gh` CLI untouched.

## Testing Strategy

### Validation Approach

Because this is a GitHub Actions workflow (not a locally unit-testable function), "tests" are primarily workflow runs and targeted local reproductions of git's auth behavior. The approach is two-phase: first demonstrate the failure on the unfixed workflow, then verify the fix authenticates the push and preserves all non-buggy behavior.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bug BEFORE implementing the fix, and confirm or refute the two hypothesized root causes. If refuted, re-hypothesize.

**Test Plan**: Run the unfixed Sync step (or reproduce it locally with only `GH_TOKEN` exported and no git credential config) and observe the push failure and its HTTP status. Separately, inspect the `gh_token` `repositories` input to confirm the scope defect.

#### Test Cases

1. **Unauthenticated Sync push**: Run `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` with only `GH_TOKEN` in env and no `insteadOf` config → expect HTTP 401 (will fail on unfixed code).

1. **Scope check**: Request an App token with `repositories: git-mirrors` only, then attempt an authenticated push to `northwood-labs/reviewdog` → expect HTTP 403, confirming root cause 2 (will fail on unfixed scope).

1. **Latent "Disable upstream workflows" push**: After a `persist-credentials: false` checkout, run `git push origin <branch>` with no global credential config → expect 401/403 (will fail on unfixed code), confirming root cause 3.

1. **Edge case — anonymous reads succeed**: Run the upstream bare clone and the mirror read clone with no credentials → expect success, confirming reads are not part of the bug condition.

#### Expected Counterexamples

- The Sync push is rejected with 401 (no credential) and, once a credential is attached but the token is `git-mirrors`-scoped, 403 (insufficient scope).

- Possible causes to confirm: (1) `GH_TOKEN` not consumed by git transport, (2) token scoped to the wrong repo, (3) later push lacks credentials after `persist-credentials: false`.

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds, the fixed workflow produces the
expected authenticated, successful push.

#### Pseudocode

```plain
FOR ALL input WHERE isBugCondition(input) DO
  result := runFixedWorkflowOperation(input)   // Sync push, Disable-upstream push
  ASSERT result.httpStatus IN 2xx
  ASSERT result.pushCompleted == true
END FOR
```

Concretely: trigger the workflow (`workflow_dispatch`) with both changes applied and assert the Sync step and the "Disable upstream workflows" step both complete, and that `northwood-labs/reviewdog` reflects the mirrored refs.

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed workflow produces the same result as the original.

#### Pseudocode

```plain
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT originalWorkflowOperation(input) == fixedWorkflowOperation(input)
END FOR
```

#### Testing Approach

Property-style reasoning over the input domain of non-write/non-reviewdog operations is appropriate here because the preserved set (every anonymous read, every `gh` CLI call, the egress decision) is large and should behave identically. Observe each on the unfixed workflow first, then confirm identical behavior after the fix.

#### Test Plan

Record outcomes of the upstream bare clone, the mirror read clone, representative `gh` CLI calls, and the harden-runner egress result on the unfixed run; re-run after the fix and compare.

#### Test Cases

1. **Upstream read clone preservation**: Observe `git clone --bare "https://github.com/reviewdog/reviewdog"` succeeds on unfixed code; verify it still succeeds after the fix (now with harmless credentials injected).

1. **gh CLI preservation**: Observe `gh api /repos/reviewdog/reviewdog/releases/latest`, `gh release create/view`, and `gh release upload` work on unfixed code; verify unchanged after the fix.

1. **Mirror read clone preservation**: Observe "Clone Reviewdog" (`git clone ... northwood-labs/reviewdog.git`) result on unfixed code; verify unchanged after the fix.

1. **Egress policy preservation**: Confirm no new endpoint is required; `github.com:443` remains the only github host contacted and it is already allowed.

### Unit Tests

- Validate the edited `reviewdog.yml` parses as valid YAML and the `actions/create-github-app-token` `repositories` block lists both `git-mirrors` and `reviewdog`.

- Validate the "Set Git config" step contains the `url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf` rewrite and that `GH_TOKEN` is present in that step's `env`.

- Validate the Sync push target and command are unchanged (minimal-diff assertion).

### Property-Based Tests

- Over a generated set of git HTTPS operations varying `operation` (read/write), `targetRepo`, and presence of the credential rewrite: assert every write to `northwood-labs/reviewdog` authenticates (Property 1) and every non-bug-condition operation yields the same result as the original (Property 2).

- Over generated token-scope configurations: assert that a push to a repo not in the `repositories` list fails and that including `reviewdog` makes the push authorized — guarding against regressing the scope fix.

### Integration Tests

- Full `workflow_dispatch` run end-to-end: confirm the Sync mirror push, "Disable upstream workflows" push, "Clone Reviewdog" clone, and the release/asset steps all succeed in one run.

- Context/consistency test: confirm behavior matches the sibling `go-x-perf.yml` mirroring flow (same `insteadOf` authentication model), so the two mirror workflows stay consistent.

- Secret-hygiene check: confirm the token does not appear in step logs (the `insteadOf` value is set via config, and GitHub masks the token), and that `git remote -v` output in later steps does not surface the embedded credential unexpectedly.
