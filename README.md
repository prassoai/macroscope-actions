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

> **This repository currently ships the groundwork** — the shared, unit-tested
> shell library the actions are built from ([`lib/`](./lib)). The `run` action
> lands with the Macroscope trigger API that backs it.

## Governance

> **Canonical source: [`prassoai/back`](https://github.com/prassoai/back).**
> This repository is a generated artifact of that monorepo's release
> workflow, so the actions, the API they call, and their tests change
> together. It accepts no contributions — pull requests are closed by policy,
> and support and source live in the monorepo.

The repository is configured at creation with pushes restricted to the
release workflow's identity (branch ruleset on `main`), a tag ruleset
protecting published versions, and Issues, Projects, Wiki, and Discussions
disabled. Verify against the repository settings rather than trusting this
paragraph: the enforcement lives there, not in this tree.

## Authentication

The `run` action authenticates with a per-job **GitHub OIDC token** — there is
no Macroscope API key or secret to store, rotate, or leak. The job grants
`id-token: write`; the action mints the token and Macroscope verifies its
claims against a repo-level trust policy (default deny — a repo admin enables
the integration in Macroscope settings).

```yaml
permissions:
  contents: read
  id-token: write       # REQUIRED: mints the OIDC token that authenticates to Macroscope
  # no checks: scope — the job itself is the check run, concluded by GitHub
```

A `permissions:` map is **closed** — every scope it does not list is revoked —
so `id-token: write` must be present. Without it the action fails immediately,
naming the missing scope.

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
