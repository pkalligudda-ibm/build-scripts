#!/usr/bin/env bash
# collect_scan_results.sh — Download per-Python-version scan result tarballs
# from the powercore-builds COS bucket and extract them into a single merged
# v2-scan-workspace, with clear log output for each version.
#
# Usage:
#   collect_scan_results.sh <package_name> <package_version> <workspace_dir>
#
# Required env vars:
#   GHA_CURRENCY_SERVICE_ID_API_KEY  — IBM Cloud IAM API key
#
# For each Python version (3.12, 3.13, 3.14) it downloads:
#   powercore-builds/<package_name>/<package_version>/<package_name>-<package_version>-v2-scan-result-<py_ver>.tar.gz
# and extracts it into <workspace_dir>.
#
# Exits 1 if none of the three tarballs were found (nothing to process).
set -euo pipefail

PACKAGE_NAME="${1:?package_name required}"
PACKAGE_VERSION="${2:?package_version required}"
WORKSPACE_DIR="${3:-v2-scan-workspace}"

: "${GHA_CURRENCY_SERVICE_ID_API_KEY:?GHA_CURRENCY_SERVICE_ID_API_KEY is required}"

mkdir -p "${WORKSPACE_DIR}/wheel"

echo "============================================================"
echo "  V2 Scan Results — Downloading & Collecting Artifacts"
echo "  Package  : ${PACKAGE_NAME}"
echo "  Version  : ${PACKAGE_VERSION}"
echo "  Workspace: ${WORKSPACE_DIR}"
echo "  Bucket   : powercore-builds"
echo "============================================================"

# Obtain IAM token once and reuse across all downloads
echo "--- Fetching IAM token ---"
token_request=$(curl -sS -X POST https://iam.cloud.ibm.com/identity/token \
  -H "content-type: application/x-www-form-urlencoded" \
  -H "accept: application/json" \
  -d "grant_type=urn%3Aibm%3Aparams%3Aoauth%3Agrant-type%3Aapikey&apikey=${GHA_CURRENCY_SERVICE_ID_API_KEY}")

if [[ $(echo "${token_request}" | jq -r '.errorCode') != "null" ]]; then
  echo "ERROR: IAM token request failed. Response: ${token_request}"
  exit 1
fi
TOKEN=$(echo "${token_request}" | jq -r '.access_token')
if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
  echo "ERROR: IAM token missing from response."
  exit 1
fi
echo "OK: IAM token obtained"

BUCKET_URL="https://s3.us.cloud-object-storage.appdomain.cloud/powercore-builds"
found_any=false

for PY_VER in 3.12 3.13 3.14; do
  TARBALL="${PACKAGE_NAME}-${PACKAGE_VERSION}-v2-scan-result-${PY_VER}.tar.gz"
  OBJECT_KEY="${PACKAGE_NAME}/${PACKAGE_VERSION}/${TARBALL}"

  echo ""
  echo "------------------------------------------------------------"
  echo "  Python ${PY_VER}"
  echo "  Object : ${OBJECT_KEY}"
  echo "------------------------------------------------------------"

  http_code=$(curl -sS -w "%{http_code}" -o "${TARBALL}" \
    -H "Authorization: bearer ${TOKEN}" \
    "${BUCKET_URL}/${OBJECT_KEY}")

  if [[ "${http_code}" == "200" ]]; then
    echo "  Downloaded OK."
    tar -xzf "${TARBALL}" --strip-components=1 -C "${WORKSPACE_DIR}"
    rm -f "${TARBALL}"
    found_any=true
    echo "  Extracted successfully."

    echo ""
    echo "  Wheel scan files:"
    PY_TAG="cp${PY_VER/./}"
    wheel_files=$(find "${WORKSPACE_DIR}/wheel" -maxdepth 1 -name "*${PY_TAG}*" 2>/dev/null | sort)
    if [ -n "${wheel_files}" ]; then
      while IFS= read -r f; do
        SIZE=$(du -sh "$f" | cut -f1)
        printf "    %-8s  %s\n" "${SIZE}" "$(basename "$f")"
      done <<< "${wheel_files}"
    else
      echo "    (none)"
    fi

    echo ""
    echo "  Source scan files:"
    source_files=$(find "${WORKSPACE_DIR}/source" -maxdepth 1 -type f 2>/dev/null | sort)
    if [ -n "${source_files}" ]; then
      while IFS= read -r f; do
        SIZE=$(du -sh "$f" | cut -f1)
        printf "    %-8s  %s\n" "${SIZE}" "$(basename "$f")"
      done <<< "${source_files}"
    else
      echo "    (none)"
    fi

  elif [[ "${http_code}" == "404" ]]; then
    rm -f "${TARBALL}"
    echo "  SKIPPED — not found in COS (job may have been skipped or failed)."
  else
    rm -f "${TARBALL}"
    echo "  ERROR: COS GET failed (HTTP ${http_code})."
    exit 1
  fi
done

echo ""
echo "============================================================"
echo "  All ScanCode JSON files collected:"
echo "============================================================"
scancode_files=$(find "${WORKSPACE_DIR}/wheel" -maxdepth 1 \
  -name '*_output.json' ! -name '*_grype_output.json' 2>/dev/null | sort)
if [ -n "${scancode_files}" ]; then
  while IFS= read -r f; do
    SIZE=$(du -sh "$f" | cut -f1)
    printf "  %-8s  %s\n" "${SIZE}" "$(basename "$f")"
  done <<< "${scancode_files}"
else
  echo "  (none)"
fi
echo "============================================================"

if [ "${found_any}" = "false" ]; then
  echo ""
  echo "ERROR: No scan result tarballs were found in COS. Cannot proceed." >&2
  exit 1
fi
