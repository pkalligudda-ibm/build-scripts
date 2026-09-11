#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${1:?PowerCore runtime required}"
PACKAGE_NAME="${2:?package name required}"
WORKSPACE_DIR="${3:-v2-scan-workspace}"

REQUEST_DIR=$(sudo -u powercore find "$RUNTIME" -type d -name 'BRequest_*' 2>/dev/null | sort | tail -1)
if [ -z "$REQUEST_DIR" ]; then
  echo "ERROR: no BRequest directory found under $RUNTIME" >&2
  echo "Available runtime directories:" >&2
  sudo -u powercore find "$RUNTIME" -maxdepth 3 -type d 2>/dev/null | sort >&2 || true
  exit 1
fi

rm -rf "$WORKSPACE_DIR"
mkdir -p "$WORKSPACE_DIR/package-cache" "$WORKSPACE_DIR/wheels" "$WORKSPACE_DIR/image" "$WORKSPACE_DIR/metadata"

sudo -u powercore find "$REQUEST_DIR" -type f -name '*.whl' -exec sudo cp -f {} "$WORKSPACE_DIR/wheels/" \;
sudo -u powercore find "$REQUEST_DIR" -type f -name 'package.json' -exec sudo cp -f {} "$WORKSPACE_DIR/metadata/package.json" \; -quit
sudo -u powercore find "$REQUEST_DIR" -type f \( -name 'validation_summary.json' -o -name 'artifacts_summary.json' -o -name 'post_process_summary.json' \) -exec sudo cp -f {} "$WORKSPACE_DIR/metadata/" \;

SOURCE_DIR=$(sudo -u powercore find "$REQUEST_DIR" -type d \( -name src -o -name source -o -name "$PACKAGE_NAME" \) 2>/dev/null | head -1 || true)
if [ -n "$SOURCE_DIR" ]; then
  sudo cp -a "$SOURCE_DIR" "$WORKSPACE_DIR/package-cache/source"
else
  echo "WARNING: no source directory found in $REQUEST_DIR" >&2
fi
printf 'export CLONED_PACKAGE=source\n' > "$WORKSPACE_DIR/package-cache/scanner-env.sh"

cat > "$WORKSPACE_DIR/package-cache/variable.sh" <<EOF
export PACKAGE_NAME="$PACKAGE_NAME"
export VALIDATE_BUILD_SCRIPT=true
export BUILD_DOCKER=true
EOF

if sudo -u powercore find "$REQUEST_DIR" -type f -name 'image.tar' -print -quit | grep -q .; then
  sudo -u powercore find "$REQUEST_DIR" -type f -name 'image.tar' -exec sudo cp -f {} "$WORKSPACE_DIR/image/image.tar" \; -quit
fi

sudo chown -R "$(id -u):$(id -g)" "$WORKSPACE_DIR"

printf 'REQUEST_DIR=%s\n' "$REQUEST_DIR" > "$WORKSPACE_DIR/metadata/request.env"
printf 'PACKAGE_NAME=%s\n' "$PACKAGE_NAME" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'SOURCE_PRESENT=%s\n' "$(test -d "$WORKSPACE_DIR/package-cache/source" && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'WHEEL_PRESENT=%s\n' "$(find "$WORKSPACE_DIR/wheels" -name '*.whl' -print -quit | grep -q . && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
printf 'IMAGE_PRESENT=%s\n' "$(test -f "$WORKSPACE_DIR/image/image.tar" && echo true || echo false)" >> "$WORKSPACE_DIR/metadata/request.env"
