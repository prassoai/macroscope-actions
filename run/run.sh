#!/usr/bin/env bash

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=macroscope-actions/lib/action_runtime.sh
source "${SCRIPT_DIR}/../lib/action_runtime.sh"

action_error() {
  echo "::error::$(strip_crlf "$1")" >&2
}

require_action_command() {
  command -v "$1" >/dev/null 2>&1 || { action_error "$1 is required"; return 1; }
}

json_string() {
  printf '%s' "$1" | jq -Rs .
}

json_member() {
  printf '"%s":%s' "$1" "$2"
}

optional_string_member() {
  [ -n "$2" ] || return 0
  json_member "$1" "$(json_string "$2")"
}

optional_uint_member() {
  [ -n "$2" ] || return 0
  json_member "$1" "$2"
}

join_json_members() {
  local first=1 member
  printf '{'
  for member in "$@"; do
    [ -n "$member" ] || continue
    if [ "$first" -eq 1 ]; then first=0; else printf ','; fi
    printf '%s' "$member"
  done
  printf '}'
}

start_payload() {
  join_json_members \
    "$(json_member repository "$(json_string "$IN_REPOSITORY")")" \
    "$(json_member agent "$(json_string "$IN_AGENT")")" \
    "$(json_member commit "$(json_string "$IN_COMMIT")")" \
    "$(optional_string_member base "${IN_BASE:-}")" \
    "$(optional_uint_member pullRequest "${IN_PULL_REQUEST:-}")" \
    "$(optional_string_member additionalInstructions "${IN_ADDITIONAL_INSTRUCTIONS:-}")" \
    "$(optional_string_member idempotencyDiscriminator "${GITHUB_ACTION:-}")"
}

url_join() {
  printf '%s/%s' "${1%/}" "${2#/}"
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

valid_jwt() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]
}

write_auth_config() {
  local path=$1 token=$2 version=${3:-}
  umask 077
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token"
    printf 'header = "Accept: application/json"\n'
    [ -z "$version" ] || printf 'header = "X-Macroscope-Action-Version: %s"\n' "$version"
  } >"$path"
}

write_json_auth_config() {
  write_auth_config "$1" "$2" "${3:-}"
  printf 'header = "Content-Type: application/json"\n' >>"$1"
}

action_http_request() {
  local method=$1 url=$2 body=$3 output=$4 headers=$5 config=$6 deadline=$7 max_time
  max_time=$(budget_max_time "$deadline") || return 124
  if [ -n "$body" ]; then
    HTTP_STATUS=$(curl --silent --show-error --output "$output" --dump-header "$headers" --write-out '%{http_code}' --max-time "$max_time" --request "$method" --config "$config" --data-binary "@$body" "$url") || return 75
  else
    HTTP_STATUS=$(curl --silent --show-error --output "$output" --dump-header "$headers" --write-out '%{http_code}' --max-time "$max_time" --request "$method" --config "$config" "$url") || return 75
  fi
  [[ "$HTTP_STATUS" =~ ^[0-9][0-9][0-9]$ ]] || return 76
}

api_error_message() {
  local body=$1 fallback=$2 reason detail
  reason=$(jq -r '.reason // empty' "$body" 2>/dev/null || true)
  detail=$(jq -r '.error // .message // empty' "$body" 2>/dev/null || true)
  if [ -n "$reason" ] && [ -n "$detail" ]; then
    printf '%s: %s' "$reason" "$detail"
  elif [ -n "$detail" ]; then
    printf '%s' "$detail"
  else
    printf '%s' "$fallback"
  fi
}

retry_after() {
  awk '{ line=$0; sub(/\r$/, "", line); name=line; sub(/:.*/, "", name); if (tolower(name) == "retry-after") { sub(/^[^:]*:[[:space:]]*/, "", line); print line; exit } }' "$1"
}

rate_limited() {
  awk '{ line=$0; sub(/\r$/, "", line); name=line; sub(/:.*/, "", name); if (tolower(name) == "x-ratelimit-remaining") { sub(/^[^:]*:[[:space:]]*/, "", line); if (line == "0") found=1 } } END{exit !found}' "$1"
}

sleep_for_retry() {
  local headers=$1 deadline=$2 delay
  delay=$(retry_after "$headers")
  if [ -n "$delay" ]; then
    validate_uint Retry-After "$delay" || return 1
    [ "$delay" -le $((deadline - SECONDS)) ] || return 124
    sleep "$delay"
    return 0
  fi
  sleep_within_budget "$deadline"
}

request_or_retry() {
  local method=$1 url=$2 body=$3 output=$4 headers=$5 config=$6 deadline=$7
  while :; do
    if action_http_request "$method" "$url" "$body" "$output" "$headers" "$config" "$deadline"; then
      case "$HTTP_STATUS" in
        429 | 5??) sleep_for_retry "$headers" "$deadline" || return $? ;;
        403) if rate_limited "$headers"; then sleep_for_retry "$headers" "$deadline" || return $?; else return 0; fi ;;
        *) return 0 ;;
      esac
    else
      case $? in
        124) return 124 ;;
        75) sleep_for_retry /dev/null "$deadline" || return $? ;;
        *) action_error "Malformed HTTP status from Macroscope"; return 1 ;;
      esac
    fi
  done
}

mint_oidc_token() {
  local output=$1 headers=$2 config=$3 deadline=$4 separator='?'
  if [ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || [ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    action_error "id-token: write permission is required to mint GitHub OIDC"
    return 1
  fi
  case "$ACTIONS_ID_TOKEN_REQUEST_URL" in *\?*) separator='&' ;; esac
  write_auth_config "$config" "$ACTIONS_ID_TOKEN_REQUEST_TOKEN"
  request_or_retry GET "${ACTIONS_ID_TOKEN_REQUEST_URL}${separator}audience=macroscope" "" "$output" "$headers" "$config" "$deadline" || return $?
  [ "$HTTP_STATUS" = 200 ] || { action_error "$(api_error_message "$output" "GitHub OIDC token request failed")"; return 1; }
  jq -e 'type == "object" and (.value | type == "string")' "$output" >/dev/null || { action_error "GitHub OIDC returned a malformed response"; return 1; }
  local token
  token=$(jq -r '.value' "$output")
  valid_jwt "$token" || { action_error "GitHub OIDC returned a malformed token"; return 1; }
  printf '%s' "$token"
}

valid_start_response() {
  jq -e 'type == "object" and (.runId | type == "string") and (.jobToken | type == "string")' "$1" >/dev/null || return 1
  valid_uuid "$(jq -r '.runId' "$1")" && valid_jwt "$(jq -r '.jobToken' "$1")"
}

start_run() {
  local oidc=$1 payload=$2 output=$3 headers=$4 config=$5 deadline=$6
  printf '%s' "$payload" >"${output}.request"
  write_json_auth_config "$config" "$oidc" "$IN_ACTION_VERSION"
  request_or_retry POST "$(url_join "$IN_API_URL" "/api/v1/github-actions/agent-runs")" "${output}.request" "$output" "$headers" "$config" "$deadline" || return $?
  [ "$HTTP_STATUS" = 202 ] || { action_error "$(api_error_message "$output" "Macroscope start returned HTTP ${HTTP_STATUS}")"; return 1; }
  valid_start_response "$output" || { action_error "Macroscope start returned a malformed response"; return 1; }
}

valid_poll_response() {
  jq -e '
    type == "object"
    and (.status | type == "string")
    and ((.reason | type == "string") or (.reason == null))
    and ((.verdict | type == "string") or (.verdict == null))
    and ((.summary | type == "string") or (.summary == null))
    and ((has("agentCredits") | not) or (.agentCredits | type == "string" and test("^(0|[1-9][0-9]*)\\.[0-9]{3}$")))
    and ((.status != "succeeded") or (.verdict == "success" or .verdict == "neutral" or .verdict == "failure"))
  ' "$1" >/dev/null
}

poll_run() {
  local run_id=$1 token=$2 output=$3 headers=$4 config=$5 deadline=$6
  write_auth_config "$config" "$token" "$IN_ACTION_VERSION"
  while :; do
    request_or_retry GET "$(url_join "$IN_API_URL" "/api/v1/github-actions/agent-runs/${run_id}")" "" "$output" "$headers" "$config" "$deadline" || return $?
    case "$HTTP_STATUS" in
      202)
        valid_poll_response "$output" || { action_error "Macroscope poll returned a malformed response"; return 1; }
        case "$(jq -r '.status' "$output")" in pending | running) sleep_for_retry "$headers" "$deadline" || return $? ;; *) action_error "Macroscope poll returned HTTP 202 with a terminal status"; return 1 ;; esac
        ;;
      200)
        valid_poll_response "$output" || { action_error "Macroscope poll returned a malformed response"; return 1; }
        case "$(jq -r '.status' "$output")" in succeeded | failed | cancelled) return 0 ;; *) action_error "Macroscope poll returned HTTP 200 with a nonterminal status"; return 1 ;; esac
        ;;
      *) action_error "$(api_error_message "$output" "Macroscope poll returned HTTP ${HTTP_STATUS}")"; return 1 ;;
    esac
  done
}

emit_terminal_outputs() {
  local body=$1
  emit_scalar verdict "$(jq -r '.verdict // ""' "$body")" || return 1
  emit_multiline summary "$(jq -r '.summary // ""' "$body")" || return 1
  publish_terminal_result "$body" "$2"
}

publish_terminal_result() {
  local body=$1 run_id=$2 directory
  directory=$(mktemp -d "${RUNNER_TEMP}/macroscope-result-${run_id}-XXXXXX") || return 1
  jq --arg runId "$run_id" '{
    schemaVersion: 1,
    runId: $runId,
    status,
    reason: (.reason // null),
    verdict: (.verdict // null),
    summary: (.summary // null)
  } + (if has("agentCredits") then {agentCredits} else {} end)' "$body" >"$directory/result.json" || return 1
  emit_multiline result-path "$directory/result.json" || return 1
  emit_scalar result-artifact-name "${directory##*/}" || return 1
  jq -r '
    "\n## Macroscope result\n",
    "- Agent verdict: \((.verdict // "unavailable") | @html)",
    "- Run status: \(.status)",
    (if has("agentCredits") then "- Agent Credits: \(.agentCredits | if . == "0.000" then "Not billed" else . end)" else empty end),
    "- Run ID: \(.runId)\n",
    "### Summary\n",
    "<pre>\((.summary // "No agent summary returned.") | @html)</pre>",
    (if .reason == null then empty else "\n### Reason\n\n<pre>\(.reason | @html)</pre>" end)
  ' "$directory/result.json" >>"$GITHUB_STEP_SUMMARY"
}

conclude_run() {
  local body=$1 status verdict conclusion reason
  status=$(jq -r '.status' "$body")
  verdict=$(jq -r '.verdict // ""' "$body")
  reason=$(jq -r '.reason // ""' "$body")
  if [ "$status" = succeeded ]; then
    case "$verdict" in success | neutral | failure) conclusion=$verdict ;; *) action_error "Macroscope succeeded without a valid verdict"; return 1 ;; esac
  else
    conclusion=failure
  fi
  if [ "$(decide_outcome "$IN_FAIL_ON" "$conclusion")" = fail ]; then
    action_error "${reason:-Macroscope agent concluded ${conclusion}}"
    return 1
  fi
  [ "$conclusion" = success ] || echo "::warning::$(strip_crlf "${reason:-Macroscope agent concluded ${conclusion}}")" >&2
}

validate_run_inputs() {
  local command
  for command in curl jq openssl; do require_action_command "$command" || return 1; done
  [ -n "${RUNNER_TEMP:-}" ] || { action_error "RUNNER_TEMP is required"; return 1; }
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || { action_error "GITHUB_STEP_SUMMARY is required"; return 1; }
  [ -n "${GITHUB_OUTPUT:-}" ] || { action_error "GITHUB_OUTPUT is required"; return 1; }
  [ -n "${IN_API_URL:-}" ] || { action_error "api-url is required"; return 1; }
  case "$IN_API_URL" in https://*) ;; *) action_error "api-url must use HTTPS"; return 1 ;; esac
  [ -n "${IN_REPOSITORY:-}" ] || { action_error "repository is required"; return 1; }
  [ -n "${IN_AGENT:-}" ] || { action_error "agent is required"; return 1; }
  [ -n "${IN_COMMIT:-}" ] || { action_error "commit is required"; return 1; }
  validate_uint timeout "${IN_TIMEOUT:-}" || return 1
  [ "$IN_TIMEOUT" -gt 0 ] || { action_error "timeout must be greater than zero"; return 1; }
  validate_uint poll-interval "${IN_POLL_INTERVAL:-}" || return 1
  case "${IN_ACTION_VERSION:-}" in '' | *[!A-Za-z0-9._-]*) action_error "action version is invalid"; return 1 ;; esac
  decide_outcome "${IN_FAIL_ON:-}" success >/dev/null || return 1
  if [ -n "${IN_PULL_REQUEST:-}" ]; then
    validate_uint pull-request "$IN_PULL_REQUEST" || return 1
    [ "$IN_PULL_REQUEST" -gt 0 ] || { action_error "pull-request must be greater than zero"; return 1; }
  fi
  [ "$(LC_ALL=C printf '%s' "${IN_ADDITIONAL_INSTRUCTIONS:-}" | wc -c)" -le 16384 ] || { action_error "additional-instructions exceeds 16 KiB"; return 1; }
}

run_action() {
  validate_run_inputs || return 1
  local deadline=$((SECONDS + IN_TIMEOUT)) oidc payload run_id token
  RUN_ACTION_TMP=$(mktemp -d)
  trap 'rm -rf "$RUN_ACTION_TMP"' EXIT
  if oidc=$(mint_oidc_token "$RUN_ACTION_TMP/oidc.json" "$RUN_ACTION_TMP/oidc.headers" "$RUN_ACTION_TMP/oidc.config" "$deadline"); then
    :
  else
    case $? in 124) unmet_exit "$IN_FAIL_ON" "Timed out while waiting for the Macroscope agent run." ;; *) return 1 ;; esac
  fi
  payload=$(start_payload) || { action_error "Could not encode the Macroscope start request"; return 1; }
  if start_run "$oidc" "$payload" "$RUN_ACTION_TMP/start.json" "$RUN_ACTION_TMP/start.headers" "$RUN_ACTION_TMP/start.config" "$deadline"; then
    :
  else
    case $? in 124) unmet_exit "$IN_FAIL_ON" "Timed out while waiting for the Macroscope agent run." ;; *) return 1 ;; esac
  fi
  run_id=$(jq -r '.runId' "$RUN_ACTION_TMP/start.json")
  token=$(jq -r '.jobToken' "$RUN_ACTION_TMP/start.json")
  emit_scalar run-id "$run_id"
  if poll_run "$run_id" "$token" "$RUN_ACTION_TMP/poll.json" "$RUN_ACTION_TMP/poll.headers" "$RUN_ACTION_TMP/poll.config" "$deadline"; then
    :
  else
    case $? in 124) unmet_exit "$IN_FAIL_ON" "Timed out while waiting for the Macroscope agent run." ;; *) return 1 ;; esac
  fi
  emit_terminal_outputs "$RUN_ACTION_TMP/poll.json" "$run_id" || { action_error "Could not publish the Macroscope terminal result"; return 1; }
  conclude_run "$RUN_ACTION_TMP/poll.json"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  run_action
fi
