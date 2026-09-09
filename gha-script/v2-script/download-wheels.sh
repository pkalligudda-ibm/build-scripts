#!/usr/bin/env bash
# download-wheels.sh — Fetch PowerCore wheels and powercore-config.env from COS.
#
# Usage:
#   download-wheels.sh <api_key> <powercore_version>
#
# Output: powercore-wheels/ directory and powercore-config.env in CWD
set -euo pipefail

API_KEY="${1:?api_key argument required}"
POWERCORE_VERSION="${2:?powercore_version argument required}"

BUCKET_URL="https://s3.us.cloud-object-storage.appdomain.cloud/powercore-wheels-staging"
LIST_URL="${BUCKET_URL}?list-type=2&prefix=powercore"

echo "--- Download config ---"
echo "  POWERCORE_VERSION : ${POWERCORE_VERSION}"
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

echo "--- Listing COS objects (version: ${POWERCORE_VERSION}) ---"
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

installer_key="powercore_installer-${POWERCORE_VERSION}-py3-none-any.whl"
if ! printf '%s\n' "$list_response" | tr '<' '\n' | grep -Fx "Key>${installer_key}" > /dev/null; then
  echo "ERROR: Installer wheel '${installer_key}' was not found in COS."
  exit 1
fi

matched_keys="${installer_key}"
echo "--- Downloading installer wheel for version ${POWERCORE_VERSION} ---"
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
