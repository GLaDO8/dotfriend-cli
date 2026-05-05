#!/usr/bin/env bash
# dotfriend — JSON/event API helpers
# shellcheck shell=bash

set -euo pipefail

api_json_escape() {
  local str="${1:-}"
  str="${str//\\/\\\\}"
  str="${str//\"/\\\"}"
  str="${str//$'\n'/\\n}"
  str="${str//$'\r'/}"
  str="${str//$'\t'/\\t}"
  printf '%s' "$str"
}

api_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

api_warning() {
  local code="$1" message="$2" details_json="${3:-}"
  [[ -n "$details_json" ]] || details_json="{}"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg code "$code" --arg message "$message" --argjson details "$details_json" \
      '{code:$code,message:$message,details:$details}'
    return 0
  fi
  printf '{"code":"%s","message":"%s","details":%s}' \
    "$(api_json_escape "$code")" "$(api_json_escape "$message")" "$details_json"
}

api_error() {
  api_warning "$@"
}

api_print_envelope() {
  local status="$1" command="$2" data_json="${3:-}" warnings_json="${4:-}" errors_json="${5:-}"
  [[ -n "$data_json" ]] || data_json="{}"
  [[ -n "$warnings_json" ]] || warnings_json="[]"
  [[ -n "$errors_json" ]] || errors_json="[]"
  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg command "$command" \
      --arg status "$status" \
      --argjson data "$data_json" \
      --argjson warnings "$warnings_json" \
      --argjson errors "$errors_json" \
      '{contract_version:1,command:$command,status:$status,warnings:$warnings,errors:$errors,data:$data}'
    return 0
  fi
  printf '{"contract_version":1,"command":"%s","status":"%s","warnings":%s,"errors":%s,"data":%s}\n' \
    "$(api_json_escape "$command")" "$(api_json_escape "$status")" "$warnings_json" "$errors_json" "$data_json"
}

api_event() {
  local event="$1" payload_json="${2:-}"
  [[ -n "$payload_json" ]] || payload_json="{}"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg event "$event" --arg time "$(api_now_iso)" --argjson payload "$payload_json" \
      '{contract_version:1,event:$event,time:$time} + $payload'
    return 0
  fi
  local payload_body="${payload_json#\{}"
  payload_body="${payload_body%\}}"
  if [[ -n "$payload_body" ]]; then
    printf '{"contract_version":1,"event":"%s","time":"%s",%s}\n' \
      "$(api_json_escape "$event")" "$(api_json_escape "$(api_now_iso)")" "$payload_body"
  else
    printf '{"contract_version":1,"event":"%s","time":"%s"}\n' \
      "$(api_json_escape "$event")" "$(api_json_escape "$(api_now_iso)")"
  fi
}

api_fail() {
  local command="$1" code="$2" message="$3" details_json="${4:-}"
  [[ -n "$details_json" ]] || details_json="{}"
  local errors_json
  errors_json="[$(api_error "$code" "$message" "$details_json")]"
  api_print_envelope "failed" "$command" "{}" "[]" "$errors_json"
}
