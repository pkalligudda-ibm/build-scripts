#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${1:?PowerCore runtime required}"
PACKAGE_NAME="${2:?package name required}"
WORKSPACE_DIR="${3:-v2-scan-workspace}"

REQUEST_DIR=$(find "$RUNTIME" -type d -name 'BRequest_*' 2>/dev/null | sort | tail -1)
if [ -z "$REQUEST_DIR" ]; then
  echo "ERROR: no BRequest directory found under $RUNTIME" >&2
  exit 1
fi

rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR/package-cache" "$WORKSPACE_DIR/wheels" "$WORKSPACE_DIR/image" "$WORKSPACE_DIR/metadata"

find "$REQUEST_DIR" -type f -name '*.whl' -exec cp -f {} "$WORKSPACE_DIR/wheels/" \;
find "$REQUEST_DIR" -type f -name 'package.json' -exec cp -f {} "$WORKSPACE_DIR/metadata/package.json" \; -quit
find "$REQUEST_DIR" -type f \( -name 'validation_summary.json' -o -name 'artifacts_summary.json' -o -name 'post_process_summary.json' \) -exec cp -f {} "$WORKSPACE_DIR/metadata/" \;

SOURCE_DIR=$(find "$REQUEST_DIR" -type d \( -name src -o -name source -o -name "$PACKAGE_NAME" \) 2>/dev/null | head -1 || true)
if [ -n "$SOURCE_DIR" ]; then
  cp -a "$SOURCE_DIR" "$WORKSPACE_DIR/package-cache/source"
else
  echo "WARNING: no source directory found in $REQUEST_DIR" >&2
fi
printf 'export CLONED_PACKAGE=source\n' > "$WORKSPACE_DIR/package-cache/scanner-env.sh"

cat > "$WORKSPACE_DIR/package-cache/variable.sh" <<EOF
export PACKAGE_NAME="$PACKAGE_NAME"
export VALIDATE_BUILD_SCRIPT=true
export BUILD_DOCKER=true
EOF

if find "$REQUEST_DIR" -type f -name 'image.tar' -print -quit | grep -q .; then
  find "$REQUEST_DIR" -type f -name 'image.tar' -exec cp -f {} "$WORKSPACE_DIR/image/image.tar" \; -quit
fi

printf 'REQUEST_DIR=%s\n' "$REQUEST_DIR" > "$WORKSPACE_DIR/metadata/request.env"
printf 'PACKAGE_NAME=%s\n' "$PACKAGE_NAME" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'SOURCE_PRESENT=%s\n' "$(test -d "$WORKSPACE_DIR/package-cache/source" && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'WHEEL_PRESENT=%s\n' "$(find "$WORKSPACE_DIR/wheels" -name '*.whl' -print -quit | grep -q . && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'IMAGE_PRESENT=%s\n' "$(test -f "$WORKSPACE_DIR/image/image.tar" && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
