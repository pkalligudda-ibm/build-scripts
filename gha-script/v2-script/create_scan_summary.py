#!/usr/bin/env python3
import json
import sys
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("v2-scan-workspace")
summary = {
    "scan_workspace": str(root),
    "files": [],
    "results": {
        "wheels": [],
        "source_scans": [],
        "wheel_scans": [],
        "wheel_licenses": [],
        "metadata": [],
    },
    "scan_types": {
        "source": root.joinpath("source").is_dir(),
        "wheel": root.joinpath("wheel").is_dir(),
        "image": root.joinpath("image", "results").is_dir(),
    },
}

for path in sorted(root.rglob("*")):
    if path.is_file() and ".git" not in path.parts:
        relative_path = str(path.relative_to(root))
        entry = {"path": relative_path, "size_bytes": path.stat().st_size}
        summary["files"].append(entry)

        if path.suffix == ".whl":
            summary["results"]["wheels"].append(relative_path)
        elif path.name.endswith("_licenses.json"):
            summary["results"]["wheel_licenses"].append(relative_path)
        elif relative_path.startswith("source/"):
            summary["results"]["source_scans"].append(relative_path)
        elif relative_path.startswith("wheel/") and path.suffix == ".json":
            summary["results"]["wheel_scans"].append(relative_path)
        elif relative_path.startswith("metadata/"):
            summary["results"]["metadata"].append(relative_path)

(root / "final_summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
