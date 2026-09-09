#!/usr/bin/env bats

setup() {
  # shellcheck disable=SC1091
  source "${BATS_TEST_DIRNAME}/run.sh"
  eval "$(declare -f mock_action_http_request | sed '1s/mock_action_http_request/action_http_request/')"
  GITHUB_OUTPUT="$(mktemp)"
  MOCK_CALLS="$(mktemp)"
  MOCK_INDEX_FILE="$(mktemp)"
  export GITHUB_OUTPUT MOCK_CALLS MOCK_INDEX_FILE
  IN_API_URL=https://hooks.example.test
  IN_REPOSITORY=prassoai/woofiors
  IN_AGENT="Release Audit"
  IN_COMMIT=0123456789abcdef0123456789abcdef01234567
  IN_BASE=abcdef0123456789abcdef0123456789abcdef01
  IN_PULL_REQUEST=
  IN_FAIL_ON=failure
  IN_TIMEOUT=60
  IN_POLL_INTERVAL=5
  IN_ACTION_VERSION=v1
  IN_ADDITIONAL_INSTRUCTIONS=
  GITHUB_ACTION=macroscope
  ACTIONS_ID_TOKEN_REQUEST_URL=https://token.actions.githubusercontent.com/request
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token
  MOCK_STATUS=()
  MOCK_BODY=()
  MOCK_HEADERS=()
  MOCK_EXIT=()
  MOCK_ADVANCE=()
  printf '0' >"$MOCK_INDEX_FILE"
}

teardown() {
  rm -f "$GITHUB_OUTPUT" "$MOCK_CALLS" "$MOCK_INDEX_FILE"
}

enqueue_response() {
  MOCK_STATUS+=("$1")
  MOCK_BODY+=("$2")
  MOCK_HEADERS+=("${3:-}")
  MOCK_EXIT+=("${4:-0}")
  MOCK_ADVANCE+=("${5:-0}")
}

mock_action_http_request() {
  local method=$1 url=$2 body=$3 output=$4 headers=$5 config=$6 index
  index=$(cat "$MOCK_INDEX_FILE")
  printf '%s' "$((index + 1))" >"$MOCK_INDEX_FILE"
  {
    printf '%s %s\n' "$method" "$url"
    sed 's/Bearer .*/Bearer <redacted>"/' "$config"
    [ -n "$body" ] && cat "$body"
    printf '\n---\n'
  } >>"$MOCK_CALLS"
  printf '%s' "${MOCK_BODY[$index]}" >"$output"
  printf '%s' "${MOCK_HEADERS[$index]}" >"$headers"
  HTTP_STATUS=${MOCK_STATUS[$index]}
  SECONDS=$((SECONDS + MOCK_ADVANCE[index]))
  return "${MOCK_EXIT[$index]}"
}

jwt() {
  printf 'aaa.bbb.ccc'
}

run_id() {
  printf '123e4567-e89b-12d3-a456-426614174000'
}

oidc_body() {
  printf '{"value":"%s"}' "$(jwt)"
}

start_body() {
  printf '{"runId":"%s","jobToken":"%s"}' "$(run_id)" "$(jwt)"
}

running_body() {
  printf '{"status":"running","rawCostCentimills":0}'
}

success_body() {
  printf '{"status":"succeeded","verdict":"success","summary":"Clean\\nship it","findingsReference":"[]","rawCostCentimills":123456}'
}

failure_body() {
  printf '{"status":"succeeded","verdict":"failure","summary":"Found issues","findingsReference":"artifact://findings","rawCostCentimills":200000}'
}

# Requirement: a successful terminal run emits every public output after a
# lease-renewing poll.
@test "terminal success emits run ID verdict summary and cost without findings" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 202 "$(running_body)" $'Retry-After: 0\r\n'
  enqueue_response 200 "$(success_body)"

  run run_action

  [ "$status" -eq 0 ]
  grep -q '^run-id=123e4567-e89b-12d3-a456-426614174000$' "$GITHUB_OUTPUT"
  grep -q '^verdict=success$' "$GITHUB_OUTPUT"
  grep -q '^cost-usd=1.23456$' "$GITHUB_OUTPUT"
  grep -q 'summary<<ghadelim_' "$GITHUB_OUTPUT"
  ! grep -q '^findings' "$GITHUB_OUTPUT"
}

@test "internal findings reference is ignored regardless of presence or type" {
  for body in \
    '{"status":"succeeded","verdict":"success","rawCostCentimills":0}' \
    '{"status":"succeeded","verdict":"success","rawCostCentimills":0,"findingsReference":null}' \
    '{"status":"succeeded","verdict":"success","rawCostCentimills":0,"findingsReference":{"internal":true}}'; do
    printf '%s' "$body" > "$MOCK_CALLS"
    run valid_poll_response "$MOCK_CALLS"
    [ "$status" -eq 0 ]
    run emit_terminal_outputs "$MOCK_CALLS"
    [ "$status" -eq 0 ]
    ! grep -q '^findings' "$GITHUB_OUTPUT"
  done
}

# Requirement: Macroscope start and poll requests identify the action client
# version, while the GitHub OIDC request does not send Macroscope-only headers.
@test "macroscope requests include action version header" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 "$(success_body)"

  run run_action

  [ "$status" -eq 0 ]
  [ "$(grep -c 'X-Macroscope-Action-Version: v1' "$MOCK_CALLS")" -eq 2 ]
  awk '/^GET https:\/\/token.actions.githubusercontent.com/ { oidc=1 } /^---$/ { oidc=0 } oidc && /X-Macroscope-Action-Version/ { found=1 } END { exit found }' "$MOCK_CALLS"
}

# Requirement: optional request fields are sent only when present, while
# additional-instructions is preserved verbatim inside JSON.
@test "start request preserves PR metadata fields without base" {
  IN_BASE=
  IN_PULL_REQUEST=42
  IN_ADDITIONAL_INSTRUCTIONS=$'Focus on migrations.\nIgnore generated files.'
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 "$(success_body)"

  run run_action

  [ "$status" -eq 0 ]
  grep '"repository"' "$MOCK_CALLS" | jq -e 'select((has("base") | not) and .pullRequest == 42 and .additionalInstructions == "Focus on migrations.\nIgnore generated files.")' >/dev/null
}

# Requirement: a terminal failure writes result outputs before fail-on turns
# the step red, so downstream always() consumers can inspect the result.
@test "terminal failure emits outputs before failing" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 "$(failure_body)"

  run run_action

  [ "$status" -eq 1 ]
  grep -q '^run-id=123e4567-e89b-12d3-a456-426614174000$' "$GITHUB_OUTPUT"
  grep -q '^verdict=failure$' "$GITHUB_OUTPUT"
  grep -q '^cost-usd=2.00000$' "$GITHUB_OUTPUT"
}

# Requirement: fail-on never makes a terminal failed verdict observable without
# failing the workflow step.
@test "fail-on never tolerates terminal failure" {
  IN_FAIL_ON=never
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 "$(failure_body)"

  run run_action

  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::"* ]]
}

# Requirement: a client timeout after start keeps the run ID output but writes
# no terminal result outputs.
@test "poll timeout keeps run ID and no verdict" {
  IN_TIMEOUT=1
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 202 "$(running_body)" "" 0 1

  run run_action

  [ "$status" -eq 1 ]
  grep -q '^run-id=' "$GITHUB_OUTPUT"
  ! grep -q '^verdict=' "$GITHUB_OUTPUT"
}

# Requirement: a timeout while minting OIDC is terminal even under fail-on
# never; command substitution must not turn that timeout into an empty token
# and continue to the start request.
@test "oidc timeout under fail-on never does not post start" {
  IN_TIMEOUT=1
  IN_FAIL_ON=never
  enqueue_response 000 "" "" 124

  run run_action

  [ "$status" -eq 0 ]
  grep -q '^GET https://token.actions.githubusercontent.com/request?audience=macroscope$' "$MOCK_CALLS"
  [ "$(grep -c '^POST ' "$MOCK_CALLS")" -eq 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

# Requirement: polling retries transient transport, 503, and rate-limited 403
# responses because polling is the server-side lease renewal.
@test "polling retries transport server and rate-limit errors" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 000 "" "" 75
  enqueue_response 503 '{"error":"busy"}' $'retry-after: 0\r\n'
  enqueue_response 403 '{"error":"rate limited"}' $'x-ratelimit-remaining: 0\r\nretry-after: 0\r\n'
  enqueue_response 200 "$(success_body)"

  run run_action

  [ "$status" -eq 0 ]
  [ "$(grep -c "GET https://hooks.example.test/api/v1/github-actions/agent-runs/$(run_id)" "$MOCK_CALLS")" -eq 4 ]
}

# Requirement: a non-rate-limit polling permission error fails immediately
# rather than burning the lease budget.
@test "polling permission error does not retry" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 403 '{"error":"denied"}'

  run run_action

  [ "$status" -eq 1 ]
  [ "$(grep -c "GET https://hooks.example.test/api/v1/github-actions/agent-runs/$(run_id)" "$MOCK_CALLS")" -eq 1 ]
}

# Requirement: malformed OIDC responses fail before any Macroscope request.
@test "malformed oidc response fails closed" {
  enqueue_response 200 '{"value":"not-a-jwt"}'

  run run_action

  [ "$status" -eq 1 ]
  [ "$(grep -c '^POST ' "$MOCK_CALLS")" -eq 0 ]
}

# Requirement: malformed start responses fail before polling, so an attacker
# cannot smuggle an arbitrary path segment into the poll URL.
@test "malformed start run id cannot reach poll URL" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 '{"runId":"../../x","jobToken":"aaa.bbb.ccc"}'

  run run_action

  [ "$status" -eq 1 ]
  [ "$(grep -c '^GET https://hooks.example.test/api/v1/github-actions/agent-runs/' "$MOCK_CALLS")" -eq 0 ]
}

# Requirement: malformed poll responses fail rather than emitting ambiguous
# outputs or applying fail-on to incomplete data.
@test "malformed poll response fails closed" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 '{"status":"succeeded","verdict":"success"}'

  run run_action

  [ "$status" -eq 1 ]
  ! grep -q '^verdict=' "$GITHUB_OUTPUT"
}

# Requirement: a succeeded terminal response with an unknown verdict is
# malformed, and malformed terminal responses must not publish outputs.
@test "invalid succeeded verdict emits no terminal outputs" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 '{"status":"succeeded","verdict":"bogus","summary":"bad","findingsReference":"[]","rawCostCentimills":1}'

  run run_action

  [ "$status" -eq 1 ]
  grep -q '^run-id=' "$GITHUB_OUTPUT"
  ! grep -q '^verdict=' "$GITHUB_OUTPUT"
  ! grep -q '^cost-usd=' "$GITHUB_OUTPUT"
}

# Requirement: cost conversion failures are detected before any terminal
# output is written, so consumers never see a partial terminal result.
@test "oversized terminal cost emits no terminal outputs" {
  enqueue_response 200 "$(oidc_body)"
  enqueue_response 202 "$(start_body)"
  enqueue_response 200 '{"status":"succeeded","verdict":"success","summary":"ok","findingsReference":"[]","rawCostCentimills":1000000000}'

  run run_action

  [ "$status" -eq 1 ]
  grep -q '^run-id=' "$GITHUB_OUTPUT"
  ! grep -q '^verdict=' "$GITHUB_OUTPUT"
  ! grep -q '^cost-usd=' "$GITHUB_OUTPUT"
}

# Requirement: oversized additional-instructions is rejected locally before
# minting OIDC or creating a durable run.
@test "oversized additional instructions fail before requests" {
  IN_ADDITIONAL_INSTRUCTIONS="$(printf '%*s' 16385 x)"

  run run_action

  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_CALLS" ]
}

# Requirement: missing id-token permission fails with the specific missing
# scope and never reaches Macroscope.
@test "missing oidc permission fails before start" {
  unset ACTIONS_ID_TOKEN_REQUEST_URL

  run run_action

  [ "$status" -eq 1 ]
  [[ "$output" == *"id-token: write"* ]]
  [ ! -s "$MOCK_CALLS" ]
}

# Requirement: the action never sends GitHub OIDC or job capabilities over
# plaintext HTTP.
@test "plaintext api url is rejected" {
  IN_API_URL=http://hooks.example.test

  run run_action

  [ "$status" -eq 1 ]
  [ ! -s "$MOCK_CALLS" ]
}
