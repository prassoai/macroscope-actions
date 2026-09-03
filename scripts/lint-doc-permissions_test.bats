#!/usr/bin/env bats
# Unit tests for lint-doc-permissions.sh. The requirement: every documented
# yaml block is validated INDEPENDENTLY — a scope present in one block must not
# excuse a different block that omits it, because customers copy blocks, not
# files.

setup() {
  # shellcheck disable=SC1091
  source "${BATS_TEST_DIRNAME}/lint-doc-permissions.sh"
  FIXTURE="$(mktemp)"
}

teardown() {
  rm -f "$FIXTURE"
}

@test "passes a block that uses run with id-token: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
  id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  lint_file "$FIXTURE"
}

@test "fails a block that uses run without id-token: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# The file-level failure mode this lint exists to prevent: id-token: write
# present in ONE block must not excuse a DIFFERENT run block that omits it.
@test "fails when only a different block carries id-token: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  id-token: write
```

```yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
}

# The workflow job is itself the check run, concluded by GitHub — no action
# reads or writes the Checks API, so any checks: grant is over-permissioning.
@test "fails a block granting checks: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  checks: write
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
}

@test "fails a block granting checks: read" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  checks: read
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
}

# The exemption is for full-comment lines only: a YAML comment grants nothing,
# but a grant with a trailing comment is still a grant.
@test "fails a grant hiding behind a trailing comment" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  checks: write # NOT a grant
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
}

# YAML permits whitespace between a key and its colon; the spelling is the
# same grant and must not evade the bans.
@test "fails checks and blanket grants with whitespace before the colon" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions :
  checks : write
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions : write-all
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"write-all"* ]]
}

# permissions: write-all grants every scope including checks: write; blanket
# grants are rejected in blocks customers copy.
@test "fails a block granting permissions: write-all" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: write-all
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"write-all"* ]]
}

# A commented "# id-token: write" grants nothing; a block relying on it ships a
# broken OIDC mint to whoever copies it. The required scope must be an
# uncommented entry.
@test "fails when id-token: write exists only in a comment" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
  # id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

@test "accepts id-token: write with a trailing comment" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  id-token: write   # REQUIRED
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  lint_file "$FIXTURE"
}

# CommonMark permits up to three leading spaces on a fence; an indented block
# must be linted, not skipped or left open to swallow the rest of the file.
@test "lints an indented fenced block" {
  cat >"$FIXTURE" <<'EOF'
Some list context:

  ```yaml
  steps:
    - uses: prassoai/macroscope-actions/run@abc
  ```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

@test "an indented closing fence terminates the block" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
  ```

```yaml
permissions:
  checks: write
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  # The second block's violation is found, proving the first closed properly.
  [[ "$output" == *"'checks:' scope"* ]]
}

# GitHub renders every one of these info-string spellings as a copyable YAML
# block — leading whitespace, the yml alias, and any letter case — so each
# must be linted, not silently exempted from every check.
@test "lints space-before-info-string, yml, and uppercase fences" {
  for info in " yaml" "yml" "YAML" " Yml"; do
    cat >"$FIXTURE" <<EOF
\`\`\`${info}
steps:
  - uses: prassoai/macroscope-actions/run@abc
\`\`\`
EOF
    run lint_file "$FIXTURE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"id-token: write"* ]]
  done
}

# A yaml fence inside a blockquote renders as copyable too, but its content
# lines carry "> " prefixes this lint cannot see through — refused outright
# rather than silently skipped.
@test "refuses a blockquoted yaml fence rather than skipping it" {
  cat >"$FIXTURE" <<'EOF'
> ```yaml
> permissions:
>   checks: write
> ```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"blockquote"* ]]
}

# CommonMark also fences with tildes; a ~~~yaml block is just as copyable as a
# backtick one and must be linted, not skipped.
@test "lints a tilde-fenced block" {
  cat >"$FIXTURE" <<'EOF'
~~~yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
~~~
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# A fence closes only with its opening character: a ``` line inside a ~~~ block
# is content. Treating it as a close would truncate the block before its
# id-token: write line and produce a false violation.
@test "a backtick line inside a tilde block is content, not a close" {
  cat >"$FIXTURE" <<'EOF'
~~~yaml
permissions:
  id-token: write
```
steps:
  - uses: prassoai/macroscope-actions/run@abc
~~~
EOF
  lint_file "$FIXTURE"
}

# CommonMark fences are runs of THREE OR MORE characters; a ````yaml block is
# just as copyable as a ```yaml one and must be linted, not skipped.
@test "lints a four-backtick fenced block" {
  cat >"$FIXTURE" <<'EOF'
````yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
````
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# A closing fence must be AT LEAST as long as the opening run: a three-char
# line inside a four-char block is content. Closing early here would truncate
# the block before its grant and produce a false violation.
@test "a shorter run inside a longer fence is content, not a close" {
  cat >"$FIXTURE" <<'EOF'
````yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
permissions:
  id-token: write
````
EOF
  lint_file "$FIXTURE"
}

# A closing fence carries nothing but whitespace: a fence-like line with
# trailing text is content. Closing on it would truncate the block before its
# grant and produce a false violation.
@test "a fence line with trailing text is content, not a close" {
  cat >"$FIXTURE" <<'EOF'
```yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
``` not a close
permissions:
  id-token: write
```
EOF
  lint_file "$FIXTURE"
}

# CommonMark runs an unclosed fence to the end of the document — the block is
# real, copyable content and must be validated, not silently dropped at EOF.
@test "validates a block left open at EOF" {
  cat >"$FIXTURE" <<'EOF'
```yaml
steps:
  - uses: prassoai/macroscope-actions/run@abc
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# The grant must live inside the permissions: mapping. The same text under
# env: (or any other key) is not a permission — counting it would pass a block
# whose OIDC mint fails at runtime.
@test "id-token: write under env: does not satisfy the requirement" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
env:
  id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# Only OUTER-depth entries of an inline map grant: a nested flow map is a
# value, and counting its contents would pass a block whose copied workflow
# cannot mint an OIDC token.
@test "id-token: write nested inside an inline map value does not satisfy" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: { nested: { id-token: write } }
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# Quoted key spellings are valid YAML and grant exactly like unquoted ones,
# so the checks: ban must catch them.
@test "fails quoted checks keys" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  "checks": write
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  'checks': read
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
}

# A quoted blanket value is the same grant as an unquoted one.
@test "fails a quoted blanket permissions value" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: "write-all"
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"write-all"* ]]
}

@test "an inline permissions map grants id-token: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: { contents: read, id-token: write }
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  lint_file "$FIXTURE"
}

# The checks: ban covers GitHub's inline-map form too — a block-style-only
# match would fail open on valid syntax.
@test "fails an inline permissions map granting checks: write" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: { checks: write }
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"'checks:' scope"* ]]
}

# read-all is a blanket grant like write-all: it includes checks: read.
@test "fails a block granting permissions: read-all" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions: read-all
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-all"* ]]
}

# Only DIRECT entries of the permissions mapping grant: id-token: write nested
# deeper than the mapping's entry indentation is a value, not a permission,
# and must not satisfy the requirement.
@test "id-token: write nested below a permissions entry does not satisfy" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
  nested:
    id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# A comment line never seeds the mapping's entry indentation — YAML comments
# need no space after the # — or a deep "#comment" as the first line would fix
# entry depth at nested level and admit a nested grant as direct.
@test "a spaceless deep comment cannot make a nested grant count as direct" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
    #comment
  nested:
    id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
}

# A key at or above the mapping's indentation ends its scope: a grant-shaped
# line under a LATER sibling key is not a permission.
@test "the permissions scope ends at the next sibling key" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
with:
  id-token: write
steps:
  - uses: prassoai/macroscope-actions/run@abc
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
}

# A missing or unreadable file must fail the lint: the failed redirection
# skips the loop entirely, and returning rc=0 there would let CI pass having
# checked nothing.
@test "fails on a missing file" {
  run lint_file "${FIXTURE}.does-not-exist"
  [ "$status" -ne 0 ]
}

# The documented prohibition lives on a full-comment line, which grants
# nothing and must not trip the checks: ban.
@test "passes the commented no-checks-scope prohibition" {
  cat >"$FIXTURE" <<'EOF'
```yaml
permissions:
  contents: read
  id-token: write
  # no checks: scope — the job itself is the check run
```
EOF
  lint_file "$FIXTURE"
}

@test "ignores non-yaml fenced blocks and prose" {
  cat >"$FIXTURE" <<'EOF'
Prose mentioning macroscope-actions/run@abc without a block.

```bash
echo "macroscope-actions/run@abc"
```
EOF
  lint_file "$FIXTURE"
}

@test "reports every failing block, not just the first" {
  cat >"$FIXTURE" <<'EOF'
```yaml
- uses: prassoai/macroscope-actions/run@abc
```

```yaml
permissions:
  checks: write
```
EOF
  run lint_file "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-token: write"* ]]
  [[ "$output" == *"'checks:' scope"* ]]
}

# The shipped README must pass its own lint — the fixture-based tests prove
# the lint works; this proves the docs are currently clean.
@test "the shipped README passes" {
  lint_file "${BATS_TEST_DIRNAME}/../README.md"
}
