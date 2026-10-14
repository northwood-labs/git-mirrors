# Bugfix Requirements Document

## Introduction

The `Reviewdog` workflow (`.github/workflows/reviewdog.yml`) mirrors the upstream `reviewdog/reviewdog` repository into `northwood-labs/reviewdog`. The "Sync" step clones the public upstream repo as a bare clone and then runs `git push --force --mirror` to the northwood-labs fork over HTTPS.

The mirror push fails with an HTTP 401 (no identity) or 403 (identity lacks write access) error. A GitHub App token is generated earlier in the job (step id `gh_token`) and exported as the `GH_TOKEN` environment variable, but a bare `git push` over HTTPS does not consume `GH_TOKEN` — that variable is only honored by the `gh` CLI, not by git's HTTPS transport. As a result the push to `northwood-labs/reviewdog` is unauthenticated and GitHub rejects it. The upstream `git clone` succeeds because anonymous HTTPS read of the public upstream repo is permitted.

The fix must make the mirror push authenticate with the GitHub App token so it succeeds, without breaking the upstream read clone or the other authenticated operations in the workflow.

## Bug Analysis

### Current Behavior (Defect)

When the Sync step runs its push, the push URL carries no credentials and the operation is rejected by GitHub.

* 1.1 WHEN the Sync step runs `git push --force --mirror "https://github.com/northwood-labs/reviewdog"` with only `GH_TOKEN` set in the environment THEN the system performs the push unauthenticated and GitHub rejects it with HTTP 401 or 403, failing the step
* 1.2 WHEN the push to `northwood-labs/reviewdog` is attempted over HTTPS THEN the system does not apply the GitHub App token to git's HTTPS transport, so no write credential reaches the push target

### Expected Behavior (Correct)

The mirror push should present the GitHub App token to GitHub's HTTPS transport so the write operation is authenticated and completes.

* 2.1 WHEN the Sync step runs `git push --force --mirror` to `northwood-labs/reviewdog` with the GitHub App token available THEN the system SHALL authenticate the push using the token and complete the mirror push successfully
* 2.2 WHEN the push target repository requires write access THEN the system SHALL present the GitHub App token credential to GitHub so the push is authorized

### Unchanged Behavior (Regression Prevention)

The fix must not alter the behavior of operations that already work, including the anonymous upstream read clone and the already-authenticated `gh` CLI and later checkout/push steps.

* 3.1 WHEN the Sync step runs `git clone --bare "https://github.com/reviewdog/reviewdog"` of the public upstream repo THEN the system SHALL CONTINUE TO complete the anonymous read clone successfully
* 3.2 WHEN `gh` CLI commands run using `GH_TOKEN` (e.g. resolving the latest reviewdog release, release/asset operations) THEN the system SHALL CONTINUE TO authenticate and function as before
* 3.3 WHEN later steps push to or clone from `northwood-labs/reviewdog` (e.g. "Disable upstream workflows", "Clone Reviewdog") THEN the system SHALL CONTINUE TO authenticate and succeed as before
* 3.4 WHEN the harden-runner egress policy is enforced THEN the system SHALL CONTINUE TO reach only already-allowed endpoints, since `github.com:443` is already permitted and no new endpoint is introduced
