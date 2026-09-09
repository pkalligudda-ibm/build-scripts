#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?scan workspace required}"
REPO_ROOT="${2:?repository root required}"
cd "$ROOT"
mkdir -p wheel
shopt -s nullglob
files=(wheel/*_output.json)
if [ "${#files[@]}" -eq 0 ]; then
  echo "No ScanCode wheel JSON files found; skipping license extraction."
  exit 0
fi

for json_file in "${files[@]}"; do
  licenses=$(python3 "$REPO_ROOT/gha-script/v2-script/licenses_extract_script.py" "$json_file")
  python3 - "$json_file" "$licenses" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
out = source.with_name(source.stem + "_licenses.json")
out.write_text(json.dumps({"source": source.name, "licenses": sys.argv[2].split(", ") if sys.argv[2] else []}, indent=2) + "\n")
PY
done
