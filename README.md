# Macroscope for GitHub Actions

Run [Macroscope](https://macroscope.com) reviews from your GitHub workflows.
Use Approvability to review a pull request, or run an agent defined in your
repository. Your workflow controls when the review runs and whether its result
fails the job.

## Requirements

- An active Macroscope installation with GitHub Actions agent runs enabled for
  the repository. A repository admin can disable the integration in Macroscope
  settings. Scoped Approvability requires separate repository enablement.
- Job permission `id-token: write`. Macroscope authenticates with GitHub OIDC;
  no Macroscope API key is needed. `repository` must match the job's GitHub
  repository. No `checks: write` permission is needed.
- Bash, `curl`, `jq`, and `openssl`, included on GitHub-hosted Ubuntu runners.
  Self-hosted runners also need Actions Runner 2.327.1 or newer and access to
  GitHub's artifact service for the bundled uploader. GitHub Enterprise Server
  is not supported.

Supported triggers include `pull_request`, `push`, `schedule`, `release`, and
`workflow_dispatch`. GitHub must allow the job to obtain an OIDC token; do not
assume this is available to fork pull requests. `pull_request_target` and
`workflow_run` are rejected. Use `pull_request` for PR reviews, and `needs:` to
run a review after another job in the same workflow.

Replace `<sha>` in each example with a full commit SHA from
`prassoai/macroscope-actions`. Pin to that SHA rather than a moving branch or tag.

## Review a pull request

Approvability uses your repository's review policy, including exclusions,
approval settings, Preview Mode, and pricing. It publishes a Macroscope check
and may approve the PR if your policy allows it. Configure the policy in
`.macroscope/approvability.md`; the Action does not accept extra Approvability
instructions.

```yaml
name: Macroscope Approvability

on:
  pull_request:

permissions:
  contents: read
  id-token: write

jobs:
  approvability:
    runs-on: ubuntu-latest
    steps:
      - id: macroscope
        uses: prassoai/macroscope-actions/run@<sha>
        with:
          repository: ${{ github.repository }}
          review: approvability
          commit: ${{ github.event.pull_request.head.sha }}
          base: ${{ github.event.pull_request.base.sha }}
          pull-request: ${{ github.event.pull_request.number }}
```

No checkout step is needed: Macroscope reads the repository through its GitHub
app. The PR must be open and its head and base must match the supplied SHAs.
Outside PR events, supply all three values explicitly.

`fail-on` controls the workflow step, not the repository's approval policy.
Preview Mode and policy skips return a neutral result. A denied review may
return `failure`, depending on your repository's conclusion settings.

## Review selected files

Scoped Approvability publishes one check per scope and a neutral summary check.
**Scoped reviews never approve the PR.** Without separate repository enablement,
requests containing `scopes` are rejected.

Add `scopes` to an Approvability step to group exact changed file paths. Reviews
use the repository's policy.

Independent child analysis and automatic delegation are planned. Currently, all
scopes are evaluated together by the parent agent.

```yaml
name: Macroscope Scoped Review

on:
  pull_request:

permissions:
  contents: read
  id-token: write

jobs:
  scoped-review:
    runs-on: ubuntu-latest
    timeout-minutes: 140
    steps:
      - id: macroscope
        uses: prassoai/macroscope-actions/run@<sha>
        with:
          repository: ${{ github.repository }}
          review: approvability
          commit: ${{ github.event.pull_request.head.sha }}
          base: ${{ github.event.pull_request.base.sha }}
          pull-request: ${{ github.event.pull_request.number }}
          scopes: |
            [
              {
                "name": "inventory",
                "checkName": "Inventory review",
                "files": ["src/inventory.ts", "tests/inventory.test.ts"],
                "analysis": "parent",
                "responsible": {"users": ["octocat"], "teams": ["acme/inventory"]}
              }
            ]
```

Replace the example paths with files changed in your PR. `responsible` is
optional context, not verified ownership, reviewer requests, or permission grants.

### Scope fields and limits

| Field | Required | Description |
| --- | --- | --- |
| `name` | yes | Unique identifier, preserved exactly. 1–128 ASCII bytes: letters, digits, `.`, `_`, `/`, `-`; starts with a letter or digit. |
| `checkName` | yes | Unique GitHub check label, preserved exactly. 1–255 ASCII bytes: the same characters as `name`, plus spaces; starts with a letter or digit. Not sent to the model. |
| `files` | yes | 1–1024 unique, exact repository-relative changed paths per scope, each 1–256 bytes. No globs, directories, or `..` path segments. |
| `analysis` | no | `parent` (the default). Independent child analysis is not available. |
| `responsible.users`, `responsible.teams` | no | Lists of unique, nonempty context labels. Each list allows up to 128 entries, 256 bytes per entry, and 4096 bytes total. All responsibility labels across the request must fit in 8192 bytes. |

You can include up to 250 applicable scopes per PR invocation. This limits the
submitted scopes, not the total scope definitions in your repository. A 512 KiB
aggregate size limit also applies to the complete scope definition. Oversize
requests are rejected before run creation, not truncated; reduce paths or
metadata to fit. Time and model-context limits apply to the whole set, so staying
within the scope count does not guarantee a request will complete.

Omit `scopes` for an ordinary review; `[]` and `null` are invalid. Do not pass
`agent`, caller instructions, `analysis: child`, `analysis: auto`, or
`awaitResult: true`. There is no `scopes-file` or custom output-schema input.

## Run a configured agent

Create an agent Markdown file under
`.macroscope/check-run-agents/github-actions/` in the target commit. For example,
save this as `.macroscope/check-run-agents/github-actions/release-audit.md`:

```markdown
---
title: Release Audit
input: full_diff
---

Review the diff for release-blocking regressions. Summarize any issues.
```

Select the agent by its `title`, not its filename. Diff agents require `base`;
agents with `input: pr_metadata` require `pull-request` instead.

```yaml
name: Macroscope Release Audit

on:
  pull_request:

permissions:
  contents: read
  id-token: write

jobs:
  release-audit:
    runs-on: ubuntu-latest
    steps:
      - id: macroscope
        uses: prassoai/macroscope-actions/run@<sha>
        with:
          repository: ${{ github.repository }}
          agent: Release Audit
          commit: ${{ github.event.pull_request.head.sha }}
          base: ${{ github.event.pull_request.base.sha }}
          additional-instructions: Focus on changes to the release process.
```

The workflow job is the configured agent's check. Use that job as a required
check in branch protection if you want its result to block merging.

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `repository` | yes | | Repository in `owner/name` form; must match the job's GitHub identity. |
| `review` | no | `cra` | `cra` for a configured agent; `approvability` for Approvability. |
| `agent` | for `cra` | | Agent title. Omit for Approvability. |
| `commit` | outside PR events for Approvability | PR head for Approvability; `${{ github.sha }}` for CRA | Full 40-character target commit SHA. Explicit values override the default. Approvability does not default to the PR's synthetic merge commit. |
| `base` | for Approvability or diff agents | | Full 40-character base commit SHA. |
| `pull-request` | for Approvability or PR metadata agents | | PR number. Also needed for tools that act on a PR. |
| `scopes` | no | omitted | JSON array for scoped Approvability; requires separate repository enablement. See scope limits above. |
| `fail-on` | no | `failure` | When a review result fails the step; see below. |
| `timeout` | no | `auto` | Maximum seconds to wait, or `auto`: 1800 seconds ordinarily, 7800 seconds with `scopes`. Explicit values must be positive whole seconds. |
| `additional-instructions` | no; CRA only | | Extra prompt text, up to 16 KiB in bytes. Approvability rejects nonempty instructions. |
| `api-url` | no | `https://actions.macroscope.com` | Macroscope HTTPS API base URL. |

Set the GitHub job or step timeout high enough for the selected wait. The scoped
default allows two hours of execution plus ten minutes to receive the result.
A shorter explicit timeout can stop waiting before the review finishes.

| `fail-on` | Step fails when… |
| --- | --- |
| `failure` | The review fails or produces no verdict, including a timeout. Neutral results pass. |
| `neutral` | The review fails, is neutral, or produces no verdict. |
| `never` | Review outcomes and wait timeouts do not fail the step. |

Invalid inputs, authentication errors, malformed responses, and artifact upload
errors can still fail the Action regardless of `fail-on`.

## Results

| Output | Description |
| --- | --- |
| `run-id` | Macroscope run ID, available once the run starts. |
| `verdict` | Terminal verdict: `success`, `neutral`, or `failure`, when available. |
| `summary` | Terminal review summary, when available. |

Terminal outputs and a job summary are written before applying `fail-on`.
Later steps can use `if: always()` to inspect results even when the review fails.
The summary includes run status, verdict, summary text, reason when provided,
and Agent Credits or **Not billed** when billing information is available.
Scoped reviews also list each scope's result and check delivery status.

The Action uploads `result.json` to the workflow run's **Artifacts** section,
under `macroscope-result-<run-id>-<unique-suffix>`. Retention follows your
repository's artifact policy. The JSON contains:

- `schemaVersion`: `1` for ordinary reviews; `2` for scoped reviews.
- `runId`, `status` (`succeeded`, `failed`, or `cancelled`), `reason`, `verdict`,
  and `summary`. Missing reason, verdict, and summary values are JSON `null`.
- `agentCredits`, when available: an exact decimal string. `"0.000"` displays
  as **Not billed**.
- For version 2, `scopedReview.scopes` and `scopedReview.parentSummary`, including
  scope decisions or execution errors, check identities, and delivery status.
  `publicationStatus` is `pending`, `uncertain`, or `confirmed`; a recorded
  conclusion alone does not prove GitHub received it.

Check the schema version before processing an artifact. These are terminal
results, not a structured findings list. Summary text is preserved in JSON and
displayed as escaped, preformatted text in the job summary. Anyone who can read
the summary or artifacts can read the review's results; treat them like logs.

## Cancellation, retries, and billing

The Action starts or rejoins a Macroscope run and polls until it finishes.
It retries network failures, server errors, `429` responses, and rate-limited
`403` responses within the configured timeout.

Polling keeps the run active. If the job is cancelled, times out, or loses its
runner, polling stops and Macroscope stops the run after its polling lease
expires. This is not immediate cancellation or a rollback: work already
performed may still incur credits, and an approval already posted remains in
place. Ordinary Approvability uses its normal PR-state checks, which can lag
GitHub updates; cancellation does not guarantee an in-flight approval request
will be withdrawn.

Reviews follow your workspace's billing and spending limits. Use reported
Agent Credits to see the charge; do not infer billing from the review verdict
or GitHub job conclusion.

Timeouts, transport failures, and malformed responses do not create terminal
summaries or artifacts. `run-id` remains available if the run started. A terminal
artifact is uploaded even when `fail-on` fails the step, but hard cancellation
or runner loss can prevent publication or upload.

## Source and license

This Action and README are maintained in
[`prassoai/back`](https://github.com/prassoai/back/tree/staging/macroscope-actions)
and mirrored to `prassoai/macroscope-actions` by the release workflow. Submit
source changes in Back, not the generated mirror.

MIT
