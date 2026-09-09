#!/usr/bin/env bash
# action_runtime.sh — the shared runtime for macroscope-actions composite
# actions: output sanitization against workflow-command forgery, arithmetic
# input validation, wait-budget arithmetic, and fail-on verdict gating. The
# HTTP layer is NOT here: each action's transport is written against the API
# contract it actually speaks, and only transport-independent machinery is
# shared.
#
# Source-only: action scripts source this file, and bats sources it to
# unit-test the functions directly. It sets no shell options — the sourcing
# script owns its own `set` line.
#
# Environment expectations (mapped by the sourcing action's env: block):
#   IN_POLL_INTERVAL  seconds between polls (sleep_within_budget)
#   GITHUB_OUTPUT     step-output file (emit_multiline)

# strip_crlf removes CR/LF from a scalar destined for $GITHUB_OUTPUT or a log
# line. A workflow command (::error::…) or an output assignment begins at a
# newline, so an untrusted value containing "\n::error::…" could otherwise
# forge one. Multiline values never go through here — they use emit_multiline.
strip_crlf() {
  local s=$1
  s=${s//$'\n'/}
  printf '%s' "${s//$'\r'/}"
}

# emit_scalar writes one CR/LF-stripped scalar output. Output names are held to
# the same safe character set as emit_multiline because the name is part of
# $GITHUB_OUTPUT's assignment framing.
emit_scalar() {
  local name=$1 value=$2
  case "$name" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s=%s\n' "$name" "$(strip_crlf "$value")" >>"$GITHUB_OUTPUT"
}

# emit_multiline writes a multiline output value with a random heredoc
# delimiter, so a value that happens to contain a fixed delimiter (or tries to
# guess one) cannot terminate the block early and forge further outputs.
emit_multiline() {
  local name=$1 value=$2 delim
  # The output name and the delimiter are load-bearing for $GITHUB_OUTPUT's
  # heredoc framing: a name outside this charset could forge entries itself,
  # and a failed randomness source (absent or broken openssl — self-hosted
  # runners exist) would yield the short, PREDICTABLE delimiter "ghadelim_",
  # letting a crafted value terminate the block early and forge further
  # outputs. Both are asserted rather than trusted.
  case "$name" in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  delim="ghadelim_$(openssl rand -hex 16)" || return 1
  [ "${#delim}" -eq 41 ] || return 1
  {
    echo "${name}<<${delim}"
    printf '%s\n' "$value"
    echo "$delim"
  } >>"$GITHUB_OUTPUT"
}

# validate_uint guards a value bound for bash arithmetic, admitting only the
# canonical base-10 form. Three hazards, each with its own rejection:
#   * Inside $(( )) bash recursively evaluates variable CONTENTS, so a value
#     like "SECONDS[\$(cmd)]" executes the command substitution — env-mapping
#     the input does not help, because the injection happens at arithmetic
#     evaluation, not interpolation. Only ASCII digits pass.
#   * A leading zero makes bash parse the value as OCTAL: 010 means 8, and
#     08/09 abort the whole action as invalid arithmetic. Rejected loudly
#     rather than silently reinterpreted — a caller who wrote 010 meant 10.
#   * A value past bash's 64-bit range overflows silently: the deadline wraps
#     negative and the action fails after its first request. Nine digits
#     (≈31 years of seconds) is the cap; nothing legitimate is larger.
validate_uint() {
  local name=$1 value=$2
  case "$value" in
    '' | *[!0-9]*)
      echo "::error::${name} must be a non-negative integer (got \"$(strip_crlf "$value")\")" >&2
      return 1
      ;;
  esac
  case "$value" in
    0) ;;
    0*)
      echo "::error::${name} must not have a leading zero — bash would read \"$(strip_crlf "$value")\" as octal" >&2
      return 1
      ;;
  esac
  if [ "${#value}" -gt 9 ]; then
    echo "::error::${name} is too large (max 9 digits): \"$(strip_crlf "$value")\"" >&2
    return 1
  fi
}

# budget_max_time prints the per-request transfer bound recomputed from the
# live deadline (remaining seconds, capped at 30), failing when the budget is
# spent so a caller can stop before issuing the request. Recomputed per call
# because every request and sleep between calls consumes budget.
budget_max_time() {
  local deadline=$1
  # Self-validating sink: bash arithmetic evaluates variable CONTENTS
  # recursively, so a non-canonical value reaching $(( )) is command
  # execution. Re-checked here rather than trusting every future call site to
  # have routed the value through validate_uint. One leading minus is legal —
  # a deadline already in the past is a valid budget-spent state.
  case "${deadline#-}" in '' | *[!0-9]*) return 1 ;; esac
  local r=$((deadline - SECONDS))
  [ "$r" -gt 0 ] || return 1
  echo $((r < 30 ? r : 30))
}

# min_uint prints the smaller of two validated unsigned integers. Used to clamp
# every poll sleep to the remaining budget, so a poll-interval larger than what
# is left cannot carry the step past its advertised timeout.
min_uint() {
  if [ "$1" -le "$2" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# sleep_within_budget sleeps the poll interval clamped to what remains before
# deadline, recomputed at call time — the request that preceded the sleep
# consumed budget too. With nothing left it returns immediately, and the loop's
# top-of-iteration deadline check emits the timeout. Without the clamp a
# poll-interval larger than the remaining budget (timeout=10, poll-interval=60)
# would overshoot the advertised timeout by most of a minute.
sleep_within_budget() {
  local deadline=$1
  # Self-validating sink, exactly as in budget_max_time — including the poll
  # interval, which reaches both $(( )) (via min_uint's callers) and sleep.
  case "${deadline#-}" in '' | *[!0-9]*) return 1 ;; esac
  case "${IN_POLL_INTERVAL:-}" in '' | *[!0-9]*) return 1 ;; esac
  local rem=$((deadline - SECONDS))
  [ "$rem" -gt 0 ] || return 0
  sleep "$(min_uint "$IN_POLL_INTERVAL" "$rem")"
}

# decide_outcome maps (fail-on policy, conclusion) to "pass" or "fail".
#   never:   never fail
#   failure: fail unless the conclusion is success, neutral, or skipped
#   neutral: fail unless the conclusion is success or skipped
# Everything not explicitly passing fails: cancelled, timed_out,
# action_required, and stale are failures under both gating policies, because
# a gate that treats "the check did not produce a verdict" as passing is not a
# gate.
decide_outcome() {
  local fail_on=$1 conclusion=$2
  case "$fail_on" in
    never) echo pass ;;
    failure)
      case "$conclusion" in
        success | neutral | skipped) echo pass ;;
        *) echo fail ;;
      esac
      ;;
    neutral)
      case "$conclusion" in
        success | skipped) echo pass ;;
        *) echo fail ;;
      esac
      ;;
    *)
      echo "::error::fail-on must be failure, neutral, or never (got \"$(strip_crlf "$fail_on")\")" >&2
      return 1
      ;;
  esac
}

# unmet_exit ends a wait that produced no conclusion — the timeout elapsed, or
# a rate-limit reset lies beyond the remaining budget (the same outcome,
# declared early). fail-on governs these exits like any other outcome: "never"
# promises the step never fails on the check's outcome or absence, so the
# report is a warning and the exit is clean; every other policy reports an
# error and fails. Misconfiguration — invalid inputs, permission errors — is
# not routed here and always fails. The conclusion outputs stay unwritten on
# this path either way, so an if: always() consumer can tell "no conclusion"
# from a real one.
unmet_exit() {
  local fail_on=$1 message=$2
  # The message is emitted after a workflow-command prefix, and a workflow
  # command begins at a newline — so the message is CR/LF-stripped like every
  # other scalar, or a message containing a newline could forge a second
  # command.
  message=$(strip_crlf "$message")
  if [ "$fail_on" = "never" ]; then
    echo "::warning::${message} The step succeeds because fail-on is never." >&2
    exit 0
  fi
  echo "::error::${message}" >&2
  exit 1
}
