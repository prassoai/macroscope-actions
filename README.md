# macroscope-actions

Composite GitHub Actions for [Macroscope](https://macroscope.com) — run
Macroscope agents from workflows you own.

**The model: your workflow owns the run.** Triggers, sequencing, retries,
concurrency, cancellation, and the conclusion are all yours, in GitHub's
native vocabulary — `on:`, `needs:`, `if:`, `strategy.matrix`,
`concurrency:`. Macroscope is the execution backend: the `run` action starts
an agent (defined as markdown under
`.macroscope/check-run-agents/github-actions/` in your repo), holds the run
open, and reports its verdict and findings as step outputs. The workflow job
is itself the check — there is no Macroscope-owned check run on this path —
so branch protection reads your job's conclusion directly, and any event is a
valid trigger: `pull_request`, `push`, `schedule`, `release`,
`workflow_dispatch`, `workflow_run`.

The `run` action is the supported workflow entry point. It mints GitHub OIDC,
starts or rejoins one durable Macroscope run, polls until the server returns a
terminal result, and writes the result as step outputs.

## Governance

> **Canonical source: [`prassoai/back`](https://github.com/prassoai/back).**
> This repository is a generated artifact of that monorepo's release
> workflow, so the actions, the API they call, and their tests change
> together. It accepts no contributions — pull requests are closed by policy,
> and support and source live in the monorepo.

Repository access restrictions, branch and tag protection, and feature
availability are managed in GitHub repository settings, not enforced by this
source tree. Do not assume those protections are configured; verify the
repository settings directly.

## Authentication

The `run` action authenticates with a per-job **GitHub OIDC token** — there is
no Macroscope API key or secret to store, rotate, or leak. The job grants
`id-token: write`; the action mints the token and Macroscope verifies its
claims against a repo-level trust policy. GitHub Actions agent runs default
to enabled for existing and new repository settings; a repo admin can disable
the integration in Macroscope settings.

```yaml
permissions:
  contents: read
  id-token: write       # REQUIRED: mints the OIDC token that authenticates to Macroscope
  # no checks: scope — the job itself is the check run, concluded by GitHub
```

A `permissions:` map is **closed** — every scope it does not list is revoked —
so `id-token: write` must be present. Without it the action fails immediately,
naming the missing scope.

## Usage

Full-diff agents pass an explicit `base`:

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
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
      - id: macroscope
        uses: prassoai/macroscope-actions/run@<sha> # v1
        with:
          repository: ${{ github.repository }}
          agent: Release Audit
          commit: ${{ github.event.pull_request.head.sha }}
          base: ${{ github.event.pull_request.base.sha }}
          fail-on: failure
          timeout: "1800"
          additional-instructions: |
            Focus on release-blocking regressions.
```

PR metadata agents pass `pull-request` instead:

```yaml
name: Macroscope PR Metadata

on:
  pull_request:

permissions:
  contents: read
  id-token: write

jobs:
  pr-metadata:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
      - id: macroscope
        uses: prassoai/macroscope-actions/run@<sha> # v1
        with:
          repository: ${{ github.repository }}
          agent: PR Metadata Audit
          commit: ${{ github.event.pull_request.head.sha }}
          pull-request: ${{ github.event.pull_request.number }}
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `api-url` | no | `https://hooks.macroscope.com` | HTTPS Macroscope control plane URL. |
| `repository` | yes | | Repository in `owner/name` form; must match GitHub OIDC claims. |
| `agent` | yes | | Agent title under `.macroscope/check-run-agents/github-actions/`. |
| `commit` | no | `${{ github.sha }}` | Target commit SHA. |
| `base` | no | | Base commit SHA for diff-shaped inputs. |
| `pull-request` | no | | Pull request number for PR metadata inputs and PR-scoped tools. |
| `fail-on` | no | `failure` | `failure`, `neutral`, or `never`. |
| `timeout` | no | `1800` | Maximum seconds to wait for a terminal result. |
| `additional-instructions` | no | | Extra prompt text, capped at 16 KiB. |

## Outputs

| Output | Description |
| --- | --- |
| `run-id` | Durable Macroscope run ID. Written once start succeeds. |
| `verdict` | Terminal verdict: `success`, `neutral`, or `failure`. |
| `summary` | Terminal agent summary. |
| `findings` | Terminal findings reference. |
| `cost-usd` | Raw inference cost rendered as USD. |

## Runtime behavior

Polling is the execution lease. While the backend reports `pending` or
`running`, each poll renews the lease; if the workflow is cancelled or the
runner dies, polling stops and Macroscope lapses the run server-side. The
action retries transport failures, server errors, `429`, and rate-limited
`403` responses within the remaining timeout budget.

`fail-on` maps the terminal result to the step exit status. `failure` fails
only on a failed or absent verdict, `neutral` also fails on neutral, and
`never` leaves the step green for agent outcomes and timeouts. Terminal outputs
are written before any fail-on failure so `if: always()` consumers can inspect
the result.

## Versioning / pinning

**Pin to a full commit SHA** — `uses: prassoai/macroscope-actions/run@<sha>` —
with a trailing `# v1.x.y` comment for readability. A mutable tag (`@v1`,
`@main`) lets a retagged upstream run attacker-controlled code inside a job
that can mint an OIDC token; an immutable SHA cannot move under you.

There is no container image anywhere in these actions — the payload is
`curl`, `jq`, and `openssl` (for random output delimiters), all present on
every GitHub-hosted runner — so a SHA pin covers the entire code path.

## License

MIT
