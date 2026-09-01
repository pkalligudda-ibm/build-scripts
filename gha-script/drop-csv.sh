#!/usr/bin/env bash
# drop-csv.sh — Write a single-row CSV for the given package into the
# 03-preprocess inbox so the PowerCore pipeline picks it up.
#
# Usage:
#   drop-csv.sh <powercore_runtime> <run_id> \
#     <package_name> <package_version> <technology> \
#     <technology_version> <ubi_version>
#
# Outputs (to $GITHUB_OUTPUT):
#   csv_name           — filename only, e.g. brotlipy-12345678.csv
#   powercore_runtime  — the runtime path passed as $1 (echo-through for polling step)
set -euo pipefail

POWERCORE_RUNTIME="${1:?powercore_runtime required}"
RUN_ID="${2:?run_id required}"
PACKAGE_NAME="${3:?package_name required}"
PACKAGE_VERSION="${4:?package_version required}"
TECHNOLOGY="${5:?technology required}"
TECHNOLOGY_VERSION="${6:-}"
UBI_VERSION="${7:-ubi9}"

echo "--- Package parameters ---"
echo "  PACKAGE_NAME       = ${PACKAGE_NAME}"
echo "  PACKAGE_VERSION    = ${PACKAGE_VERSION}"
echo "  TECHNOLOGY         = ${TECHNOLOGY}"
echo "  TECHNOLOGY_VERSION = ${TECHNOLOGY_VERSION}"
echo "  UBI_VERSION        = ${UBI_VERSION}"
echo "  POWERCORE_RUNTIME  = ${POWERCORE_RUNTIME}"

INBOX_DIR="${POWERCORE_RUNTIME}/queues/03-preprocess/inbox"

echo "--- Verifying inbox directory ---"
if ! sudo -u powercore test -d "${INBOX_DIR}"; then
  echo "ERROR: inbox does not exist: ${INBOX_DIR}"
  echo "--- Runtime tree (maxdepth 4) ---"
  sudo -u powercore find "${POWERCORE_RUNTIME}" -maxdepth 4 | sort || true
  exit 1
fi
echo "Inbox OK: ${INBOX_DIR}"

# Filename includes package name + GHA run ID so parallel runs don't collide.
CSV_NAME="${PACKAGE_NAME}-${RUN_ID}.csv"
CSV_PATH="${INBOX_DIR}/${CSV_NAME}"

printf '%s\n' \
  "package_name,package_version,technology,technology_version,ubi_version" \
  "${PACKAGE_NAME},${PACKAGE_VERSION},${TECHNOLOGY},${TECHNOLOGY_VERSION},${UBI_VERSION}" \
  | sudo -u powercore tee "${CSV_PATH}" > /dev/null

echo "--- CSV written: ${CSV_PATH} ---"
sudo -u powercore cat "${CSV_PATH}"

echo "--- Inbox after drop ---"
sudo -u powercore ls -lh "${INBOX_DIR}"

# Export for the polling step
echo "csv_name=${CSV_NAME}"                    >> "${GITHUB_OUTPUT}"
echo "powercore_runtime=${POWERCORE_RUNTIME}" >> "${GITHUB_OUTPUT}"
