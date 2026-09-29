#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ZIP="${1:-$(dirname "${ROOT_DIR}")/peakgear-ai-lakehouse-resource-manager-v26.zip}"

if grep -Fq 'tools_ingress_cidr' "${ROOT_DIR}/schema.yaml" \
    || grep -Eq 'variable[[:space:]]+"tools_ingress_cidr"' "${ROOT_DIR}/variables.tf" \
    || grep -Fq 'var.tools_ingress_cidr' "${ROOT_DIR}/network.tf"; then
  echo "The Peak Gear package must use one application source CIDR for the application and administration tools." >&2
  exit 1
fi

command -v zip >/dev/null 2>&1 || {
  echo "zip is required to build the Resource Manager archive." >&2
  exit 1
}
command -v unzip >/dev/null 2>&1 || {
  echo "unzip is required to verify the Resource Manager archive." >&2
  exit 1
}

mkdir -p "$(dirname "${OUTPUT_ZIP}")"
rm -f "${OUTPUT_ZIP}"

source_files=()
while IFS= read -r -d '' source_file; do
  source_files+=("${source_file}")
done < <(
  find "${ROOT_DIR}" -type f \
    \( -name '*.tf' -o -name '*.yaml' -o -name '*.yml' -o -name '*.json' \
      -o -name '*.md' -o -name '*.txt' -o -name '*.sh' -o -name '*.ps1' \
      -o -name '*.tpl' \) \
    -print0
)

if grep -InE -- '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' "${source_files[@]}"; then
  echo "Refusing to package source containing a private key." >&2
  exit 1
fi

non_artifact_files=()
for source_file in "${source_files[@]}"; do
  if [[ "$(basename "${source_file}")" != 'approved-artifacts.json' ]]; then
    non_artifact_files+=("${source_file}")
  fi
done

if grep -InE -- '/p/[A-Za-z0-9_-]{20,}/' "${non_artifact_files[@]}"; then
  echo "Refusing to package source containing an Object Storage pre-authenticated request." >&2
  exit 1
fi

if ! grep -Eq '"peakgear_build_archive_url"[[:space:]]*:[[:space:]]*"https://github\.com/oracle-livelabs/livestack/raw/refs/heads/main/aidatabaseindustrylivestack/terraform-ready-livestack/peakgear-ai-lakehouse/peakgear-build-dev\.zip"' "${ROOT_DIR}/approved-artifacts.json"; then
  echo "approved-artifacts.json does not contain the reviewed Peak Gear artifact location." >&2
  exit 1
fi

if ! grep -Eq '"peakgear_build_archive_sha256"[[:space:]]*:[[:space:]]*"7afe244845b0eaab381efe67bcc643cbb54f45d33498df5ecb1203c14fdf5117"' "${ROOT_DIR}/approved-artifacts.json"; then
  echo "approved-artifacts.json does not contain the reviewed Peak Gear checksum." >&2
  exit 1
fi

if ! grep -Eq '"gravitino_archive_url"[[:space:]]*:[[:space:]]*"https://objectstorage\.us-ashburn-1\.oraclecloud\.com/p/[A-Za-z0-9_-]+/n/c4u04/b/ai-lh-build/o/gravitino-iceberg-rest-server-0\.7\.0-incubating-SNAPSHOT-bin\.zip"' "${ROOT_DIR}/approved-artifacts.json"; then
  echo "approved-artifacts.json does not contain the reviewed Gravitino artifact location." >&2
  exit 1
fi

if grep -InE -- 'ocid1\.(tenancy|user|compartment|instance|image|subnet|vcn|networksecuritygroup|autonomousdatabase)\.[A-Za-z0-9._-]{20,}' "${source_files[@]}"; then
  echo "Refusing to package source containing a concrete OCI resource OCID." >&2
  exit 1
fi

if ! grep -Eq 'user_data[[:space:]]*=[[:space:]]*base64gzip[[:space:]]*\(' "${ROOT_DIR}/compute-app.tf"; then
  echo "compute-app.tf must gzip cloud-init user data to remain below the OCI instance metadata limit." >&2
  exit 1
fi

if ! grep -Fq 'variable "compartment_ocid"' "${ROOT_DIR}/variables.tf" \
    || ! grep -Fq '^ocid1\\.compartment\\.' "${ROOT_DIR}/variables.tf"; then
  echo "variables.tf must require a non-root OCI compartment for every Peak Gear resource." >&2
  exit 1
fi

if ! grep -Fq 'resource "oci_objectstorage_bucket" "ai_data_catalog"' "${ROOT_DIR}/object-storage.tf" \
    || ! grep -Fq 'PEAKGEAR_AI_CATALOG_BUCKET_NAME' "${ROOT_DIR}/object-storage.tf" \
    || ! grep -Fq 'terraform_data" "empty_lakehouse_bucket' "${ROOT_DIR}/object-storage.tf" \
    || ! grep -Eq 'when[[:space:]]*=[[:space:]]*destroy' "${ROOT_DIR}/object-storage.tf"; then
  echo "The Peak Gear package must create and clean its dedicated AI Data Catalog bucket." >&2
  exit 1
fi

if ! grep -Fq 'objectVersions' "${ROOT_DIR}/scripts/empty_object_storage_bucket.py" \
    || ! grep -Fq 'delete_object' "${ROOT_DIR}/scripts/empty_object_storage_bucket.py" \
    || ! grep -Fq 'PEAKGEAR_AI_CATALOG_BUCKET_NAME' "${ROOT_DIR}/scripts/empty_object_storage_bucket.py"; then
  echo "The Peak Gear destroy cleanup must delete all objects and versions from both deployment buckets." >&2
  exit 1
fi

if ! grep -Fq 'ai_data_catalog_url_b64' "${ROOT_DIR}/compute-app.tf" \
    || ! grep -Fq 'ai_data_catalog_warehouse_b64' "${ROOT_DIR}/compute-app.tf" \
    || ! grep -Fq 'ai_data_catalog_s3_endpoint_b64' "${ROOT_DIR}/compute-app.tf"; then
  echo "compute-app.tf must pass the AI Data Catalog connection contract to cloud-init." >&2
  exit 1
fi

if ! grep -Fq 'write_env_value "AI_DATA_CATALOG_ENABLED" "true"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'write_env_value "AI_DATA_CATALOG_REGISTER_STORAGE" "true"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'systemctl --user start pg-ai-data-catalog.service' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq '.ai_data_catalog_done' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must configure AI Data Catalog before application startup." >&2
  exit 1
fi

if ! grep -Fq '"ADB$TOOLS" = "AI_CAT"' "${ROOT_DIR}/autonomous-database.tf"; then
  echo "autonomous-database.tf must include the Peak Gear ADB tools tag." >&2
  exit 1
fi

if grep -Eq '\|[[:space:]]*tee[[:space:]]+"\$\{INSTALLER_CONSOLE_LOG\}"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear installer must not use a tee pipeline because long-lived Podman helpers can keep it open." >&2
  exit 1
fi

if ! grep -Eq '>[[:space:]]*"\$\{INSTALLER_CONSOLE_LOG\}"[[:space:]]+2>&1' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear installer must redirect output directly to its console log." >&2
  exit 1
fi

if ! grep -Fq 'ORACLE_USER_PWD: ${ORACLE_PWD:-oracle}' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must provide the database password expected by current ORDS images." >&2
  exit 1
fi

if ! grep -Fq 'ACTUAL_BUILD_SHA256="$(sha256sum "${BUILD_ZIP}"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'Peak Gear build bundle checksum does not match the reviewed release.' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must verify the reviewed runtime checksum." >&2
  exit 1
fi

if ! grep -Fq 'ords_has_user_password=false' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'The production compose file can add, rename, or reorder services' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must normalize the ORDS password field within the ORDS service." >&2
  exit 1
fi

if ! grep -Fq "grep -Eq '^ExecStartPre=.*\/usr\/local\/bin\/podman-compose" "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must accept the reviewed legacy and TLS-aware Compose cleanup steps." >&2
  exit 1
fi

if ! grep -Fq "sed -i '\#^ExecStartPre=.*\/usr\/local\/bin\/podman-compose" "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must remove the active Compose cleanup step before startup." >&2
  exit 1
fi

if ! grep -Fq 'Unable to normalize the Peak Gear service definition' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must normalize Windows line endings in the systemd unit." >&2
  exit 1
fi

if ! grep -Fq 'normalize_runtime_text_files' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'Peak Gear installer still contains Windows line endings.' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must normalize portable runtime text before execution." >&2
  exit 1
fi

if ! grep -Fq 'login-container-registry.sh --username' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'max_attempts=6' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'Container registry login failed after' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must retry transient container registry login failures." >&2
  exit 1
fi

if ! grep -Fq 'wait_for_streaming_analytics' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq '/api/streaming-analytics/status' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || grep -Fq 'wait_for_tcp "${GGSA_HTTPS_PORT}"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must verify GGSA and its ADB connection through the application status API." >&2
  exit 1
fi

if ! grep -Fq 'SC_SECURITY_CTX package and body must both be valid' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must verify the database security context package." >&2
  exit 1
fi

if ! grep -Fq 'repair_select_ai_package_detection' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'FROM all_objects' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear bootstrap must detect DBMS_CLOUD packages and synonyms visible to the application schema." >&2
  exit 1
fi
if grep -Fq 'python3.11 - "${service_file}"' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear Select AI package repair must not require Python before the installer runs." >&2
  exit 1
fi
if ! grep -Fq '\140SELECT DISTINCT object_name' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq 'SYNONYM\047)\140,' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear Select AI package repair must preserve the JavaScript template-literal delimiters." >&2
  exit 1
fi

if ! grep -Fq "index(\$0, end) { exit }" "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq -- '-- AUDIT POLICY (Unified Auditing)' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "The Peak Gear ADB security bootstrap must omit unsupported unified-audit policy creation." >&2
  exit 1
fi

startup_helper="$({
  sed -n \
    '/cat > "${OPC_HOME}\/init\/start-application-services.sh" <<'\''EOF'\''/,/^EOF$/p' \
    "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"
} || true)"
if [[ -z "${startup_helper}" ]]; then
  echo "Unable to locate the generated Peak Gear service startup helper." >&2
  exit 1
fi

startup_contract=(
  'bash /home/opc/init/setenv.sh'
  'source /home/opc/ingestion/.env'
  'systemctl --user start adb-wallet.service'
  '/home/opc/ingestion/.adb_load_done'
  '/home/opc/init/ensure-security-schema.sh'
  '/home/opc/ingestion/.security_schema_done'
  'systemctl --user start pg-ai-data-catalog.service'
  '/home/opc/ingestion/.ai_data_catalog_done'
  'build_service_image gravitino'
  'up --no-deps -d gravitino'
  'build_service_image ggsa'
  'systemctl --user start user-podman.service'
)
previous_line=0
for step in "${startup_contract[@]}"; do
  line="$(grep -nF -- "${step}" <<<"${startup_helper}" | head -n 1 | cut -d: -f1)"
  if [[ -z "${line}" ]]; then
    echo "Peak Gear service startup helper is missing required step: ${step}" >&2
    exit 1
  fi
  if (( line <= previous_line )); then
    echo "Peak Gear service startup helper has an invalid dependency order at: ${step}" >&2
    exit 1
  fi
  previous_line="${line}"
done

if ! grep -Fq -- '-type d -exec chmod 0755 {} +' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq -- '-type f -exec chmod 0644 {} +' "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh" \
    || ! grep -Fq -- "-type f -name '*.sh' -exec chmod 0755 {} +" "${ROOT_DIR}/scripts/bootstrap_lakehouse_vm.sh"; then
  echo "Peak Gear bootstrap must restore readable runtime files and executable shell scripts after ZIP extraction." >&2
  exit 1
fi

(
  cd "${ROOT_DIR}"
  zip -qr "${OUTPUT_ZIP}" . \
    -x '.terraform/*' \
    -x '.terraform.lock.hcl' \
    -x '.terraform.tfstate.lock.info' \
    -x '.oci/*' \
    -x '*/.oci/*' \
    -x 'dist/*' \
    -x '*/.DS_Store' \
    -x '*.tfstate' \
    -x '*.tfstate.*' \
    -x '*.tfplan' \
    -x '*.tfvars' \
    -x '*.tfvars.json' \
    -x 'crash.log' \
    -x 'crash.*.log' \
    -x '*.generated.zip' \
    -x '*wallet*.zip' \
    -x '*wallet*.b64' \
    -x '*.pem' \
    -x '*.key' \
    -x '*.p12' \
    -x '*.pfx' \
    -x '*.jks' \
    -x '.env' \
    -x '*/.env'
)

unzip -tq "${OUTPUT_ZIP}" >/dev/null

if unzip -Z1 "${OUTPUT_ZIP}" | grep -Eq '(^\.terraform/|(^|/)\.terraform\.tfstate\.lock\.info$|(^|/)\.oci/|^dist/|(^|/)\.DS_Store$|\.tfstate(\.|$)|\.tfplan$|\.tfvars(\.json)?$|(^|/)crash(\..*)?\.log$|\.generated\.zip$|wallet.*\.(zip|b64)$|\.pem$|\.key$|\.(p12|pfx|jks)$|(^|/)\.env$)'; then
  echo "Refusing to release an archive containing a generated, local, or sensitive artifact." >&2
  rm -f "${OUTPUT_ZIP}"
  exit 1
fi

required_entries=(
  'approved-artifacts.json'
  'artifacts.tf'
  'schema.yaml'
  'versions.tf'
  'main.tf'
  'variables.tf'
  'cloud-init/app.yaml'
  'scripts/bootstrap_lakehouse_vm.sh'
  'scripts/empty_object_storage_bucket.py'
  'scripts/wait_for_bootstrap_callback.sh'
)

for required_entry in "${required_entries[@]}"; do
  if ! unzip -Z1 "${OUTPUT_ZIP}" | grep -Fxq "${required_entry}"; then
    echo "Resource Manager archive is missing required entry: ${required_entry}" >&2
    rm -f "${OUTPUT_ZIP}"
    exit 1
  fi
done

echo "Created and verified ${OUTPUT_ZIP}"
