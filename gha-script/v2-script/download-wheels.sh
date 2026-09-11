#!/usr/bin/env bash
# download-wheels.sh — Fetch PowerCore wheels and powercore-config.env from COS.
#
# Usage:
#   download-wheels.sh <api_key> <arch>
#
# Output: powercore-wheels/ directory and powercore-config.env in CWD
set -euo pipefail

API_KEY="${1:?api_key argument required}"
ARCH="${2:-ppc64le}"
CONFIG_URL="https://s3.us.cloud-object-storage.appdomain.cloud/powercore-wheels-staging/powercore-config.env"

BUCKET_URL="https://s3.us.cloud-object-storage.appdomain.cloud/powercore-wheels-staging"
LIST_URL="${BUCKET_URL}?list-type=2&prefix=${ARCH}/"

echo "--- Download config ---"
echo "  CONFIG_URL        : ${CONFIG_URL}"
echo "  ARCH              : ${ARCH}"
echo "  BUCKET_URL        : ${BUCKET_URL}"

echo "--- Fetching IAM token ---"
token_request=$(curl -sS -X POST https://iam.cloud.ibm.com/identity/token \
  -H "content-type: application/x-www-form-urlencoded" \
  -H "accept: application/json" \
  -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${API_KEY}")

if [[ $(echo "$token_request" | jq -r '.errorCode') != "null" ]]; then
  echo "ERROR: IAM token request failed. Response: $token_request"
  exit 1
fi

token=$(echo "$token_request" | jq -r '.access_token')
if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERROR: IAM token missing from response: $token_request"
  exit 1
fi
echo "OK: IAM token obtained"

echo "--- Listing COS objects ---"
echo "  List URL: ${LIST_URL}"

list_response=$(curl -sS -H "Authorization: bearer $token" "${LIST_URL}")
curl_status=$?
if [[ $curl_status -ne 0 ]]; then
  echo "ERROR: Failed to list wheels from COS. curl exit code: ${curl_status}"
  exit 1
fi

if echo "$list_response" | grep -q "<Error>"; then
  echo "ERROR: COS list request returned an error response:"
  echo "$list_response"
  exit 1
fi

POWERCORE_VERSION=$(curl -fsS -H "Authorization: bearer $token" "$CONFIG_URL" \
  | sed -n 's/^POWERCORE_WHEEL_VERSION=//p' \
  | head -1 \
  | tr -d '"' \
  | xargs)
if [ -z "$POWERCORE_VERSION" ]; then
  echo "ERROR: POWERCORE_WHEEL_VERSION is missing from powercore-config.env"
  exit 1
fi

echo "  POWERCORE_WHEEL_VERSION: ${POWERCORE_VERSION}"

listed_keys=$(printf '%s\n' "$list_response" \
  | grep -oE '<Key>[^<]+</Key>' \
  | sed -e 's#<Key>##' -e 's#</Key>##')

required_wheels=(
  powercore_installer
  powercore_config
  powercore_database
  powercore_preprocess
  powercore_shallow_scan
  powercore_deep_scan
  powercore_postprocess
  powercore_bookkeeping
  powercore_workflow
)

matched_keys=""
for wheel_name in "${required_wheels[@]}"; do
  wheel_key="${ARCH}/${wheel_name}-${POWERCORE_VERSION}-py3-none-any.whl"
  if ! printf '%s\n' "$listed_keys" | grep -Fxq "$wheel_key"; then
    echo "ERROR: Required PowerCore wheel was not found in COS: ${wheel_key}"
    exit 1
  fi
  matched_keys+="${wheel_key}"$'\n'
done

echo "--- Downloading required PowerCore wheels for version ${POWERCORE_VERSION} ---"
mkdir -p powercore-wheels
while IFS= read -r wheel_key; do
  [[ -z "$wheel_key" ]] && continue
  echo "  Downloading: ${wheel_key}"
  if ! curl -fsS -H "Authorization: bearer $token" \
    -o "powercore-wheels/$(basename "$wheel_key")" \
    "${BUCKET_URL}/${wheel_key}"; then
    echo "ERROR: Failed to download wheel '${wheel_key}'"
    exit 1
  fi
  echo "    OK: $(ls -lh "powercore-wheels/$(basename "$wheel_key")" | awk '{print $5}')"
done <<< "$matched_keys"

echo "--- Wheel download complete ---"

echo "--- Downloading powercore-config.env ---"
if ! curl -fsS -H "Authorization: bearer $token" \
  -o "powercore-config.env" \
  "${BUCKET_URL}/powercore-config.env"; then
  echo "ERROR: Failed to download powercore-config.env"
  echo "  Tried: ${BUCKET_URL}/powercore-config.env"
  exit 1
fi
echo "--- powercore-config.env (safe view — key names only) ---"
grep -E '^[A-Z_]+=' powercore-config.env | sed 's/=.*/=<hidden>/' || true
