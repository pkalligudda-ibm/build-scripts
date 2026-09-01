#!/usr/bin/env bash
# parse-package-json.sh — Validate package_json input, extract fields, write variable.sh
#
# Usage:
#   parse-package-json.sh <package_json> \
#     <validate_build_script_v2> <wheel_build> <build_docker> <powercore_version>
#
# Output: variable.sh written to CWD
set -euo pipefail

PKG_JSON="${1:?package_json argument required}"
VALIDATE_BUILD_SCRIPT_V2="${2:?validate_build_script_v2 required}"
WHEEL_BUILD="${3:?wheel_build required}"
BUILD_DOCKER="${4:?build_docker required}"
POWERCORE_VERSION="${5:?powercore_version required}"

echo "--- Validating package_json ---"
if ! echo "$PKG_JSON" | jq empty 2>/dev/null; then
  echo "ERROR: package_json is not valid JSON"
  exit 1
fi

# Extract fields — technology_version key may have a leading space in some
# callers (e.g. {" technology_version":"3.12"}), handle both forms.
PKG_NAME=$(echo "$PKG_JSON" | jq -r '.package_name    // empty')
PKG_VER=$(echo  "$PKG_JSON" | jq -r '.package_version // empty')
TECH=$(echo     "$PKG_JSON" | jq -r '.technology      // empty')
TECH_VER=$(echo "$PKG_JSON" | jq -r '.technology_version // (.["  technology_version"] // "")' 2>/dev/null || echo "")
UBI_VER=$(echo  "$PKG_JSON" | jq -r '.ubi_version // ""')

echo "--- Validating required fields ---"
for field in PKG_NAME PKG_VER TECH; do
  eval "val=\$$field"
  if [ -z "$val" ]; then
    echo "ERROR: Required field missing in package_json: $field"
    exit 1
  fi
done

# Default ubi_version to ubi9 when blank
UBI_VER="${UBI_VER:-ubi9}"

echo "--- Writing variable.sh ---"
printf '%s\n' \
  "PACKAGE_NAME=\"${PKG_NAME}\"" \
  "PACKAGE_VERSION=\"${PKG_VER}\"" \
  "TECHNOLOGY=\"${TECH}\"" \
  "TECHNOLOGY_VERSION=\"${TECH_VER}\"" \
  "UBI_VERSION=\"${UBI_VER}\"" \
  "VALIDATE_BUILD_SCRIPT_V2=\"${VALIDATE_BUILD_SCRIPT_V2}\"" \
  "WHEEL_BUILD=\"${WHEEL_BUILD}\"" \
  "BUILD_DOCKER=\"${BUILD_DOCKER}\"" \
  "POWERCORE_VERSION=\"${POWERCORE_VERSION}\"" \
  > variable.sh

echo "===== variable.sh ====="
cat variable.sh
echo "======================="
echo "OK: ${PKG_NAME} ${PKG_VER} (${TECH} ${TECH_VER:-default}) ubi=${UBI_VER}"
