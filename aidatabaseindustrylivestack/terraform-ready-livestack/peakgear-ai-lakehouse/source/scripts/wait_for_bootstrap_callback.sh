#!/usr/bin/env bash
set -Eeuo pipefail

: "${BOOTSTRAP_STATUS_URL:?BOOTSTRAP_STATUS_URL must be set}"
: "${EXPECTED_INSTANCE_OCID:?EXPECTED_INSTANCE_OCID must be set}"

WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-10800}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-20}"
INITIAL_STATUS_TIMEOUT_SECONDS="${INITIAL_STATUS_TIMEOUT_SECONDS:-1200}"

log() {
  printf '[%s] [resource-manager-readiness] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if ! command -v curl >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  log "Neither curl nor python3 is available on the Resource Manager worker."
  exit 1
fi

fetch_status() {
  if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
      -H 'Cache-Control: no-cache' "${BOOTSTRAP_STATUS_URL}" 2>/dev/null || true
    return 0
  fi

  python3 - <<'PY'
import os
import sys
import urllib.request

try:
    request = urllib.request.Request(
        os.environ["BOOTSTRAP_STATUS_URL"],
        headers={"Cache-Control": "no-cache"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        sys.stdout.write(response.read().decode("utf-8"))
except Exception:
    pass
PY
}

status_field() {
  local field="$1"
  local status="$2"

  awk -F= -v field="${field}" '$1 == field { print substr($0, index($0, "=") + 1); exit }' <<<"${status}"
}

started_at="$(date +%s)"
deadline=$((started_at + WAIT_TIMEOUT_SECONDS))
initial_status_deadline=$((started_at + INITIAL_STATUS_TIMEOUT_SECONDS))
last_signature=""
reported_initial_pending="false"
reported_unexpected_instance="false"

log "Waiting up to $(( WAIT_TIMEOUT_SECONDS / 60 )) minutes for Peak Gear bootstrap."

while (( $(date +%s) < deadline )); do
  status="$(fetch_status)"
  now="$(date +%s)"

  if [[ -n "${status}" ]]; then
    state="$(status_field state "${status}")"
    phase="$(status_field phase "${status}")"
    marker="$(status_field marker "${status}")"
    instance_ocid="$(status_field instance_ocid "${status}")"
    message="$(status_field message "${status}")"

    if [[ "${instance_ocid}" != "${EXPECTED_INSTANCE_OCID}" ]]; then
      if [[ "${state}" == "PENDING" && -z "${instance_ocid}" && "${reported_initial_pending}" != "true" ]]; then
        log "Waiting for cloud-init to publish its first status."
        reported_initial_pending="true"
      elif [[ "${reported_unexpected_instance}" != "true" ]]; then
        log "Ignoring a status that was not produced by this VM."
        reported_unexpected_instance="true"
      fi
      if (( now >= initial_status_deadline )); then
        log "Cloud-init did not publish a valid status for this VM in time."
        log "Use bootstrap_log_command in the stack outputs."
        exit 1
      fi
      sleep "${POLL_INTERVAL_SECONDS}"
      continue
    fi

    signature="${state}|${phase}|${marker}"
    if [[ "${signature}" != "${last_signature}" ]]; then
      log "Bootstrap status: ${state:-unknown}${phase:+ (phase: ${phase})}."
      last_signature="${signature}"
    fi

    case "${state}" in
      SUCCEEDED)
        if [[ "${marker}" == "RESOURCE_MANAGER_DEPLOYMENT_OK" ]]; then
          log "Peak Gear, ADB loading, and declared service checks passed."
          exit 0
        fi
        log "The VM reported success without the required marker."
        exit 1
        ;;
      FAILED)
        log "The VM reported failure${phase:+ during phase: ${phase}}."
        if [[ -n "${message}" ]]; then
          log "Reason: ${message}"
        fi
        if [[ "${phase}" == "peakgear_install" ]]; then
          log "Use installer_log_command in the stack outputs for the application installer details."
        fi
        log "Use bootstrap_log_command in the stack outputs."
        exit 1
        ;;
      PENDING|RUNNING)
        ;;
      *)
        if (( now >= initial_status_deadline )); then
          log "Cloud-init did not publish a valid bootstrap status in time."
          exit 1
        fi
        ;;
    esac
  elif (( now >= initial_status_deadline )); then
    log "Cloud-init did not publish a readable bootstrap status in time."
    log "Use bootstrap_log_command in the stack outputs."
    exit 1
  fi

  sleep "${POLL_INTERVAL_SECONDS}"
done

log "Timed out waiting for Peak Gear bootstrap completion."
log "Use bootstrap_log_command in the stack outputs."
exit 1
