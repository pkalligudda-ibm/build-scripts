#!/usr/bin/env bash
# fetch-and-install-powercore.sh — Retrieve powercore-config.env from IBM Cloud Secrets Manager,
# inject/override POWERCORE_WHEEL_VERSION and GITHUB_TOKEN, download the powercore_installer wheel from COS,
# and install PowerCore. Optionally destroy the setup with --destroy.
#
# Usage:
#   ./fetch-and-install-powercore.sh \
#       --api-key <IAM_API_KEY> \
#       --powercore-version <VERSION> \
#       --github-token <GITHUB_TOKEN> \
#       --env <local|staging>
#
#   Destroy mode (removes all PowerCore artefacts, no other flags required):
#   ./fetch-and-install-powercore.sh --destroy
#
# Alternatively:
#   ./fetch-and-install-powercore.sh <API_KEY> <VERSION> [GITHUB_TOKEN]
#
# Environment variables:
#   IBMCLOUD_API_KEY / IAM_API_KEY / GHA_CURRENCY_SERVICE_ID_API_KEY
#   POWERCORE_VERSION / POWERCORE_WHEEL_VERSION
#   GITHUB_TOKEN / GH_TOKEN
#   POWERCORE_ENVIRONMENT  (local | staging — must be provided for install)
set -euo pipefail

# ── Secrets Manager & COS Configuration ──────────────────────────────────────
SM_INSTANCE_ID="e04a4ffa-e1fc-419f-85ec-5dcb512d2d1c"
SM_REGION="us-east"
SM_SECRET_ID_STAGING="7384e6e0-3ce1-aaca-e68a-bbfe5e2cf010"
SM_SECRET_ID_LOCAL="5eab98cb-9685-0b86-896c-390f0b82391a"
COS_BUCKET_URL="https://s3.us.cloud-object-storage.appdomain.cloud/powercore-wheels-staging"

API_KEY="${IBMCLOUD_API_KEY:-${IAM_API_KEY:-${GHA_CURRENCY_SERVICE_ID_API_KEY:-}}}"
POWERCORE_VERSION_INPUT="${POWERCORE_VERSION:-${POWERCORE_WHEEL_VERSION:-}}"
GITHUB_TOKEN_INPUT="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
POWERCORE_ENV_INPUT="${POWERCORE_ENVIRONMENT:-}"
DESTROY_MODE=false

# Parse flags or positional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)
      API_KEY="$2"
      shift 2
      ;;
    --powercore-version)
      POWERCORE_VERSION_INPUT="$2"
      shift 2
      ;;
    --github-token)
      GITHUB_TOKEN_INPUT="$2"
      shift 2
      ;;
    --env)
      POWERCORE_ENV_INPUT="$2"
      shift 2
      ;;
    --destroy)
      DESTROY_MODE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 --api-key <KEY> --powercore-version <VERSION> --github-token <TOKEN> --env <local|staging>"
      echo "   or: $0 --destroy"
      echo "   or: $0 <API_KEY> <VERSION> [GITHUB_TOKEN]"
      echo ""
      echo "  --env local    : Use secret 'powercore-config-secrets-local' from Secrets Manager"
      echo "  --env staging  : Use secret 'powercore-config-secrets-staging' from Secrets Manager"
      echo "  --destroy      : Remove PowerCore installation and all local artefacts (no other flags needed)"
      exit 0
      ;;
    *)
      if [[ -z "${API_KEY}" ]]; then
        API_KEY="$1"
      elif [[ -z "${POWERCORE_VERSION_INPUT}" ]]; then
        POWERCORE_VERSION_INPUT="$1"
      elif [[ -z "${GITHUB_TOKEN_INPUT}" ]]; then
        GITHUB_TOKEN_INPUT="$1"
      else
        echo "ERROR: Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# ── Destroy mode ─────────────────────────────────────────────────────────────
if [[ "${DESTROY_MODE}" == "true" ]]; then
  echo "=== DESTROY MODE: Removing PowerCore setup ==="

  echo "--- Stopping and removing PowerCore services ---"
  if command -v powercore-uninstall &>/dev/null; then
    sudo powercore-uninstall --non-interactive -y 2>/dev/null || true
  elif command -v powercore &>/dev/null; then
    sudo powercore stop 2>/dev/null || true
  fi

  echo "--- Removing PowerCore Python packages ---"
  PY_CMD=$(command -v python3.12 || command -v python3 || true)
  if [[ -n "${PY_CMD}" ]]; then
    sudo "${PY_CMD}" -m pip uninstall -y powercore powercore_installer 2>/dev/null || true
  fi

  echo "--- Removing powercore-install / powercore binaries ---"
  for bin in /usr/local/bin/powercore-install /usr/bin/powercore-install \
             /usr/local/bin/powercore /usr/bin/powercore; do
    sudo rm -f "${bin}" && echo "  Removed: ${bin}" || true
  done

  echo "--- Removing local artefacts ---"
  rm -f powercore-config.env
  rm -rf powercore-wheels/
  echo "  Removed: powercore-config.env, powercore-wheels/"

  echo "=== PowerCore Destroy Complete ==="
  exit 0
fi

# ── Validation (install path only) ───────────────────────────────────────────
if [[ -z "${API_KEY}" ]]; then
  echo "ERROR: IBM Cloud IAM API key is required (--api-key <KEY> or set IAM_API_KEY)"
  exit 1
fi
if [[ -z "${POWERCORE_VERSION_INPUT}" ]]; then
  echo "ERROR: PowerCore wheel version is required (--powercore-version <VERSION> or set POWERCORE_WHEEL_VERSION)"
  exit 1
fi
if [[ -z "${GITHUB_TOKEN_INPUT}" ]]; then
  echo "ERROR: GitHub token is required (--github-token <TOKEN> or set GITHUB_TOKEN / GH_TOKEN)"
  exit 1
fi
if [[ -z "${POWERCORE_ENV_INPUT}" ]]; then
  echo "ERROR: Environment is required (--env <local|staging> or set POWERCORE_ENVIRONMENT)"
  exit 1
fi

# Resolve secret ID based on environment
case "${POWERCORE_ENV_INPUT}" in
  local)
    SM_SECRET_ID="${SM_SECRET_ID_LOCAL}"
    echo "INFO: Environment=local — using secret 'powercore-config-secrets-local' (${SM_SECRET_ID})"
    ;;
  staging)
    SM_SECRET_ID="${SM_SECRET_ID_STAGING}"
    echo "INFO: Environment=staging — using secret 'powercore-config-secrets-staging' (${SM_SECRET_ID})"
    ;;
  *)
    echo "ERROR: Invalid --env value '${POWERCORE_ENV_INPUT}'. Must be 'local' or 'staging'."
    exit 1
    ;;
esac

echo "=== 1. Authenticating with IBM Cloud IAM ==="
token_request=$(curl -sS -X POST https://iam.cloud.ibm.com/identity/token \
  -H "content-type: application/x-www-form-urlencoded" \
  -H "accept: application/json" \
  -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${API_KEY}")

if [[ $(echo "${token_request}" | jq -r '.errorCode // empty') != "" ]]; then
  echo "ERROR: IAM token request failed."
  exit 1
fi

token=$(echo "${token_request}" | jq -r '.access_token // empty')
if [[ -z "${token}" ]]; then
  echo "ERROR: IAM access token could not be retrieved."
  exit 1
fi
echo "OK: IAM access token obtained"

echo "=== 2. Fetching Secret from Secrets Manager ==="
SM_API_URL="https://${SM_INSTANCE_ID}.${SM_REGION}.secrets-manager.appdomain.cloud/api/v2/secrets/${SM_SECRET_ID}"
echo "  Fetching secret ID: ${SM_SECRET_ID}"
echo "  Instance: ${SM_INSTANCE_ID} (${SM_REGION})"

secret_response=$(curl -sS -X GET "${SM_API_URL}" \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/json")

if echo "${secret_response}" | grep -q '"errors"'; then
  echo "ERROR: Failed to retrieve secret from Secrets Manager:"
  echo "${secret_response}" | jq -r '.errors[]?.message // .' 2>/dev/null || echo "${secret_response}"
  exit 1
fi

echo "=== 3. Generating powercore-config.env ==="
python3 -c "
import json, sys

raw = sys.stdin.read()
doc = json.loads(raw)
version_input = sys.argv[1]

# Support multiple Secrets Manager KV response structures
kv_data = None
if 'data' in doc and isinstance(doc['data'], dict):
    if 'data' in doc['data'] and isinstance(doc['data']['data'], dict):
        kv_data = doc['data']['data']
    else:
        kv_data = doc['data']
elif 'resources' in doc and len(doc['resources']) > 0:
    res = doc['resources'][0]
    kv_data = res.get('secret_data') or res.get('data') or {}
elif 'secret_data' in doc and isinstance(doc['secret_data'], dict):
    kv_data = doc['secret_data']

if not kv_data or not isinstance(kv_data, dict):
    sys.stderr.write('ERROR: Could not parse key-value data dictionary from Secrets Manager response\n')
    sys.exit(1)

api_key_input = sys.argv[3] if len(sys.argv) > 3 else ''

# Set or override POWERCORE_WHEEL_VERSION and GITHUB_TOKEN
kv_data['POWERCORE_WHEEL_VERSION'] = version_input
if len(sys.argv) > 2 and sys.argv[2]:
    kv_data['GITHUB_TOKEN'] = sys.argv[2]

# Map user-provided IAM API key to required downstream service variables
if api_key_input:
    kv_data['COS_API_KEY'] = api_key_input
    kv_data['ICR_API_KEY'] = api_key_input
    kv_data['IBMCLOUD_API_KEY'] = api_key_input
    kv_data['IAM_WRITER_API_KEY'] = api_key_input

with open('powercore-config.env', 'w') as f:
    for k, v in kv_data.items():
        val_str = str(v)
        f.write(f'{k}={val_str}\n')
" "${POWERCORE_VERSION_INPUT}" "${GITHUB_TOKEN_INPUT}" "${API_KEY}" <<< "${secret_response}"

if [[ ! -f powercore-config.env ]]; then
  echo "ERROR: powercore-config.env was not generated"
  exit 1
fi

echo "  Generated powercore-config.env successfully."
echo "--- powercore-config.env (safe view — keys only) ---"
grep -E '^[A-Z_]+=' powercore-config.env | sed 's/=.*/=<hidden>/' || true

POWERCORE_VERSION=$(sed -n 's/^POWERCORE_WHEEL_VERSION=//p' powercore-config.env | head -1 | tr -d '"' | tr -d "'" | xargs)
echo "  Target POWERCORE_WHEEL_VERSION: ${POWERCORE_VERSION}"

echo "=== 4. Fetching powercore_installer wheel from COS ==="
mkdir -p powercore-wheels
installer_wheel_name="powercore_installer-${POWERCORE_VERSION}-py3-none-any.whl"
echo "  Downloading: ${installer_wheel_name}"

if ! curl -fsS -H "Authorization: bearer ${token}" \
  -o "powercore-wheels/${installer_wheel_name}" \
  "${COS_BUCKET_URL}/${installer_wheel_name}"; then
  echo "ERROR: Failed to download wheel '${installer_wheel_name}' from COS"
  exit 1
fi

echo "  OK: $(ls -lh "powercore-wheels/${installer_wheel_name}" | awk '{print $5}')"

echo "=== 5. Installing PowerCore ==="
PY_CMD=$(command -v python3.12 || command -v python3 || true)
if [[ -z "${PY_CMD}" ]]; then
  echo "ERROR: No python3 found on PATH"
  exit 1
fi
echo "--- Using Python: ${PY_CMD} ($(${PY_CMD} --version)) ---"
"${PY_CMD}" -m pip install --upgrade pip --user --quiet 2>/dev/null || true

echo "--- Installing powercore_installer wheel ---"
echo "  Installing from: powercore-wheels/${installer_wheel_name}"
sudo "${PY_CMD}" -m pip install "powercore-wheels/${installer_wheel_name}" --force-reinstall --no-warn-script-location

echo "--- Locating powercore-install binary ---"
INSTALL_BIN=""
for path in /usr/local/bin/powercore-install /usr/bin/powercore-install ~/.local/bin/powercore-install; do
  if sudo test -x "${path}"; then
    INSTALL_BIN="${path}"
    break
  fi
done

if [[ -z "${INSTALL_BIN}" ]]; then
  INSTALL_BIN=$(command -v powercore-install || sudo which powercore-install 2>/dev/null || true)
fi

if [[ -z "${INSTALL_BIN}" ]]; then
  echo "ERROR: powercore-install executable not found"
  exit 1
fi

echo "--- Running powercore-install (${INSTALL_BIN}) ---"
sudo env "PATH=/usr/local/bin:/usr/bin:/bin:$PATH" "${INSTALL_BIN}" --config "$(pwd)/powercore-config.env" --non-interactive

echo "=== PowerCore Installation Complete ==="
sudo "${PY_CMD}" -m pip list | grep -i powercore || true

echo "--- Removing powercore-config.env ---"
rm -f powercore-config.env
echo "  Removed: powercore-config.env"
