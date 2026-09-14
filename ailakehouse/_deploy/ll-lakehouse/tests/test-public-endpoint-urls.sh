#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETENV_FILE="${PROJECT_ROOT}/init/setenv.sh"
COMPOSE_FILE="${PROJECT_ROOT}/ingestion/compose.yml"
ICEBERG_ROUTE_FILE="${PROJECT_ROOT}/ingestion/backend/routes/icebergCatalog.js"
STREAMING_ROUTE_FILE="${PROJECT_ROOT}/ingestion/backend/routes/streamingAnalytics.js"
CDC_SETUP_FILE="${PROJECT_ROOT}/ingestion/backend/lib/customerCdcSetup.js"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_text() {
  local file="$1"
  local expected="$2"
  grep -qF -- "${expected}" "${file}" || fail "Missing expected text in ${file}: ${expected}"
}

node --check "${ICEBERG_ROUTE_FILE}"
node --check "${STREAMING_ROUTE_FILE}"
node --check "${CDC_SETUP_FILE}"

require_text "${SETENV_FILE}" 'OSA_PUBLIC_URL=${OSA_PUBLIC_URL:-https://${PUBLIC_ENDPOINT_HOST}:8085/osa/index.html}'
require_text "${SETENV_FILE}" 'GOLDENGATE_PUBLIC_URL=${GOLDENGATE_PUBLIC_URL:-https://${PUBLIC_ENDPOINT_HOST}:8501}'
require_text "${SETENV_FILE}" 'DATA_TRANSFORMS_ICEBERG_PUBLIC_HOST=${DATA_TRANSFORMS_ICEBERG_PUBLIC_HOST:-${PUBLIC_ENDPOINT_HOST}}'
require_text "${COMPOSE_FILE}" 'PUBLIC_HOST: ${PUBLIC_HOST:-}'
require_text "${COMPOSE_FILE}" 'PUBLIC_IP: ${PUBLIC_IP:-}'
require_text "${COMPOSE_FILE}" 'DATA_TRANSFORMS_ICEBERG_PUBLIC_HOST: ${DATA_TRANSFORMS_ICEBERG_PUBLIC_HOST:-}'

# The route itself should prefer the external FQDN and use the VM IP only when
# no FQDN has been supplied. Mock Express because this repository's route
# dependencies normally arrive only in the container image.
node - "${ICEBERG_ROUTE_FILE}" <<'NODE'
const assert = require('node:assert/strict');
const Module = require('node:module');
const originalLoad = Module._load;
Module._load = function mockExpress(request, parent, isMain) {
  if (request === 'express') return { Router: () => ({ get() {} }) };
  return originalLoad.call(this, request, parent, isMain);
};

const { _private } = require(process.argv[2]);
const base = { GRAVITINO_REST_PORT: '1525' };

assert.equal(
  _private.deriveIcebergRestUrl({
    ...base,
    PUBLIC_HOST: 'llenv00608.livelabsenv3.oracle.com',
    PUBLIC_IP: '138.2.60.131',
  }),
  'http://llenv00608.livelabsenv3.oracle.com:1525/iceberg'
);
assert.equal(
  _private.deriveIcebergRestUrl({ ...base, PUBLIC_IP: '138.2.60.131' }),
  'http://138.2.60.131:1525/iceberg'
);
NODE

echo "Public endpoint URL checks passed."
