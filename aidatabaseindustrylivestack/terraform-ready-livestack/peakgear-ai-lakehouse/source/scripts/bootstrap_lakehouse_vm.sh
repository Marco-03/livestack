#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/opt/peakgear-livestack"
RUNTIME_ENV="${ROOT}/runtime-bootstrap.env"
STATUS_FILE="${ROOT}/deployment-status.txt"
BUILD_ZIP="${ROOT}/build_dev.zip"
WALLET_B64="${ROOT}/adb-wallet.b64"
WALLET_ZIP="${ROOT}/adb-wallet.zip"
INSTALLER_CONSOLE_LOG="${ROOT}/installer-console.log"
OPC_HOME="/home/opc"
INSTALLER_DETAIL_LOG="${OPC_HOME}/inst.log"
OPC_ENV="${OPC_HOME}/.env"
INGESTION_DIR="${OPC_HOME}/ingestion"
WALLET_DIR="${INGESTION_DIR}/wallet"
WALLET_STAGING_DIR="${OPC_HOME}/.peakgear"
STAGED_WALLET_ZIP="${WALLET_STAGING_DIR}/adb-wallet.zip"
BOOTSTRAP_PHASE="initializing"
BOOTSTRAP_TERMINAL_STATE=""
INSTANCE_OCID=""
PUBLIC_IP=""
OPC_UID=""

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

check_download_url() {
  local label="$1"
  local url="$2"

  if ! curl --fail --silent --show-error --location --head \
    --proto '=https' --tlsv1.2 \
    --retry 3 --retry-delay 3 \
    --connect-timeout 10 --max-time 60 \
    "${url}" >/dev/null; then
    fail "${label} URL is expired, inaccessible, or not a direct HTTPS download."
  fi
}

download_file() {
  local label="$1"
  local url="$2"
  local destination="$3"
  local partial="${destination}.part"

  rm -f "${partial}"
  if ! curl --fail --silent --show-error --location \
    --proto '=https' --tlsv1.2 \
    --retry 8 --retry-delay 5 \
    --connect-timeout 15 \
    "${url}" -o "${partial}"; then
    rm -f "${partial}"
    fail "Unable to download ${label}."
  fi

  [[ -s "${partial}" ]] || fail "${label} download is empty."
  mv -f "${partial}" "${destination}"
}

decode() {
  printf '%s' "$1" | base64 --decode
}

publish_status() {
  [[ -n "${BOOTSTRAP_STATUS_UPLOAD_URL:-}" && -f "${STATUS_FILE}" ]] || return 0

  curl --fail --silent --show-error --retry 8 --retry-delay 5 \
    --connect-timeout 10 --max-time 30 --upload-file "${STATUS_FILE}" \
    "${BOOTSTRAP_STATUS_UPLOAD_URL}" >/dev/null || {
      log "WARNING: Unable to publish the bootstrap status callback."
      return 0
    }
}

write_status() {
  local state="$1"
  local phase="$2"
  local marker="$3"
  local exit_code="${4:-}"
  local message="${5:-}"

  install -d -m 0700 "${ROOT}" 2>/dev/null || return 0
  {
    printf 'format=peakgear-rm-bootstrap/v1\n'
    printf 'state=%s\n' "${state}"
    printf 'phase=%s\n' "${phase}"
    printf 'instance_ocid=%s\n' "${INSTANCE_OCID:-unknown}"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'marker=%s\n' "${marker}"
    if [[ -n "${exit_code}" ]]; then
      printf 'exit_code=%s\n' "${exit_code}"
    fi
    if [[ -n "${message}" ]]; then
      printf 'message=%s\n' "${message//$'\n'/ }"
    fi
    if [[ "${state}" == "SUCCEEDED" ]]; then
      printf 'application=http://%s:%s/\n' "${PUBLIC_IP}" "${APPLICATION_PORT}"
      printf 'database_service=%s\n' "${ADB_SERVICE_NAME}"
      printf 'database_user=PG\n'
      printf 'gravitino=http://127.0.0.1:%s/iceberg/v1/config\n' "${GRAVITINO_PORT}"
    fi
  } > "${STATUS_FILE}" || return 0
  chmod 0600 "${STATUS_FILE}" || true
  publish_status || true
}

set_phase() {
  BOOTSTRAP_PHASE="$1"
  write_status "RUNNING" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_RUNNING"
}

remove_build_secrets() {
  if [[ -f "${OPC_ENV}" ]]; then
    sed -i \
      -e '/^CON_USER=/d' \
      -e '/^CON_TOK=/d' \
      -e '/^BUILD_ARCHIVE_URL=/d' \
      -e '/^GGSA_OSA_ARCHIVE_URL=/d' \
      -e '/^GRAVITINO_ICEBERG_REST_SERVER_ARCHIVE_URL=/d' \
      "${OPC_ENV}" || true
    chmod 0600 "${OPC_ENV}" || true
  fi

  runuser -u opc -- podman logout container-registry.oracle.com >/dev/null 2>&1 || true
  rm -f \
    "${RUNTIME_ENV}" \
    "${BUILD_ZIP}" \
    "${BUILD_ZIP}.part" \
    "${WALLET_B64}" \
    "${WALLET_B64}.part" \
    "${WALLET_ZIP}" \
    "${STAGED_WALLET_ZIP}" \
    "${INGESTION_DIR}/ggsa/V1054826-01.zip" \
    "${INGESTION_DIR}/gravitino/dist/gravitino-iceberg-rest-server-0.7.0-incubating-SNAPSHOT-bin.zip" \
    2>/dev/null || true
}

stop_application_service() {
  [[ -n "${OPC_UID}" ]] || return 0
  runuser -u opc -- env \
    HOME="${OPC_HOME}" \
    USER=opc \
    LOGNAME=opc \
    XDG_RUNTIME_DIR="/run/user/${OPC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPC_UID}/bus" \
    timeout 90 systemctl --user stop user-podman.service >/dev/null 2>&1 \
    || true
}

fail() {
  log "FAILED: $*"
  write_status "FAILED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_FAILED" "1" "$*"
  stop_application_service
  remove_build_secrets
  exit 1
}

installer_log_tail() {
  local installer_log

  # inst.log contains the ordinary installer stages, while the upstream
  # registry-login phase deliberately writes to the console. Keep console
  # second so its immediate error wins when we select the last matching line.
  for installer_log in "${INSTALLER_DETAIL_LOG}" "${INSTALLER_CONSOLE_LOG}"; do
    if [[ -r "${installer_log}" ]]; then
      tail -n 300 "${installer_log}" 2>/dev/null || true
    fi
  done
}

repair_peakgear_server_helpers() {
  local server_file="${INGESTION_DIR}/backend/server.js"

  if grep -Eq '^[[:space:]]*function[[:space:]]+envFlagEnabled[[:space:]]*\(' "${server_file}"; then
    return 0
  fi
  grep -Fq 'envFlagEnabled(' "${server_file}" \
    || fail "Peak Gear server is missing its environment-flag contract."

  sed -i "/^const PORT = process.env.PORT || 3001;$/a\\
\\
function envFlagEnabled(name, defaultValue = true) {\\
  const raw = process.env[name];\\
  if (raw == null || raw === '') return defaultValue;\\
  return ['1', 'true', 'yes', 'on'].includes(String(raw).trim().toLowerCase());\\
}" "${server_file}"

  grep -Eq '^[[:space:]]*function[[:space:]]+envFlagEnabled[[:space:]]*\(' "${server_file}" \
    || fail "Unable to repair the missing Peak Gear environment-flag helper."
  log "Repaired the missing Peak Gear environment-flag helper in the reviewed application payload."
}

repair_select_ai_package_detection() {
  local service_file="${INGESTION_DIR}/backend/lib/selectAiService.js"

  [[ -f "${service_file}" ]] \
    || fail "Peak Gear Select AI service is missing from the reviewed application payload."
  if grep -Fq "object_type IN ('PACKAGE', 'SYNONYM')" "${service_file}"; then
    return 0
  fi
  if ! grep -Fq 'FROM all_procedures' "${service_file}" \
      && ! { grep -Fq "owner IN ('SYS', 'C##CLOUD\$SERVICE')" "${service_file}" \
        && grep -Fq "object_type = 'PACKAGE'" "${service_file}"; }; then
    fail "Peak Gear Select AI package-detection contract is not recognized."
  fi

  # This runs before the installer provisions Python. Rewrite the complete
  # JavaScript template literal, including its delimiters and trailing comma.
  local repaired_file="${service_file}.select-ai-repaired"
  awk '
    BEGIN { replacing = 0; replaced = 0 }
    !replacing && /SELECT (DISTINCT )?object_name/ {
      print "    \140SELECT DISTINCT object_name"
      print "     FROM all_objects"
      print "     WHERE object_name IN (\047DBMS_CLOUD\047, \047DBMS_CLOUD_AI\047)"
      print "       AND object_type IN (\047PACKAGE\047, \047SYNONYM\047)\140,"
      replacing = 1
      replaced = 1
      next
    }
    replacing && /(AND|WHERE) object_name IN/ {
      replacing = 0
      next
    }
    replacing { next }
    { print }
    END {
      if (replacing || !replaced) exit 1
    }
  ' "${service_file}" > "${repaired_file}" \
    || fail "Unable to rewrite Peak Gear Select AI package detection."
  cat "${repaired_file}" > "${service_file}"
  rm -f "${repaired_file}"

  grep -Fq '`SELECT DISTINCT object_name' "${service_file}" \
    && grep -Fq 'FROM all_objects' "${service_file}" \
    && grep -Fq "object_type IN ('PACKAGE', 'SYNONYM')\`," "${service_file}" \
    || fail "Unable to repair Peak Gear Select AI package detection."
  log "Updated Select AI package detection to use the packages accessible to the PG schema."
}

on_unhandled_error() {
  local exit_code="$1"

  trap - ERR
  set +e
  if [[ "${BOOTSTRAP_TERMINAL_STATE}" != "SUCCEEDED" ]]; then
    log "FAILED: Bootstrap exited during ${BOOTSTRAP_PHASE} (exit code ${exit_code})."
    write_status "FAILED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_FAILED" "${exit_code}" \
      "Bootstrap exited unexpectedly during ${BOOTSTRAP_PHASE}."
    stop_application_service
    remove_build_secrets
  fi
  exit "${exit_code}"
}

trap 'on_unhandled_error "$?"' ERR

resolve_instance_metadata() {
  local attempt
  local instance_response
  local vnic_response

  for attempt in {1..12}; do
    instance_response="$(curl -fsS -H 'Authorization: Bearer Oracle' \
      http://169.254.169.254/opc/v2/instance/ 2>/dev/null || true)"
    INSTANCE_OCID="$(printf '%s' "${instance_response}" \
      | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)"

    vnic_response="$(curl -fsS -H 'Authorization: Bearer Oracle' \
      http://169.254.169.254/opc/v2/vnics/ 2>/dev/null || true)"
    PUBLIC_IP="$(printf '%s' "${vnic_response}" \
      | sed -n 's/.*"publicIp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)"

    if [[ "${INSTANCE_OCID}" == ocid1.instance.* ]]; then
      return 0
    fi
    sleep 5
  done

  fail "Unable to resolve the instance OCID from OCI IMDSv2."
}

write_env_value() {
  local key="$1"
  local value="$2"
  printf '%s=' "${key}" >> "${OPC_ENV}"
  printf '%q\n' "${value}" >> "${OPC_ENV}"
}

user_service_is_failed() {
  local unit="$1"
  local state

  [[ -n "${OPC_UID}" ]] || return 1
  state="$(
    runuser -u opc -- env \
      HOME="${OPC_HOME}" \
      USER=opc \
      LOGNAME=opc \
      XDG_RUNTIME_DIR="/run/user/${OPC_UID}" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPC_UID}/bus" \
      systemctl --user is-failed "${unit}" 2>/dev/null || true
  )"
  [[ "${state}" == "failed" ]]
}

wait_for_file() {
  local path="$1"
  local label="$2"
  local attempts="$3"

  for attempt in $(seq 1 "${attempts}"); do
    [[ -s "${path}" ]] && return 0
    if (( attempt % 20 == 0 )); then
      log "Still waiting for ${label}."
    fi
    sleep 15
  done
  fail "Timed out waiting for ${label}."
}

wait_for_database_load() {
  local attempt
  local unit

  for attempt in $(seq 1 480); do
    [[ -s "${INGESTION_DIR}/.adb_load_done" ]] && return 0
    for unit in adb-wallet.service adb-load.service; do
      if user_service_is_failed "${unit}"; then
        fail "${unit} failed before ADB schema and data loading completed. Use installer_log_command and bootstrap_log_command for details."
      fi
    done
    if (( attempt % 20 == 0 )); then
      log "Still waiting for ADB schema and data loading."
    fi
    sleep 15
  done

  fail "Timed out waiting for ADB schema and data loading."
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local attempts="$3"

  for attempt in $(seq 1 "${attempts}"); do
    if curl -fsS --connect-timeout 5 --max-time 20 "${url}" >/dev/null 2>&1; then
      return 0
    fi
    if user_service_is_failed "user-podman.service"; then
      fail "Peak Gear application services failed while waiting for ${label}. Use application_diagnostics_command for container state and logs."
    fi
    if (( attempt % 20 == 0 )); then
      log "Still waiting for ${label}."
    fi
    sleep 15
  done
  fail "Timed out waiting for ${label}."
}

wait_for_application_health() {
  local attempt
  local container_id
  local container_state

  for attempt in $(seq 1 80); do
    if curl -fsS --connect-timeout 5 --max-time 20 \
      "http://127.0.0.1:${APPLICATION_PORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi

    if user_service_is_failed "user-podman.service"; then
      fail "Peak Gear application services failed before the application health check passed. Use application_diagnostics_command for container state and logs."
    fi

    if (( attempt % 20 == 0 )); then
      container_id="$(
        runuser -u opc -- env \
          HOME="${OPC_HOME}" \
          USER=opc \
          LOGNAME=opc \
          XDG_RUNTIME_DIR="/run/user/${OPC_UID}" \
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPC_UID}/bus" \
          podman ps -a \
            --filter label=io.podman.compose.service=app \
            --format '{{.ID}}' 2>/dev/null \
          | head -n 1
      )"
      if [[ -n "${container_id}" ]]; then
        container_state="$(
          runuser -u opc -- env \
            HOME="${OPC_HOME}" \
            USER=opc \
            LOGNAME=opc \
            XDG_RUNTIME_DIR="/run/user/${OPC_UID}" \
            podman inspect --format '{{.State.Status}}' "${container_id}" 2>/dev/null \
            || true
        )"
        log "Still waiting for Peak Gear application health (container: ${container_state:-unknown})."
      else
        log "Still waiting for Peak Gear application health (app container not created yet)."
      fi
    fi
    sleep 15
  done

  fail "Timed out waiting 20 minutes for Peak Gear application health. Use application_diagnostics_command for the app container state and logs."
}

wait_for_tcp() {
  local port="$1"
  local label="$2"
  local attempts="$3"

  for attempt in $(seq 1 "${attempts}"); do
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
      return 0
    fi
    if user_service_is_failed "user-podman.service"; then
      fail "Peak Gear application services failed while waiting for ${label}. Use application_diagnostics_command for container state and logs."
    fi
    if (( attempt % 20 == 0 )); then
      log "Still waiting for ${label}."
    fi
    sleep 15
  done
  fail "Timed out waiting for ${label}."
}

wait_for_streaming_analytics() {
  local attempt
  local response

  for attempt in $(seq 1 80); do
    response="$(
      curl -fsS --connect-timeout 5 --max-time 20 \
        "http://127.0.0.1:${APPLICATION_PORT}/api/streaming-analytics/status" \
        2>/dev/null \
        || true
    )"
    if grep -Eq '"connected"[[:space:]]*:[[:space:]]*true' <<< "${response}"; then
      return 0
    fi
    if user_service_is_failed "user-podman.service"; then
      fail "Peak Gear application services failed while waiting for GoldenGate Stream Analytics. Use application_diagnostics_command for container state and logs."
    fi
    if (( attempt % 20 == 0 )); then
      log "Still waiting for GoldenGate Stream Analytics and its ADB connection."
    fi
    sleep 15
  done

  fail "Timed out waiting 20 minutes for GoldenGate Stream Analytics and its ADB connection. Use application_diagnostics_command for container state and logs."
}

[[ -f "${RUNTIME_ENV}" ]] || fail "Missing protected runtime configuration."

# shellcheck disable=SC1090
source "${RUNTIME_ENV}"

WALLET_ARCHIVE_URL="$(decode "${WALLET_ARCHIVE_URL_B64}")"
BOOTSTRAP_STATUS_UPLOAD_URL="$(decode "${BOOTSTRAP_STATUS_UPLOAD_URL_B64}")"
ADB_ADMIN_PASSWORD="$(decode "${ADB_ADMIN_PASSWORD_B64}")"
ADB_CONNECTION="$(decode "${ADB_CONNECTION_B64}")"
ADB_SERVICE_NAME="$(decode "${ADB_SERVICE_NAME_B64}")"
ADB_NAME="$(decode "${ADB_NAME_B64}")"
ADB_OCID="$(decode "${ADB_OCID_B64}")"
ADB_ORDS_URL="$(decode "${ADB_ORDS_URL_B64}")"
ADB_BASE_URL="$(decode "${ADB_BASE_URL_B64}")"
OCI_PRIVATE_KEY="$(decode "${OCI_PRIVATE_KEY_B64}")"
OCI_FINGERPRINT="$(decode "${OCI_FINGERPRINT_B64}")"
OCI_USER_OCID="$(decode "${OCI_USER_OCID_B64}")"
TENANCY_OCID="$(decode "${TENANCY_OCID_B64}")"
COMPARTMENT_OCID="$(decode "${COMPARTMENT_OCID_B64}")"
REGION="$(decode "${REGION_B64}")"
AI_ENDPOINT_REGION="$(decode "${AI_ENDPOINT_REGION_B64}")"
OBJECT_NAMESPACE="$(decode "${OBJECT_NAMESPACE_B64}")"
BUCKET_NAME="$(decode "${BUCKET_NAME_B64}")"
BUCKET_PAR="$(decode "${BUCKET_PAR_B64}")"
S3_ENDPOINT="$(decode "${S3_ENDPOINT_B64}")"
AI_DATA_CATALOG_URL="$(decode "${AI_DATA_CATALOG_URL_B64}")"
AI_DATA_CATALOG_WAREHOUSE="$(decode "${AI_DATA_CATALOG_WAREHOUSE_B64}")"
AI_DATA_CATALOG_S3_ENDPOINT="$(decode "${AI_DATA_CATALOG_S3_ENDPOINT_B64}")"
S3_ACCESS_KEY="$(decode "${S3_ACCESS_KEY_B64}")"
S3_SECRET_KEY="$(decode "${S3_SECRET_KEY_B64}")"
REGISTRY_USERNAME="$(decode "${REGISTRY_USERNAME_B64}")"
REGISTRY_AUTH_TOKEN="$(decode "${REGISTRY_AUTH_TOKEN_B64}")"
GGSA_ARCHIVE_URL="$(decode "${GGSA_ARCHIVE_URL_B64}")"
BUILD_ARCHIVE_URL="$(decode "${BUILD_ARCHIVE_URL_B64}")"
BUILD_ARCHIVE_SHA256="$(decode "${BUILD_ARCHIVE_SHA256_B64}")"
GRAVITINO_ARCHIVE_URL="$(decode "${GRAVITINO_ARCHIVE_URL_B64}")"

resolve_instance_metadata
set_phase "runtime_configuration"

[[ "${WALLET_ARCHIVE_URL}" == https://* ]] || fail "ADB wallet URL must use HTTPS."
[[ "${BOOTSTRAP_STATUS_UPLOAD_URL}" == https://* ]] || fail "Status callback URL must use HTTPS."
[[ "${BUILD_ARCHIVE_URL}" == https://* ]] || fail "Peak Gear build URL must use HTTPS."
[[ "${BUILD_ARCHIVE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "Peak Gear build checksum is invalid."
[[ "${GRAVITINO_ARCHIVE_URL}" == https://* ]] || fail "Gravitino URL must use HTTPS."
[[ "${GGSA_ARCHIVE_URL}" == https://* ]] || fail "GGSA URL must use HTTPS."
[[ "${ADB_OCID}" == ocid1.autonomousdatabase.* ]] || fail "ADB OCID is invalid."
[[ "${OCI_USER_OCID}" == ocid1.user.* ]] || fail "OCI user OCID is invalid."
[[ "${TENANCY_OCID}" == ocid1.tenancy.* ]] || fail "Tenancy OCID is invalid."
[[ "${COMPARTMENT_OCID}" == ocid1.compartment.* || "${COMPARTMENT_OCID}" == ocid1.tenancy.* ]] || fail "Compartment OCID is invalid."
[[ "${OCI_PRIVATE_KEY}" == *"BEGIN RSA PRIVATE KEY"* || "${OCI_PRIVATE_KEY}" == *"BEGIN PRIVATE KEY"* ]] || fail "Generated OCI private key is invalid."
[[ -n "${REGISTRY_USERNAME}" && -n "${REGISTRY_AUTH_TOKEN}" ]] || fail "Container Registry credentials are missing."
[[ "${AI_DATA_CATALOG_URL}" =~ ^https://[^/]+/catalog$ ]] || fail "AI Data Catalog URL is invalid."
[[ "${AI_DATA_CATALOG_WAREHOUSE}" =~ ^s3://[A-Za-z0-9._-]+$ ]] || fail "AI Data Catalog warehouse is invalid."
[[ "${AI_DATA_CATALOG_S3_ENDPOINT}" =~ ^https://[^/]+$ ]] || fail "AI Data Catalog S3 endpoint is invalid."

umask 077
install -d -m 0700 "${ROOT}"

set_phase "artifact_preflight"
log "Checking approved software download URLs."
check_download_url "Peak Gear build archive" "${BUILD_ARCHIVE_URL}"
check_download_url "Gravitino archive" "${GRAVITINO_ARCHIVE_URL}"
check_download_url "GoldenGate Stream Analytics archive" "${GGSA_ARCHIVE_URL}"

set_phase "application_download"
log "Downloading the approved Peak Gear build bundle."
download_file "Peak Gear build archive" "${BUILD_ARCHIVE_URL}" "${BUILD_ZIP}"
ACTUAL_BUILD_SHA256="$(sha256sum "${BUILD_ZIP}" | awk '{print $1}')"
[[ "${ACTUAL_BUILD_SHA256}" == "${BUILD_ARCHIVE_SHA256}" ]] \
  || fail "Peak Gear build bundle checksum does not match the reviewed release."
unzip -tq "${BUILD_ZIP}" >/dev/null || fail "Peak Gear build bundle is not a valid ZIP."
unzip -oq "${BUILD_ZIP}" -d "${OPC_HOME}"

normalize_runtime_text_files() {
  local runtime_text_file

  while IFS= read -r -d '' runtime_text_file; do
    sed -i 's/\r$//' "${runtime_text_file}" \
      || fail "Unable to normalize runtime text file: ${runtime_text_file}"
  done < <(
    find "${OPC_HOME}" -type f \
      \( -name '*.sh' \
         -o -name '*.service' \
         -o -name 'Dockerfile' \
         -o -name '*.yml' \
         -o -name '*.yaml' \
         -o -name '*.py' \) \
      -print0
  )
}

normalize_runtime_text_files
if grep -q $'\r' "${OPC_HOME}/inst.sh"; then
  fail "Peak Gear installer still contains Windows line endings."
fi

SETENV_SCRIPT="${OPC_HOME}/init/setenv.sh"
ADB_WALLET_UNIT="${OPC_HOME}/init/adb-wallet.service"
ADB_LOAD_UNIT="${OPC_HOME}/init/adb-load.service"
PODMAN_SOURCE_UNIT="${OPC_HOME}/init/user-podman.service"
PG_ICEBERG_UNIT="${OPC_HOME}/init/pg-iceberg-connection.service"
ICEBERG_SEED_UNIT="${OPC_HOME}/init/iceberg-seed.service"
PG_AI_DATA_CATALOG_UNIT="${OPC_HOME}/init/pg-ai-data-catalog.service"

[[ -f "${OPC_HOME}/inst.sh" && -f "${SETENV_SCRIPT}" && -f "${ADB_WALLET_UNIT}" && -f "${ADB_LOAD_UNIT}" && -f "${PODMAN_SOURCE_UNIT}" && -f "${PG_ICEBERG_UNIT}" && -f "${ICEBERG_SEED_UNIT}" && -f "${PG_AI_DATA_CATALOG_UNIT}" && -f "${OPC_HOME}/init/configure-ai-data-catalog.sh" && -f "${INGESTION_DIR}/compose.yml" && -f "${INGESTION_DIR}/backend/server.js" ]] \
  || fail "Peak Gear build bundle is missing required files."
grep -Fq 'COMPOSE_ENV="$POD_ROOT/.env"' "${SETENV_SCRIPT}" \
  && grep -Fq 'mv "${TMP_ENV}" "${COMPOSE_ENV}"' "${SETENV_SCRIPT}" \
  || fail "Peak Gear setenv.sh no longer matches the required Compose environment contract."
grep -Fq "ExecStartPre=/bin/bash -c '/home/opc/init/setenv.sh'" "${ADB_WALLET_UNIT}" \
  && grep -Fq "ExecStartPost=/bin/bash -c '/home/opc/init/adb-load.sh'" "${ADB_WALLET_UNIT}" \
  || fail "Peak Gear ADB wallet service no longer matches the required setup order."
grep -Fq 'ConditionPathExists=!/home/opc/ingestion/.adb_load_done' "${ADB_LOAD_UNIT}" \
  || fail "Peak Gear ADB load service no longer protects completed database loads."
grep -Fq 'After=network-online.target adb-wallet.service adb-load.service pg-ai-data-catalog.service' "${PODMAN_SOURCE_UNIT}" \
  && grep -Fq "ExecStartPre=/bin/bash -c '/home/opc/init/setenv.sh'" "${PODMAN_SOURCE_UNIT}" \
  || fail "Peak Gear Podman service no longer matches the required ADB, AI Data Catalog, and environment dependencies."
grep -Fq 'Before=user-podman.service' "${PG_AI_DATA_CATALOG_UNIT}" \
  && grep -Fq 'ExecStart=/bin/bash /home/opc/init/configure-ai-data-catalog.sh' "${PG_AI_DATA_CATALOG_UNIT}" \
  || fail "Peak Gear AI Data Catalog service no longer matches the required startup contract."
grep -Fq 'After=network-online.target adb-wallet.service adb-load.service user-podman.service' "${PG_ICEBERG_UNIT}" \
  && grep -Fq 'After=network-online.target adb-wallet.service adb-load.service user-podman.service' "${ICEBERG_SEED_UNIT}" \
  || fail "Peak Gear post-start services no longer wait for the application stack."
repair_peakgear_server_helpers
repair_select_ai_package_detection
[[ ! -L "${WALLET_DIR}" ]] \
  || fail "Refusing to use a symbolic-link ADB wallet directory."
install -d -o opc -g opc -m 0700 "${WALLET_DIR}" \
  || fail "Unable to prepare the ADB wallet directory."
[[ -d "${WALLET_DIR}" && ! -L "${WALLET_DIR}" ]] \
  || fail "Unable to prepare the ADB wallet directory."

# The build archive can be produced on a developer workstation. Remove only
# runtime state so a new VM never reports packaging-time logs or markers as
# deployment output. Resource Manager supplies the wallet below.
rm -f \
  "${INSTALLER_DETAIL_LOG}" \
  "${INGESTION_DIR}/logs/adb-load.log" \
  "${INGESTION_DIR}/logs/adb-wallet.log" \
  "${INGESTION_DIR}/.adb_load_done" \
  "${INGESTION_DIR}/.oci_wallet_required" \
  "${WALLET_DIR}/.wallet_done"

set_phase "wallet_download"
log "Downloading the generated Autonomous Database wallet."
download_file "Autonomous Database wallet" "${WALLET_ARCHIVE_URL}" "${WALLET_B64}"
base64 --decode "${WALLET_B64}" > "${WALLET_ZIP}"
unzip -tq "${WALLET_ZIP}" >/dev/null || fail "Generated Autonomous Database wallet is invalid."
[[ ! -L "${WALLET_STAGING_DIR}" ]] \
  || fail "Refusing to stage the ADB wallet through a symbolic-link directory."
# Create this as opc.  In V14, root created missing ~/.local/share parents
# while staging the wallet, which blocked rootless Podman later in the install.
runuser -u opc -- install -d -m 0700 "${WALLET_STAGING_DIR}" \
  || fail "Unable to prepare the ADB wallet staging directory."
install -o opc -g opc -m 0600 "${WALLET_ZIP}" "${STAGED_WALLET_ZIP}"
runuser -u opc -- unzip -tq "${STAGED_WALLET_ZIP}" >/dev/null \
  || fail "The staged Autonomous Database wallet is not readable by the application user."
runuser -u opc -- install -d -m 0700 \
  "${OPC_HOME}/.local/share/containers/storage/libpod" \
  || fail "Unable to initialize rootless Podman storage for the application user."
runuser -u opc -- test -w "${OPC_HOME}/.local/share/containers/storage/libpod" \
  || fail "Rootless Podman storage is not writable by the application user."

set_phase "runtime_environment"
: > "${OPC_ENV}"
write_env_value "PUBLIC_IP" "${PUBLIC_IP}"
write_env_value "DBPASSWORD" "${ADB_ADMIN_PASSWORD}"
write_env_value "adbwallet" "${STAGED_WALLET_ZIP}"
write_env_value "ADB_WALLET_REQUIRE_OCI_GENERATION" "false"
write_env_value "dbconnectionlocal" "${ADB_CONNECTION}"
write_env_value "pem_keylocal" "${OCI_PRIVATE_KEY}"
write_env_value "pem_key_fingerprintlocal" "${OCI_FINGERPRINT}"
write_env_value "user_ocidlocal" "${OCI_USER_OCID}"
write_env_value "tenancy_ocidlocal" "${TENANCY_OCID}"
write_env_value "region_identifierlocal" "${REGION}"
write_env_value "ai_endpoint_regionlocal" "${AI_ENDPOINT_REGION}"
write_env_value "oci_auth_typelocal" "api_key"
write_env_value "compartment_ocidlocal" "${COMPARTMENT_OCID}"
write_env_value "adb_ocidlocal" "${ADB_OCID}"
write_env_value "ordsurllocal" "${ADB_ORDS_URL}"
write_env_value "dbnamelocal" "${ADB_NAME}"
write_env_value "baseurllocal" "${ADB_BASE_URL}"
write_env_value "BUCKET_PAR" "${BUCKET_PAR}"
write_env_value "BUCKET_NAME" "${BUCKET_NAME}"
write_env_value "OBJECT_NAMESPACE" "${OBJECT_NAMESPACE}"
write_env_value "GRAVITINO_S3_ENDPOINT" "${S3_ENDPOINT}"
write_env_value "GRAVITINO_S3_REGION" "${REGION}"
write_env_value "GRAVITINO_S3_ACCESS_KEY_ID" "${S3_ACCESS_KEY}"
write_env_value "GRAVITINO_S3_SECRET_ACCESS_KEY" "${S3_SECRET_KEY}"
write_env_value "GRAVITINO_OBJECT_STORAGE_BUCKET" "${BUCKET_NAME}"
write_env_value "GRAVITINO_OBJECT_STORAGE_PREFIX" "iceberg"
write_env_value "AI_DATA_CATALOG_ENABLED" "true"
write_env_value "AI_DATA_CATALOG_URL" "${AI_DATA_CATALOG_URL}"
write_env_value "AI_DATA_CATALOG_WAREHOUSE" "${AI_DATA_CATALOG_WAREHOUSE}"
write_env_value "AI_DATA_CATALOG_S3_ENDPOINT" "${AI_DATA_CATALOG_S3_ENDPOINT}"
write_env_value "AI_DATA_CATALOG_REGISTER_STORAGE" "true"
write_env_value "WEBSHOP_UPLOAD_PAR_URL" "${BUCKET_PAR}"
write_env_value "webshop_upload_par_url_local" "${BUCKET_PAR}"
write_env_value "WEBSHOP_UPLOAD_OBJECT_PREFIX" "webshop-uploads"
write_env_value "webshop_upload_object_prefix_local" "webshop-uploads"
write_env_value "PG_AI_PROFILE_AUTO_SETUP" "true"
write_env_value "OCI_GENAI_MODEL" "cohere.command-a-03-2025"
write_env_value "OCI_GENAI_EMBEDDING_MODEL" "cohere.embed-v4.0"
write_env_value "OCI_AI_PROFILE_NAME" "PG_GENAI_PROFILE"
write_env_value "OCI_GENAI_CREDENTIAL_NAME" "PG_OCI_GENAI_CRED"
write_env_value "CON_USER" "${REGISTRY_USERNAME}"
write_env_value "CON_TOK" "${REGISTRY_AUTH_TOKEN}"
write_env_value "BUILD_ARCHIVE_URL" "${BUILD_ARCHIVE_URL}"
write_env_value "GGSA_OSA_ARCHIVE_URL" "${GGSA_ARCHIVE_URL}"
write_env_value "GRAVITINO_ICEBERG_REST_SERVER_ARCHIVE_URL" "${GRAVITINO_ARCHIVE_URL}"
chmod 0600 "${OPC_ENV}"

# The upstream scripts were created for a LiveLabs image build. Resource
# Manager already delivered the bundle and owns network access, so remove only
# those two image-build-only sections while preserving the application logic.
cp "${OPC_HOME}/inst.sh" "${OPC_HOME}/inst.resource-manager.sh"
sed -i \
  -e '/## some LiveLabs config/,/## load variables/{/## load variables/!d;}' \
  -e '/progress 9 "Downloading and extracting application files"/,/rm \/home\/opc\/build_dev.zip/d' \
  -e '/add-rich-rule=.*10\.0\.0\.0\/24/d' \
  -e '/^[[:space:]]*sudo dnf install -y podman-compose[[:space:]]*$/d' \
  -e 's/wget -O "${OSA_ARCHIVE_TMP}"/wget -q -O "${OSA_ARCHIVE_TMP}"/' \
  -e 's/wget -O "${GRAVITINO_ARCHIVE_TMP}"/wget -q -O "${GRAVITINO_ARCHIVE_TMP}"/' \
  -e 's#sudo pip3\.11 install --upgrade podman-compose#/home/opc/init/install-podman-compose.sh#' \
  -e 's#  /usr/local/bin/podman-compose -f compose.yml --profile seed build iceberg-seeder#  /home/opc/init/build-iceberg-seeder.sh#' \
  -e 's#systemctl --user start user-podman#/home/opc/init/start-application-services.sh#' \
  -e 's#| podman login --username "${CON_USER}" --password-stdin container-registry.oracle.com#| /home/opc/init/login-container-registry.sh --username "${CON_USER}" --password-stdin container-registry.oracle.com#' \
  "${OPC_HOME}/inst.resource-manager.sh"

if grep -Eq '^[[:space:]]*sudo[[:space:]]+dnf[[:space:]]+install[[:space:]]+-y[[:space:]]+podman-compose' \
  "${OPC_HOME}/inst.resource-manager.sh"; then
  fail "The reviewed Peak Gear installer still contains the unsupported podman-compose RPM step."
fi
if ! grep -Fq '/home/opc/init/install-podman-compose.sh' \
  "${OPC_HOME}/inst.resource-manager.sh"; then
  fail "The reviewed Peak Gear installer no longer matches the expected podman-compose setup."
fi
if ! grep -Fq '/home/opc/init/build-iceberg-seeder.sh' \
  "${OPC_HOME}/inst.resource-manager.sh"; then
  fail "The reviewed Peak Gear installer no longer matches the expected Iceberg seeder build step."
fi
if ! grep -Fq '/home/opc/init/start-application-services.sh' \
  "${OPC_HOME}/inst.resource-manager.sh"; then
  fail "The reviewed Peak Gear installer no longer matches the expected service startup step."
fi
if ! grep -Fq '/home/opc/init/login-container-registry.sh --username "${CON_USER}" --password-stdin container-registry.oracle.com' \
  "${OPC_HOME}/inst.resource-manager.sh"; then
  fail "The reviewed Peak Gear installer no longer matches the expected registry login step."
fi

cat > "${OPC_HOME}/init/login-container-registry.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

max_attempts=6
retry_delay=15
max_retry_delay=60
token="$(cat)"

cleanup() {
  unset token
}
trap cleanup EXIT

for ((attempt = 1; attempt <= max_attempts; attempt++)); do
  if printf '%s' "${token}" | podman login "$@"; then
    exit 0
  fi

  if (( attempt == max_attempts )); then
    echo "Container registry login failed after ${max_attempts} attempts." >&2
    exit 1
  fi

  echo "Container registry login attempt ${attempt}/${max_attempts} failed; retrying in ${retry_delay} seconds." >&2
  sleep "${retry_delay}"
  if (( retry_delay < max_retry_delay )); then
    retry_delay=$((retry_delay + 15))
    if (( retry_delay > max_retry_delay )); then
      retry_delay="${max_retry_delay}"
    fi
  fi
done
EOF
chmod 0700 "${OPC_HOME}/init/login-container-registry.sh"

COMPOSE_FILE="${INGESTION_DIR}/compose.yml"
PODMAN_UNIT="${OPC_HOME}/init/user-podman.service"
SETENV_FILE="${OPC_HOME}/init/setenv.sh"
[[ -f "${COMPOSE_FILE}" && -f "${PODMAN_UNIT}" && -f "${SETENV_FILE}" ]] \
  || fail "Peak Gear application compose or user service definition is missing."
# Runtime ZIPs built from a Windows checkout can preserve CRLF in the systemd
# unit. Normalize it before applying and validating the exact startup edits.
sed -i 's/\r$//' "${PODMAN_UNIT}" \
  || fail "Unable to normalize the Peak Gear service definition."
if grep -q $'\r' "${PODMAN_UNIT}"; then
  fail "The Peak Gear service definition still contains Windows line endings."
fi
grep -Fq 'ORACLE_CONNECTION_STRING: db:1521/FREEPDB1' "${COMPOSE_FILE}" \
  || fail "The reviewed Peak Gear compose file no longer matches the expected database configuration."
grep -Eq '^ExecStartPre=.*\/usr\/local\/bin\/podman-compose([[:space:]]|.*[[:space:]])down' "${PODMAN_UNIT}" \
  || fail "The reviewed Peak Gear service no longer contains a recognized Compose cleanup step."

# ORDS 26.2 renamed its required database-password variable. Keep the
# reviewed application bundle compatible with both the old and new images.
if ! grep -Fq 'echo "ORACLE_USER_PWD=${DBPASSWORD}"' "${SETENV_FILE}"; then
  grep -Fq 'echo "ORACLE_PWD=${DBPASSWORD}"' "${SETENV_FILE}" \
    || fail "The reviewed Peak Gear environment generator no longer matches the expected ORDS configuration."
  sed -i \
    '/echo "ORACLE_PWD=${DBPASSWORD}"/a\  echo "ORACLE_USER_PWD=${DBPASSWORD}"' \
    "${SETENV_FILE}"
fi
# The production compose file can add, rename, or reorder services. Restrict
# this edit to the ords service itself rather than assuming its next neighbor.
ords_scope="$({
  awk '
    $0 == "  ords:" { in_ords = 1; next }
    in_ords && $0 ~ /^  [A-Za-z0-9_.-]+:$/ { exit }
    in_ords { print }
  ' "${COMPOSE_FILE}"
} || true)"
if [[ -z "${ords_scope}" ]]; then
  fail "The reviewed Peak Gear compose file does not define an ORDS service."
fi

ords_has_user_password=false
if grep -Fq 'ORACLE_USER_PWD:' <<<"${ords_scope}"; then
  ords_has_user_password=true
fi

ords_compose_tmp="$(mktemp)"
if ! awk -v has_user_password="${ords_has_user_password}" '
  function is_service_header(line) {
    return line ~ /^  [A-Za-z0-9_.-]+:$/
  }

  $0 == "  ords:" {
    in_ords = 1
    print
    next
  }

  in_ords && is_service_header($0) {
    in_ords = 0
  }

  in_ords && $0 ~ /^[[:space:]]+ORACLE_USER_PWD:/ {
    print "      ORACLE_USER_PWD: ${ORACLE_PWD:-oracle}"
    repaired = 1
    next
  }

  in_ords && has_user_password == "false" && $0 ~ /^[[:space:]]+ORACLE_PWD:/ {
    print
    print "      ORACLE_USER_PWD: ${ORACLE_PWD:-oracle}"
    repaired = 1
    next
  }

  { print }

  END {
    if (!repaired) {
      exit 42
    }
  }
' "${COMPOSE_FILE}" > "${ords_compose_tmp}"; then
  rm -f "${ords_compose_tmp}"
  fail "Unable to configure the ORDS database-password value in the production Compose file."
fi
mv "${ords_compose_tmp}" "${COMPOSE_FILE}"
grep -Fq 'echo "ORACLE_USER_PWD=${DBPASSWORD}"' "${SETENV_FILE}" \
  || fail "Unable to configure the ORDS database-password environment value."
awk '
  $0 == "  ords:" { in_ords = 1; next }
  in_ords && $0 ~ /^  [A-Za-z0-9_.-]+:$/ { exit }
  in_ords { print }
' "${COMPOSE_FILE}" \
  | grep -Fq 'ORACLE_USER_PWD: ${ORACLE_PWD:-oracle}' \
  || fail "Unable to pass the required database-password value to ORDS."

# Resource Manager has already loaded the PG schema into ADB. Start the app
# against that database before the optional, heavyweight demo services so a
# slow GoldenGate or Private AI startup cannot block the main application.
sed -i \
  -e 's#ORACLE_CONNECTION_STRING: db:1521/FREEPDB1#ORACLE_CONNECTION_STRING: ${DBCONNECTION:-}#' \
  -e '/ORACLE_CONNECTION_STRING: ${DBCONNECTION:-}/a\      ORACLE_WALLET_LOCATION: /wallet\n      ORACLE_WALLET_PASSWORD: ${ADB_WALLET_PASSWORD:-}' \
  "${COMPOSE_FILE}"
sed -i \
  "/^ExecStartPre=\/bin\/bash -c '\/home\/opc\/init\/setenv.sh'$/a\\
ExecStartPre=/bin/bash -lc 'set -a; source /home/opc/ingestion/.env; set +a; /usr/local/bin/podman-compose up --no-deps -d app'" \
  "${PODMAN_UNIT}"

grep -Fq 'ORACLE_CONNECTION_STRING: ${DBCONNECTION:-}' "${COMPOSE_FILE}" \
  || fail "Unable to configure the Peak Gear app for the provisioned ADB."
grep -Fq 'podman-compose up --no-deps -d app' "${PODMAN_UNIT}" \
  || fail "Unable to configure early Peak Gear application startup."
sed -i '\#^ExecStartPre=.*\/usr\/local\/bin\/podman-compose.*[[:space:]]down.*$#d' "${PODMAN_UNIT}"
if grep -Eq '^ExecStartPre=.*\/usr\/local\/bin\/podman-compose([[:space:]]|.*[[:space:]])down' "${PODMAN_UNIT}"; then
  fail "Unable to preserve prebuilt application services during Podman startup."
fi

cat > "${OPC_HOME}/init/install-podman-compose.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

runtime_dir="/opt/peakgear-podman-compose"
python_bin="$(command -v python3.11)"
wrapper_tmp="$(mktemp)"

cleanup() {
  rm -f "${wrapper_tmp}"
}
trap cleanup EXIT

[[ -x "${python_bin}" ]] || {
  echo "PEAKGEAR_ERROR: Python 3.11 is unavailable for the isolated podman-compose runtime." >&2
  exit 1
}

sudo rm -rf "${runtime_dir}"
if ! sudo "${python_bin}" -m pip install \
    --disable-pip-version-check \
    --no-cache-dir \
    --target "${runtime_dir}" \
    'podman-compose==1.6.0'; then
  echo "PEAKGEAR_ERROR: The isolated podman-compose package installation failed." >&2
  exit 1
fi
sudo chown -R root:root "${runtime_dir}"
sudo chmod -R a+rX "${runtime_dir}"
sudo chmod -R go-w "${runtime_dir}"
if [[ ! -r "${runtime_dir}/podman_compose.py" ]]; then
  echo "PEAKGEAR_ERROR: The isolated podman-compose module is not readable by the application user." >&2
  exit 1
fi

installed_version="$(
  PYTHONPATH="${runtime_dir}" "${python_bin}" -c \
    'import podman_compose; print(podman_compose.__version__)'
)" || {
  echo "PEAKGEAR_ERROR: The isolated podman-compose module import failed." >&2
  exit 1
}
if [[ "${installed_version}" != "1.6.0" ]]; then
  echo "PEAKGEAR_ERROR: The isolated podman-compose version validation failed." >&2
  exit 1
fi

cat > "${wrapper_tmp}" <<WRAPPER
#!/usr/bin/env bash
export PYTHONPATH="${runtime_dir}"
exec "${python_bin}" -m podman_compose "\$@"
WRAPPER
if ! sudo install -o root -g root -m 0755 \
    "${wrapper_tmp}" /usr/local/bin/podman-compose; then
  echo "PEAKGEAR_ERROR: The isolated podman-compose launcher installation failed." >&2
  exit 1
fi
echo "Installed isolated podman-compose ${installed_version}."
EOF
chmod 0700 "${OPC_HOME}/init/install-podman-compose.sh"

cat > "${OPC_HOME}/init/build-iceberg-seeder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /home/opc/ingestion
for attempt in 1 2 3; do
  echo "Iceberg seeder image build attempt ${attempt} of 3."
  if /usr/local/bin/podman-compose -f compose.yml --profile seed build iceberg-seeder; then
    exit 0
  fi
  if [[ "${attempt}" != "3" ]]; then
    sleep $((attempt * 20))
  fi
done

echo "Iceberg seeder image build failed after 3 attempts." >&2
exit 1
EOF
chmod 0700 "${OPC_HOME}/init/build-iceberg-seeder.sh"

cat > "${OPC_HOME}/init/ensure-security-schema.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

INGESTION_DIR="/home/opc/ingestion"
ENV_FILE="${INGESTION_DIR}/.env"
WALLET_DIR="${INGESTION_DIR}/wallet"
SECURITY_SQL="${INGESTION_DIR}/db/schema/06_security.sql"
MARKER_FILE="${INGESTION_DIR}/.security_schema_done"
WORK_DIR=""

cleanup() {
  [[ -z "${WORK_DIR}" || ! -d "${WORK_DIR}" ]] || rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

[[ -s "${ENV_FILE}" ]] || { echo "PEAKGEAR_ERROR: ADB environment is missing." >&2; exit 1; }
[[ -s "${WALLET_DIR}/tnsnames.ora" ]] || { echo "PEAKGEAR_ERROR: ADB wallet is missing." >&2; exit 1; }
[[ -s "${SECURITY_SQL}" ]] || { echo "PEAKGEAR_ERROR: Peak Gear security SQL is missing." >&2; exit 1; }
command -v sql >/dev/null 2>&1 || { echo "PEAKGEAR_ERROR: SQLcl is not installed." >&2; exit 1; }

set +u
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
set -u

[[ -n "${DBPASSWORD:-}" ]] || { echo "PEAKGEAR_ERROR: ADB password is missing." >&2; exit 1; }

WORK_DIR="$(mktemp -d /tmp/peakgear-security.XXXXXX)"
chmod 0700 "${WORK_DIR}"
mkdir -p "${WORK_DIR}/wallet"
cp -R "${WALLET_DIR}/." "${WORK_DIR}/wallet/"
if [[ -f "${WORK_DIR}/wallet/ojdbc.properties" ]]; then
  escaped_wallet_dir="$(printf '%s' "${WORK_DIR}/wallet" | sed 's/[\/&]/\\&/g')"
  sed -i "s#/wallet#${escaped_wallet_dir}#g" "${WORK_DIR}/wallet/ojdbc.properties"
fi
export TNS_ADMIN="${WORK_DIR}/wallet"

connect_target="${SERVICE_NAME:-}"
if [[ -n "${connect_target}" ]] && ! grep -Eiq "^[[:space:]]*${connect_target}[[:space:]]*=" "${TNS_ADMIN}/tnsnames.ora"; then
  connect_target=""
fi
if [[ -z "${connect_target}" ]]; then
  connect_target="$(awk 'tolower($0) ~ /^[[:space:]]*[a-z0-9_]+_high[[:space:]]*=/ { gsub(/[[:space:]=]/, "", $1); print $1; exit }' "${TNS_ADMIN}/tnsnames.ora")"
fi
[[ -n "${connect_target}" ]] || connect_target="${DBCONNECTION:-}"
[[ -n "${connect_target}" ]] || { echo "PEAKGEAR_ERROR: ADB connection target is missing." >&2; exit 1; }

awk -v start='-- SECTION 1: RUN AS ADMIN' -v end='-- SECTION 2: RUN AS PG' '
  index($0, start) { in_section = 1; next }
  index($0, end) { exit }
  in_section { print }
' "${SECURITY_SQL}" > "${WORK_DIR}/security-admin.sql"
awk -v start='-- SECTION 2: RUN AS PG' -v end='-- AUDIT POLICY (Unified Auditing)' '
  index($0, start) { in_section = 1; next }
  index($0, end) { exit }
  in_section { print }
' "${SECURITY_SQL}" > "${WORK_DIR}/security-pg.sql"
[[ -s "${WORK_DIR}/security-admin.sql" && -s "${WORK_DIR}/security-pg.sql" ]] \
  || { echo "PEAKGEAR_ERROR: Security SQL sections could not be extracted." >&2; exit 1; }

admin_password="$(printf '%s' "${DBPASSWORD}" | sed 's/"/""/g')"
schema_password="$(printf '%s' "${ADB_STREAM_SCHEMA_PASSWORD:-${DBPASSWORD}}" | sed 's/"/""/g')"
cat > "${WORK_DIR}/install-security.sql" <<SQL
SET ECHO OFF
SET DEFINE OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT SQL.SQLCODE
CONNECT ADMIN/"${admin_password}"@"${connect_target}"
@"${WORK_DIR}/security-admin.sql"
CONNECT PG/"${schema_password}"@"${connect_target}"
@"${WORK_DIR}/security-pg.sql"
DECLARE
  v_valid NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_valid
  FROM user_objects
  WHERE object_name = 'SC_SECURITY_CTX'
    AND object_type IN ('PACKAGE', 'PACKAGE BODY')
    AND status = 'VALID';
  IF v_valid != 2 THEN
    RAISE_APPLICATION_ERROR(-20001, 'SC_SECURITY_CTX package and body must both be valid.');
  END IF;
END;
/
EXIT
SQL

if ! sql -L /nolog @"${WORK_DIR}/install-security.sql" > "${WORK_DIR}/install-security.out" 2>&1; then
  cat "${WORK_DIR}/install-security.out" >&2
  echo "PEAKGEAR_ERROR: Peak Gear security schema installation failed." >&2
  exit 1
fi
cat "${WORK_DIR}/install-security.out"
printf 'verified_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${MARKER_FILE}"
chmod 0600 "${MARKER_FILE}"
echo "Peak Gear security schema verified."
EOF
chmod 0700 "${OPC_HOME}/init/ensure-security-schema.sh"

cat > "${OPC_HOME}/init/start-application-services.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

cd /home/opc/ingestion

# The original user-podman unit runs setenv.sh as an ExecStartPre step. This
# helper replaces the installer's direct unit start, so it must preserve that
# prerequisite before any Compose command reads ingestion/.env.
if ! bash /home/opc/init/setenv.sh; then
  echo "PEAKGEAR_ERROR: Runtime environment generation failed before service startup." >&2
  exit 1
fi
if [[ ! -s /home/opc/ingestion/.env ]]; then
  echo "PEAKGEAR_ERROR: Runtime environment generation did not create /home/opc/ingestion/.env." >&2
  exit 1
fi
set -a
# shellcheck disable=SC1091
source /home/opc/ingestion/.env
set +a

build_service_image() {
  local service="$1"
  local label="$2"
  local build_status

  for attempt in 1 2; do
    echo "${label} image build attempt ${attempt} of 2."
    if timeout --signal=TERM --kill-after=60 1800 \
        /usr/local/bin/podman-compose -f compose.yml build "${service}"; then
      return 0
    else
      build_status="$?"
    fi
    if [[ "${build_status}" == "124" ]]; then
      echo "PEAKGEAR_ERROR: ${label} image build exceeded 30 minutes." >&2
    fi
    if [[ "${attempt}" != "2" ]]; then
      sleep 30
    fi
  done

  echo "PEAKGEAR_ERROR: ${label} image build failed after 2 attempts." >&2
  return 1
}

# Start the wallet unit directly. Its ExecStartPost runs adb-load.sh, so a
# wallet or schema-load failure is returned to the installer rather than being
# ignored through the user-podman Wants= dependency.
systemctl --user reset-failed adb-wallet.service adb-load.service || true
systemctl --user start adb-wallet.service
if [[ ! -s /home/opc/ingestion/.adb_load_done ]]; then
  echo "PEAKGEAR_ERROR: ADB wallet service completed without loading schema and data." >&2
  exit 1
fi
/home/opc/init/ensure-security-schema.sh
if [[ ! -s /home/opc/ingestion/.security_schema_done ]]; then
  echo "PEAKGEAR_ERROR: ADB security schema verification did not complete." >&2
  exit 1
fi
systemctl --user reset-failed pg-ai-data-catalog.service || true
systemctl --user start pg-ai-data-catalog.service
if [[ ! -s /home/opc/ingestion/.ai_data_catalog_done ]]; then
  echo "PEAKGEAR_ERROR: AI Data Catalog configuration did not complete." >&2
  exit 1
fi

[[ -s gravitino/dist/gravitino-iceberg-rest-server-0.7.0-incubating-SNAPSHOT-bin.zip ]] || {
  echo "PEAKGEAR_ERROR: The embedded Gravitino archive is missing." >&2
  exit 1
}
[[ -s ggsa/V1054826-01.zip ]] || {
  echo "PEAKGEAR_ERROR: The required GGSA archive was not downloaded." >&2
  exit 1
}

# Build the two large local images before starting the long-running Compose
# unit. This prevents systemd from reporting a healthy service while Compose
# is still blocked building GGSA, and keeps the archives in place until each
# image has been verified.
build_service_image gravitino "Gravitino"
/usr/local/bin/podman-compose -f compose.yml up --no-deps -d gravitino
build_service_image ggsa "GGSA"
systemctl --user start user-podman.service
EOF
chmod 0700 "${OPC_HOME}/init/start-application-services.sh"

SEEDER_DOCKERFILE="${INGESTION_DIR}/iceberg-seeder/Dockerfile"
[[ -f "${SEEDER_DOCKERFILE}" ]] || fail "Iceberg seeder Dockerfile is missing."
sed -i \
  -e 's/apt-get update/apt-get -o Acquire::Retries=5 update/' \
  -e 's/pip install --no-cache-dir /pip install --no-cache-dir --retries 10 --timeout 120 /' \
  "${SEEDER_DOCKERFILE}"
grep -Fq 'Acquire::Retries=5' "${SEEDER_DOCKERFILE}" \
  || fail "Unable to harden the Iceberg seeder operating-system package download."
grep -Fq -- '--retries 10 --timeout 120' "${SEEDER_DOCKERFILE}" \
  || fail "Unable to harden the Iceberg seeder Python package download."

# Preserve Resource Manager values when OCI custom metadata is intentionally
# absent. The rest of variable.sh remains unchanged.
sed -i '/export PUBLIC_IP=\$(curl/i PUBLIC_IP_FROM_ENV="${PUBLIC_IP:-}"' "${OPC_HOME}/init/variable.sh"
sed -i 's/export PUBLIC_IP="127.0.0.1"/export PUBLIC_IP="${PUBLIC_IP_FROM_ENV:-127.0.0.1}"/' "${OPC_HOME}/init/variable.sh"
sed -i '/export BUCKET_PAR=\$(curl/i BUCKET_PAR_FROM_ENV="${BUCKET_PAR:-}"' "${OPC_HOME}/init/variable.sh"
sed -i 's#export BUCKET_PAR="https://par.par.par"#export BUCKET_PAR="${BUCKET_PAR_FROM_ENV:-https://par.par.par}"#' "${OPC_HOME}/init/variable.sh"

chown -R opc:opc \
  "${OPC_HOME}/inst.resource-manager.sh" \
  "${OPC_HOME}/init" \
  "${INGESTION_DIR}" \
  "${OPC_ENV}"
# ZIP extraction on Windows-backed release branches does not preserve Unix
# modes. Restore ordinary runtime readability and script executability before
# systemd and non-root container users consume the payload.
find "${OPC_HOME}/init" "${INGESTION_DIR}" \
  -type d -exec chmod 0755 {} +
find "${OPC_HOME}/init" "${INGESTION_DIR}" \
  -type f -exec chmod 0644 {} +
find "${OPC_HOME}/init" "${INGESTION_DIR}" \
  -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0700 "${OPC_HOME}/inst.resource-manager.sh"
# The Resource Manager flow stages the source wallet elsewhere; adb-wallet.sh
# populates and secures this service-owned destination.
chmod 0700 "${WALLET_DIR}" \
  || fail "Unable to secure the ADB wallet directory."

set_phase "peakgear_install"
log "Running the Peak Gear installer. This is the longest deployment phase."
loginctl enable-linger opc
OPC_UID="$(id -u opc)"
systemctl start "user@${OPC_UID}.service"
install -m 0600 /dev/null "${INSTALLER_CONSOLE_LOG}"
# Do not pipe the installer through tee. Rootless Podman network helpers can
# inherit that pipe after the installer exits, which leaves cloud-init and the
# Resource Manager readiness waiter blocked even though the services are up.
if runuser -u opc -- env \
    HOME="${OPC_HOME}" \
    USER=opc \
    LOGNAME=opc \
    XDG_RUNTIME_DIR="/run/user/${OPC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${OPC_UID}/bus" \
    bash -lc "${OPC_HOME}/inst.resource-manager.sh" \
    >"${INSTALLER_CONSOLE_LOG}" 2>&1; then
  tail -n 40 "${INSTALLER_CONSOLE_LOG}" || true
  rm -f "${INSTALLER_CONSOLE_LOG}"
else
  installer_exit="$?"
  installer_stage="$(
    sed -n 's/^Installation failed during:[[:space:]]*//p' "${INSTALLER_CONSOLE_LOG}" \
      | tail -n 1 \
      | tr -cd '[:alnum:] ._:/()-' \
      | cut -c 1-160
  )"
  installer_error="$(
    raw_error="$(
      installer_log_tail \
        | grep -F 'PEAKGEAR_ERROR:' \
        | tail -n 1 \
        || true
    )"
    if [[ -z "${raw_error}" ]]; then
      raw_error="$(
        installer_log_tail \
          | grep -Eiv '^[[:space:]]*(Installation failed during:|Detailed output:|Iceberg seeder image build failed after|WARNING: Running pip as the .root. user)' \
          | grep -Ei 'error|failed|fatal|denied|timeout|timed out|no space|permission|certificate|tls|manifest|resolve|network|connection|unreachable|unable|could not|not found|exit status|non-zero' \
          | tail -n 1 \
          || true
      )"
    fi
    printf '%s\n' "${raw_error}" \
      | sed -E \
          -e 's#https?://[^[:space:]]+#<url-redacted>#g' \
          -e 's#(/p/)[A-Za-z0-9_-]{20,}#\1<redacted>#g' \
          -e 's#([Pp]assword|[Tt]oken|[Ss]ecret)([=:][^[:space:]]+)#\1=<redacted>#g' \
      | tr -cd '[:print:]' \
      | cut -c 1-180 \
      || true
  )"
  if [[ -n "${installer_stage}" && -n "${installer_error}" ]]; then
    fail "Peak Gear installer failed during ${installer_stage} (exit code ${installer_exit}). Last error: ${installer_error}. Use installer_log_command for details."
  fi
  if [[ -n "${installer_stage}" ]]; then
    fail "Peak Gear installer failed during ${installer_stage} (exit code ${installer_exit}). Use installer_log_command for details."
  fi
  fail "Peak Gear installer failed (exit code ${installer_exit}). Use installer_log_command for details."
fi

set_phase "database_verification"
wait_for_database_load

set_phase "service_verification"
wait_for_application_health
wait_for_http "http://127.0.0.1:${GRAVITINO_PORT}/iceberg/v1/config" "Gravitino Iceberg REST API" "240"
wait_for_streaming_analytics
wait_for_tcp "${GOLDENGATE_PORT}" "GoldenGate Studio" "240"
wait_for_tcp "${GOLDENGATE_API_PORT}" "GoldenGate runtime API" "240"

remove_build_secrets
write_status "SUCCEEDED" "${BOOTSTRAP_PHASE}" "RESOURCE_MANAGER_DEPLOYMENT_OK"
BOOTSTRAP_TERMINAL_STATE="SUCCEEDED"
log "RESOURCE_MANAGER_DEPLOYMENT_OK"
