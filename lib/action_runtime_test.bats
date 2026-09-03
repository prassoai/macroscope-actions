#!/usr/bin/env bats
# Unit tests for lib/action_runtime.sh, the shared runtime for the composite
# actions. Each test's comment names the requirement it encodes.

setup() {
  # shellcheck disable=SC1091
  source "${BATS_TEST_DIRNAME}/action_runtime.sh"
  GITHUB_OUTPUT="$(mktemp)"
  export GITHUB_OUTPUT
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

# Requirement: a value containing "\n::error::…" cannot forge a workflow
# command — an output line begins at a newline, so CR/LF must be stripped from
# every scalar destined for $GITHUB_OUTPUT or a log line.
@test "strip_crlf removes newlines that could forge workflow commands" {
  run strip_crlf $'safe\n::error::forged'
  [ "$status" -eq 0 ]
  [ "$output" = "safe::error::forged" ]
}

@test "strip_crlf removes carriage returns" {
  run strip_crlf $'value\r\nwith\rcr'
  [ "$output" = "valuewithcr" ]
}

# Requirement: a multiline value round-trips through the random heredoc
# delimiter verbatim — including a value that contains a plausible delimiter
# line, which must not terminate the block early.
@test "emit_multiline round-trips a multiline value verbatim" {
  local value=$'line one\nghadelim_0000000000000000000000000000000\nline three'
  emit_multiline summary "$value"
  # The written block is name<<delim / value / delim. Reconstruct the value.
  local delim
  delim=$(head -1 "$GITHUB_OUTPUT" | sed 's/^summary<<//')
  [[ "$delim" == ghadelim_* ]]
  local got
  got=$(sed -n "2,\$p" "$GITHUB_OUTPUT" | sed "/^${delim}\$/,\$d")
  [ "$got" = "$value" ]
}

@test "emit_multiline uses a fresh random delimiter each call" {
  emit_multiline a "x"
  emit_multiline b "y"
  local d1 d2
  d1=$(grep -o 'a<<ghadelim_[0-9a-f]*' "$GITHUB_OUTPUT")
  d2=$(grep -o 'b<<ghadelim_[0-9a-f]*' "$GITHUB_OUTPUT")
  [ "${d1#a<<}" != "${d2#b<<}" ]
}

# The fail-on matrix, as documented in action.yml. "No verdict" conclusions
# (cancelled, timed_out, action_required, stale) fail under both gating
# policies — a gate that passes on "no verdict" is not a gate.
@test "decide_outcome failure policy passes success, neutral, skipped" {
  [ "$(decide_outcome failure success)" = "pass" ]
  [ "$(decide_outcome failure neutral)" = "pass" ]
  [ "$(decide_outcome failure skipped)" = "pass" ]
}

@test "decide_outcome failure policy fails failure and every no-verdict conclusion" {
  [ "$(decide_outcome failure failure)" = "fail" ]
  [ "$(decide_outcome failure cancelled)" = "fail" ]
  [ "$(decide_outcome failure timed_out)" = "fail" ]
  [ "$(decide_outcome failure action_required)" = "fail" ]
  [ "$(decide_outcome failure stale)" = "fail" ]
}

@test "decide_outcome neutral policy fails neutral" {
  [ "$(decide_outcome neutral success)" = "pass" ]
  [ "$(decide_outcome neutral skipped)" = "pass" ]
  [ "$(decide_outcome neutral neutral)" = "fail" ]
  [ "$(decide_outcome neutral failure)" = "fail" ]
}

@test "decide_outcome never policy never fails" {
  [ "$(decide_outcome never failure)" = "pass" ]
  [ "$(decide_outcome never cancelled)" = "pass" ]
}

@test "decide_outcome rejects an unknown policy loudly" {
  run decide_outcome sometimes success
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail-on must be"* ]]
}

# fail-on: never is a promise about the STEP, not just the verdict mapping: a
# wait that ends without a conclusion (timeout, or a rate-limit reset beyond
# the remaining budget) must succeed with a warning under never, and fail with
# an error under every other policy. Both no-conclusion exits route through
# unmet_exit.
@test "unmet_exit succeeds with a warning under never" {
  run unmet_exit never "no conclusion."
  [ "$status" -eq 0 ]
  [[ "$output" == "::warning::no conclusion."* ]]
}

@test "unmet_exit fails with an error under failure and neutral" {
  run unmet_exit failure "no conclusion."
  [ "$status" -eq 1 ]
  [[ "$output" == "::error::no conclusion." ]]
  run unmet_exit neutral "no conclusion."
  [ "$status" -eq 1 ]
}

# A workflow command begins at a newline, so a message containing one could
# otherwise emit a second ::warning::/::error:: — the message is CR/LF-
# stripped like every other scalar this library emits.
@test "unmet_exit flattens a message that tries to forge a second command" {
  run unmet_exit failure $'real problem\n::warning::forged'
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "::error::real problem::warning::forged" ]]
}

# The arithmetic sinks are self-validating: an injection-shaped value
# reaching them returns 1 and executes nothing, even if a future call site
# forgets validate_uint.
@test "budget_max_time rejects an injection-shaped deadline without executing it" {
  run budget_max_time 'x[$(touch /tmp/art_pwn_budget)]'
  [ "$status" -ne 0 ]
  [ ! -e /tmp/art_pwn_budget ]
}

@test "sleep_within_budget rejects injection-shaped deadline and interval" {
  IN_POLL_INTERVAL=1
  run sleep_within_budget 'x[$(touch /tmp/art_pwn_sleep)]'
  [ "$status" -ne 0 ]
  [ ! -e /tmp/art_pwn_sleep ]
  IN_POLL_INTERVAL='x[$(touch /tmp/art_pwn_interval)]'
  run sleep_within_budget "$SECONDS"
  [ "$status" -ne 0 ]
  [ ! -e /tmp/art_pwn_interval ]
}

# A failed randomness source must not degrade to the predictable "ghadelim_"
# delimiter, which a crafted value could name to terminate the heredoc early
# and forge further outputs; and the output NAME is part of the framing too.
@test "emit_multiline fails closed when openssl produces no randomness" {
  openssl() { return 1; }
  run emit_multiline summary "value"
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
  unset -f openssl
}

@test "emit_multiline rejects an output name outside the safe charset" {
  run emit_multiline $'bad
name' "value"
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

# Bash arithmetic evaluates variable CONTENTS recursively, so a
# caller-controlled timeout like "SECONDS[$(cmd)]" executes the command
# substitution inside $(( )). Only ASCII-digit strings may reach an arithmetic
# context; everything else is rejected loudly before the wait begins.
@test "validate_uint accepts plain digits" {
  validate_uint timeout "1200"
  validate_uint timeout "0"
}

@test "validate_uint rejects an arithmetic command injection" {
  run validate_uint timeout 'SECONDS[$(touch /tmp/await_pwned)]'
  [ "$status" -ne 0 ]
  [ ! -e /tmp/await_pwned ]
  [[ "$output" == *"non-negative integer"* ]]
}

@test "validate_uint rejects empty, negative, float, and spaced values" {
  run validate_uint timeout "";      [ "$status" -ne 0 ]
  run validate_uint timeout "-5";    [ "$status" -ne 0 ]
  run validate_uint timeout "1.5";   [ "$status" -ne 0 ]
  run validate_uint timeout "10 10"; [ "$status" -ne 0 ]
}

# A leading zero makes bash arithmetic parse the value as octal (010 means 8;
# 08/09 abort as invalid), and a value past the 64-bit range overflows to a
# negative deadline. Both are rejected loudly rather than silently misread.
@test "validate_uint rejects leading zeros, naming octal" {
  run validate_uint timeout "010"
  [ "$status" -ne 0 ]
  [[ "$output" == *"octal"* ]]
  run validate_uint timeout "08"
  [ "$status" -ne 0 ]
}

@test "validate_uint accepts a bare zero" {
  validate_uint timeout "0"
}

@test "validate_uint rejects values over nine digits" {
  run validate_uint timeout "9999999999999999999"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too large"* ]]
  validate_uint timeout "999999999"
}

# Every poll sleep is clamped to the remaining budget: a poll-interval larger
# than what is left (timeout=10, poll-interval=60) must not carry the step past
# its advertised timeout.
@test "min_uint returns the smaller value" {
  [ "$(min_uint 15 4)" = "4" ]
  [ "$(min_uint 4 15)" = "4" ]
  [ "$(min_uint 7 7)" = "7" ]
}

@test "sleep_within_budget returns immediately when the budget is spent" {
  IN_POLL_INTERVAL=60
  local before=$SECONDS
  sleep_within_budget "$SECONDS"       # deadline == now: nothing left
  sleep_within_budget $((SECONDS - 5)) # deadline in the past
  [ $((SECONDS - before)) -le 1 ]
}

@test "sleep_within_budget clamps the interval to the remaining budget" {
  IN_POLL_INTERVAL=60
  local before=$SECONDS
  sleep_within_budget $((SECONDS + 1)) # 1s left, 60s interval: sleep ~1s
  [ $((SECONDS - before)) -le 3 ]
}

@test "validate_uint strips CR/LF from the value it echoes in its error" {
  run validate_uint timeout $'x\n::error::forged'
  [ "$status" -ne 0 ]
  [[ "$output" != *$'\n::error::forged'* ]]
}
