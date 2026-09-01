#!/usr/bin/env bash
# poll-pipeline.sh — Monitor a PowerCore pipeline run until completion or timeout.
# Tracks the BRequest directory through all 5 stages, printing per-stage summaries.
#
# Usage:
#   poll-pipeline.sh <powercore_runtime> <csv_name> <package_name>
#
# Pipeline stage flow (grounded in worker.py + adapter source):
#   03-preprocess  : CSV → BRequest_* dir created in runtime/input/
#   04-shallow-scan: categorise packages; route to deep-scan or post-process
#   05-deep-scan   : build (may be skipped if all packages SATISFIED)
#   06-post-process: aggregate results, write post_process_summary.json
#   07-bookkeeping : upload to CouchDB; BRequest moves to runtime/requests/ (DONE)
#
# Error handling: worker writes BRequest/.error and retries from inbox — no
# permanent failed/ dir. We detect .error, log it, and keep polling.
#
# Soft timeout: 10500 s (175 min) — fires before GHA's 180-min hard kill.
set -euo pipefail

POWERCORE_RUNTIME="${1:?powercore_runtime required}"
CSV_NAME="${2:?csv_name required}"
PKG_NAME="${3:?package_name required}"

POLL_INTERVAL=10
ELAPSED=0
TIMEOUT_SECS=10500
BREQUEST=""
PREV_LOCATION=""
PREV_STAGE=""

POWERCORE_UID=$(id -u powercore 2>/dev/null || echo "")
XDG_DIR="/run/user/${POWERCORE_UID}"
DBUS="unix:path=/run/user/${POWERCORE_UID}/bus"
WFLOG="${POWERCORE_RUNTIME}/logs/workflow.log"

# ── _find_brequest ─────────────────────────────────────────────────────────────
# Returns the BRequest path relative to POWERCORE_RUNTIME.
# Searches: requests/ (done), then queues/ (in-flight).
_find_brequest() {
  [ -z "${BREQUEST}" ] && return
  if sudo -u powercore test -d "${POWERCORE_RUNTIME}/requests/${BREQUEST}" 2>/dev/null; then
    echo "requests/${BREQUEST}"; return
  fi
  sudo -u powercore find "${POWERCORE_RUNTIME}/queues/" \
    -mindepth 3 -maxdepth 3 -type d -name "${BREQUEST}" 2>/dev/null \
    | head -1 | sed "s|${POWERCORE_RUNTIME}/||"
}

# ── _fmt_location ──────────────────────────────────────────────────────────────
# Converts a relative BRequest path into a human-readable label.
_fmt_location() {
  local rel="$1"
  [[ "$rel" == requests/* ]] && { echo "DONE"; return; }
  local stage subfolder label
  stage=$(echo "$rel"     | grep -oP '\d\d-[a-z-]+' | head -1)
  subfolder=$(echo "$rel" | grep -oP '(?<=/)(inbox|processing|outbox)(?=/)' | head -1)
  case "$stage" in
    03-preprocess)   label="Stage 1/5  Pre-process"   ;;
    04-shallow-scan) label="Stage 2/5  Shallow Scan"  ;;
    05-deep-scan)    label="Stage 3/5  Deep Scan"      ;;
    06-post-process) label="Stage 4/5  Post-Process"  ;;
    07-bookkeeping)  label="Stage 5/5  Bookkeeping"   ;;
    *)               label="${stage:-${rel}}"          ;;
  esac
  case "$subfolder" in
    inbox)      label="${label}  [queued]"   ;;
    processing) label="${label}  [running]"  ;;
    outbox)     label="${label}  [done]"     ;;
  esac
  echo "${label}"
}

# ── _worker_journal ────────────────────────────────────────────────────────────
_worker_journal() {
  local stage="$1" lines="${2:-40}"
  echo "  journal: powercore-worker@${stage} (last ${lines} lines)"
  sudo -u powercore \
    XDG_RUNTIME_DIR="${XDG_DIR}" DBUS_SESSION_BUS_ADDRESS="${DBUS}" \
    journalctl --user -u "powercore-worker@${stage}.service" \
      --no-pager -n "${lines}" 2>/dev/null || true
}

_dump_all_journals() {
  echo "========== Worker journals =========="
  for s in 03-preprocess 04-shallow-scan 05-deep-scan 06-post-process 07-bookkeeping; do
    _worker_journal "$s"
  done
}

# ── _section_header ────────────────────────────────────────────────────────────
_section_header() {
  local stage="$1" elapsed_min="$2" elapsed_sec="$3"
  echo ""
  echo "============================================================"
  case "$stage" in
    04-shallow-scan) echo "  Stage 2/5 — Shallow Scan  [${elapsed_min}m${elapsed_sec}s]" ;;
    05-deep-scan)    echo "  Stage 3/5 — Deep Scan     [${elapsed_min}m${elapsed_sec}s]" ;;
    06-post-process) echo "  Stage 4/5 — Post-Process  [${elapsed_min}m${elapsed_sec}s]" ;;
    07-bookkeeping)  echo "  Stage 5/5 — Bookkeeping   [${elapsed_min}m${elapsed_sec}s]" ;;
  esac
  echo "============================================================"
}

# ── _json_field ────────────────────────────────────────────────────────────────
# Extract a value from a flat JSON file using grep+awk (no python/jq needed).
# Usage: _json_field <file> <key>   → prints the raw value (no quotes)
_json_field() {
  sudo -u powercore grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" "$1" \
    2>/dev/null | head -1 \
    | awk -F': ' '{gsub(/[",[:space:]]/,"",$2); print $2}' \
    || true
}

# ── _print_shallow_summary ─────────────────────────────────────────────────────
# Reads shallow_scan_metadata.json (written by shallow_scan.py:write_shallow_scan_metadata).
# File lives at: BRequest_dir/sheet_*/shallow_scan_output/shallow_scan_metadata.json
_print_shallow_summary() {
  local meta
  meta=$(sudo -u powercore find "$1" \
    -name "shallow_scan_metadata.json" 2>/dev/null | head -1)
  [ -z "$meta" ] && return
  local satisfied failed_known noarch rebuild new_pkg lang_unavail
  local pass_deep reduction dur next_st
  satisfied=$(_json_field   "${meta}" "satisfied")
  failed_known=$(_json_field "${meta}" "failed_known")
  noarch=$(_json_field       "${meta}" "noarch_unverified")
  rebuild=$(_json_field      "${meta}" "rebuild")
  new_pkg=$(_json_field      "${meta}" "new")
  lang_unavail=$(_json_field "${meta}" "lang_ver_unavailable")
  pass_deep=$(_json_field    "${meta}" "pass_to_deep_scan")
  reduction=$(_json_field    "${meta}" "reduction_pct")
  dur=$(_json_field          "${meta}" "duration_seconds")
  next_st=$(_json_field      "${meta}" "next_stage")
  local total=$(( ${satisfied:-0} + ${failed_known:-0} + ${noarch:-0} \
                  + ${rebuild:-0} + ${new_pkg:-0} + ${lang_unavail:-0} ))
  echo "  Shallow Scan Summary"
  echo "  ----------------------------------------"
  echo "  Total tasks        : ${total}"
  echo "  SATISFIED          : ${satisfied:-0}"
  echo "  FAILED_KNOWN       : ${failed_known:-0}"
  echo "  NOARCH_UNVERIFIED  : ${noarch:-0}"
  echo "  REBUILD            : ${rebuild:-0}"
  echo "  NEW                : ${new_pkg:-0}"
  echo "  LANG_VER_UNAVAIL   : ${lang_unavail:-0}"
  echo "  Pass to Deep Scan  : ${pass_deep:-0}"
  echo "  Reduction          : ${reduction:-0}%"
  echo "  Duration           : ${dur:-0}s"
  echo "  ----------------------------------------"
  echo "  Next stage         : ${next_st:-unknown}"
}

# ── _print_deep_scan_summary ───────────────────────────────────────────────────
# progress_reporter.py writes: "■ DONE  N/T ✓  F ✗  elapsed=Xm Ys  success=Z%"
# Fallback: run_core._print_summary() individual lines.
_print_deep_scan_summary() {
  [ ! -f "${WFLOG}" ] && return
  local done_line
  done_line=$(sudo -u powercore grep -a "DONE" "${WFLOG}" 2>/dev/null \
    | grep -a "elapsed=" | tail -1 || true)
  if [ -n "$done_line" ]; then
    echo "  Deep Scan Summary"
    echo "  ----------------------------------------"
    echo "  ${done_line}"
    echo "  ----------------------------------------"
  else
    local total success failed rate
    total=$(sudo -u powercore grep -a "Total packages:" "${WFLOG}" 2>/dev/null \
      | tail -1 | grep -oP '\d+' || true)
    success=$(sudo -u powercore grep -a "Successful:" "${WFLOG}" 2>/dev/null \
      | tail -1 | grep -oP '\d+' || true)
    failed=$(sudo -u powercore grep -aP "Failed: \d" "${WFLOG}" 2>/dev/null \
      | tail -1 | grep -oP '\d+$' || true)
    rate=$(sudo -u powercore grep -a "Success rate:" "${WFLOG}" 2>/dev/null \
      | tail -1 | grep -oP '[\d.]+%' || true)
    if [ -n "$total" ]; then
      echo "  Deep Scan Summary"
      echo "  ----------------------------------------"
      echo "  Total     : ${total}"
      echo "  Succeeded : ${success:-?}"
      echo "  Failed    : ${failed:-?}"
      echo "  Rate      : ${rate:-?}"
      echo "  ----------------------------------------"
    fi
  fi
}

# ── _print_postprocess_summary ─────────────────────────────────────────────────
# Reads post_process_summary.json (written by postprocess.py at BRequest root).
# totals keys: total_packages / build_success / build_success_unverified /
#              build_fail / install_fail / test_fail / timeout / partial
_print_postprocess_summary() {
  local pp="$1/post_process_summary.json"
  sudo -u powercore test -f "${pp}" 2>/dev/null || return
  local total ok ok_uv b_fail i_fail t_fail tmo partial arch
  total=$(_json_field  "${pp}" "total_packages")
  ok=$(_json_field     "${pp}" "build_success")
  ok_uv=$(_json_field  "${pp}" "build_success_unverified")
  b_fail=$(_json_field "${pp}" "build_fail")
  i_fail=$(_json_field "${pp}" "install_fail")
  t_fail=$(_json_field "${pp}" "test_fail")
  tmo=$(_json_field    "${pp}" "timeout")
  partial=$(_json_field "${pp}" "partial")
  arch=$(_json_field   "${pp}" "architecture")
  echo "  Post-Process Summary"
  echo "  ----------------------------------------"
  echo "  Architecture       : ${arch:-unknown}"
  echo "  Packages submitted : ${total:-N/A}"
  [ "${ok:-0}"      != "0" ] && echo "  Build success      : ${ok}"
  [ "${ok_uv:-0}"   != "0" ] && echo "  Build success (UV) : ${ok_uv}"
  [ "${b_fail:-0}"  != "0" ] && echo "  Build failures     : ${b_fail}"
  [ "${i_fail:-0}"  != "0" ] && echo "  Install failures   : ${i_fail}"
  [ "${t_fail:-0}"  != "0" ] && echo "  Test failures      : ${t_fail}"
  [ "${tmo:-0}"     != "0" ] && echo "  Timeouts           : ${tmo}"
  [ "${partial:-0}" != "0" ] && echo "  Partial            : ${partial}"
  if [ "${ok:-0}" = "0" ] && [ "${ok_uv:-0}" = "0" ] && [ "${total:-0}" != "0" ]; then
    echo ""
    echo "  NOTE: 0 builds - packages already SATISFIED in catalog"
  fi
  echo "  ----------------------------------------"
}

# ── _print_shallow_csv ─────────────────────────────────────────────────────────
# Prints per-package shallow scan status from *_shallow_results.csv.
# Columns (csv_formatter.py): shallow_status, needs_deep_scan, shallow_notes
_print_shallow_csv() {
  local csv_path="$1"
  [ -z "$csv_path" ] && return
  sudo -u powercore awk -F',' '
    NR==1 {
      for (i=1;i<=NF;i++) {
        gsub(/\r/,"",$i); gsub(/^ +| +$/,"",$i)
        if ($i=="package_name" || $i=="name")        ni=i
        if ($i=="package_version" || $i=="version")  vi=i
        if ($i=="shallow_status")  si=i
        if ($i=="needs_deep_scan") di=i
        if ($i=="shallow_notes")   oi=i
      }
      next
    }
    NF>1 {
      gsub(/\r/,"")
      name=ni?$ni:"?"
      ver=vi?$vi:"?"
      status=si?$si:"?"
      deep=di?$di:"?"
      notes=oi?$oi:""
      tag=(status=="SATISFIED") ? "SATISFIED" : (deep=="true" ? "NEEDS BUILD" : status)
      printf "  [%-11s]  %s  %s\n", tag, name, ver
      if (notes != "") printf "               %s\n", notes
    }
  ' "${csv_path}" 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# STARTUP BANNER
# ══════════════════════════════════════════════════════════════════════════════
echo "============================================================"
echo "  PowerCore Pipeline Monitor"
echo "============================================================"
echo "  Package      : ${PKG_NAME}"
echo "  CSV file     : ${CSV_NAME}"
echo "  Runtime      : ${POWERCORE_RUNTIME}"
echo "  Poll interval: ${POLL_INTERVAL}s  |  Soft timeout: $((TIMEOUT_SECS/60))min"
echo "============================================================"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STAGE 1/5 — PRE-PROCESS
# Wait for 03-preprocess to consume the CSV and create a BRequest dir.
# BRequest name = BRequest_{date}_{csv_stem}_{uuid8}  (preprocess.generate_task_id)
# BRequest created in runtime/input/ or runtime/ root (config-dependent).
# ══════════════════════════════════════════════════════════════════════════════
CSV_STEM="${CSV_NAME%.csv}"

echo "------------------------------------------------------------"
echo "  Stage 1/5  Pre-process  [waiting for BRequest creation]"
echo "------------------------------------------------------------"

while [ -z "$BREQUEST" ]; do
  if [ "${ELAPSED}" -ge "${TIMEOUT_SECS}" ]; then
    echo "TIMEOUT (${ELAPSED}s) — Pre-process never created a BRequest"
    echo "  03-preprocess/inbox:"
    sudo -u powercore ls -lh "${POWERCORE_RUNTIME}/queues/03-preprocess/inbox/" 2>/dev/null || true
    echo "  03-preprocess/processing:"
    sudo -u powercore ls -lh "${POWERCORE_RUNTIME}/queues/03-preprocess/processing/" 2>/dev/null || true
    echo "  runtime/input/:"
    sudo -u powercore ls -lh "${POWERCORE_RUNTIME}/input/" 2>/dev/null || true
    _worker_journal "03-preprocess"
    exit 1
  fi

  FOUND=$(
    {
      sudo -u powercore find "${POWERCORE_RUNTIME}/input/" \
        -maxdepth 1 -type d -name "BRequest_*" 2>/dev/null
      sudo -u powercore find "${POWERCORE_RUNTIME}" \
        -maxdepth 1 -type d -name "BRequest_*" 2>/dev/null
      sudo -u powercore find "${POWERCORE_RUNTIME}/queues/" \
        -mindepth 3 -maxdepth 3 -type d -name "BRequest_*" 2>/dev/null
    } | head -1
  )

  if [ -n "$FOUND" ]; then
    BREQUEST=$(basename "$FOUND")
    REL=$(echo "$FOUND" | sed "s|${POWERCORE_RUNTIME}/||")
    PREV_LOCATION="$REL"
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))
    echo ""
    echo "  BRequest created: ${BREQUEST}  [${ELAPSED_MIN}m${ELAPSED_SEC}s]"
    echo "  Starting location: $(_fmt_location "${REL}")"
    echo ""
    if sudo -u powercore test -f "${WFLOG}" 2>/dev/null; then
      echo "  Pre-process log (last 10 lines):"
      sudo -u powercore grep -a "03-preprocess\|preprocess\|BRequest" "${WFLOG}" 2>/dev/null \
        | tail -10 | sed 's/^/    /' || true
      echo ""
    fi
    break
  fi

  if [ "$(( ELAPSED % 60 ))" -eq 0 ] && [ "${ELAPSED}" -gt 0 ]; then
    CSV_IN_INBOX="NO"; CSV_IN_PROC="NO"
    sudo -u powercore test -f \
      "${POWERCORE_RUNTIME}/queues/03-preprocess/inbox/${CSV_NAME}" \
      2>/dev/null && CSV_IN_INBOX="YES"
    sudo -u powercore test -f \
      "${POWERCORE_RUNTIME}/queues/03-preprocess/processing/${CSV_NAME}" \
      2>/dev/null && CSV_IN_PROC="YES"
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    echo "  [${ELAPSED_MIN}m] Waiting... CSV in inbox=${CSV_IN_INBOX} processing=${CSV_IN_PROC}"
    _worker_journal "03-preprocess" 10
  else
    echo "  [${ELAPSED}s] Waiting for Pre-process to create BRequest..."
  fi
  sleep "${POLL_INTERVAL}"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
done

# ══════════════════════════════════════════════════════════════════════════════
# STAGE 2–5: Track BRequest through the remaining pipeline stages
# ══════════════════════════════════════════════════════════════════════════════
while true; do
  if [ "${ELAPSED}" -ge "${TIMEOUT_SECS}" ]; then
    echo ""
    echo "TIMEOUT (${ELAPSED}s) — pipeline did not complete in time"
    _dump_all_journals
    exit 1
  fi

  # ── SUCCESS ─────────────────────────────────────────────────────────────────
  if sudo -u powercore test -d "${POWERCORE_RUNTIME}/requests/${BREQUEST}" 2>/dev/null; then
    RESULT_DIR="${POWERCORE_RUNTIME}/requests/${BREQUEST}"
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))
    echo ""
    echo "============================================================"
    echo "  PIPELINE COMPLETE  [${ELAPSED_MIN}m${ELAPSED_SEC}s total]"
    echo "============================================================"
    echo "  Package   : ${PKG_NAME}"
    echo "  BRequest  : ${BREQUEST}"
    echo "  Result    : ${RESULT_DIR}"
    echo ""
    _print_postprocess_summary "${RESULT_DIR}"
    echo ""
    SHALLOW_CSV=$(sudo -u powercore find "${RESULT_DIR}" \
      -maxdepth 1 -name "*shallow_results.csv" 2>/dev/null | head -1)
    if [ -n "$SHALLOW_CSV" ]; then
      echo "  Shallow Scan — Per-Package Status"
      echo "  ----------------------------------------"
      _print_shallow_csv "${SHALLOW_CSV}"
      echo ""
    fi
    OUTPUT_DIR="${RESULT_DIR}/output"
    if sudo -u powercore test -d "${OUTPUT_DIR}" 2>/dev/null; then
      echo "  Output Files"
      echo "  ----------------------------------------"
      sudo -u powercore find "${OUTPUT_DIR}" -type f | sort | while read -r f; do
        SIZE=$(sudo -u powercore du -sh "$f" 2>/dev/null | cut -f1)
        printf "  %-8s  %s\n" "${SIZE}" "${f#${RESULT_DIR}/}"
      done
      echo ""
    fi
    echo "============================================================"
    exit 0
  fi

  # ── ERROR ────────────────────────────────────────────────────────────────────
  ERROR_FILE=$(sudo -u powercore find "${POWERCORE_RUNTIME}/queues/" \
    -name ".error" 2>/dev/null | grep "/${BREQUEST}/" | head -1 || true)
  if [ -n "$ERROR_FILE" ]; then
    echo ""
    echo "  ERROR detected in ${BREQUEST}"
    echo "  .error: ${ERROR_FILE}"
    sudo -u powercore cat "${ERROR_FILE}" | sed 's/^/  /'
    CUR_LOCATION=$(_find_brequest)
    ERR_STAGE=$(echo "$CUR_LOCATION" | grep -oP '\d\d-[a-z-]+' | head -1)
    [ -n "$ERR_STAGE" ] && _worker_journal "${ERR_STAGE}" 30
    echo "  (worker will retry — waiting for recovery or timeout)"
  fi

  # ── LOCATE ───────────────────────────────────────────────────────────────────
  CUR_LOCATION=$(_find_brequest)
  if [ -z "$CUR_LOCATION" ]; then
    sleep 2; ELAPSED=$(( ELAPSED + 2 )); continue
  fi

  # ── TRANSITION ───────────────────────────────────────────────────────────────
  if [ "${CUR_LOCATION}" != "${PREV_LOCATION}" ]; then
    CUR_STAGE=$(echo "$CUR_LOCATION" | grep -oP '\d\d-[a-z-]+' | head -1)
    CUR_SUB=$(echo "$CUR_LOCATION"   | grep -oP '(?<=/)(inbox|processing|outbox)(?=/)' | head -1)
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))

    if [ "${CUR_STAGE}" != "${PREV_STAGE}" ] && [ -n "${CUR_STAGE}" ]; then
      _section_header "${CUR_STAGE}" "${ELAPSED_MIN}" "${ELAPSED_SEC}"

      case "${PREV_STAGE}" in
        04-shallow-scan)
          BREQ_SEARCH=$(sudo -u powercore find \
            "${POWERCORE_RUNTIME}/queues/${PREV_STAGE}" \
            -name "shallow_scan_metadata.json" 2>/dev/null | head -1)
          if [ -n "$BREQ_SEARCH" ]; then
            _print_shallow_summary "$(dirname "$BREQ_SEARCH")"
          else
            _print_shallow_summary \
              "${POWERCORE_RUNTIME}/queues/${CUR_STAGE}/${CUR_SUB:-inbox}/${BREQUEST}"
          fi
          echo ""
          ;;
        05-deep-scan)
          _print_deep_scan_summary
          echo ""
          ;;
      esac

      PREV_STAGE="${CUR_STAGE}"
    fi

    echo "  [${ELAPSED_MIN}m${ELAPSED_SEC}s]  $(_fmt_location "${CUR_LOCATION}")"
    PREV_LOCATION="${CUR_LOCATION}"
  else
    # Heartbeat every 60 s
    if [ "$(( ELAPSED % 60 ))" -eq 0 ] && [ "${ELAPSED}" -gt 0 ]; then
      ELAPSED_MIN=$(( ELAPSED / 60 ))
      echo "  ... [${ELAPSED_MIN}m]  $(_fmt_location "${CUR_LOCATION}")"
    fi
  fi

  sleep "${POLL_INTERVAL}"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
done
