#!/usr/bin/env bash
# start-workers.sh — Start powercore-workflow.target via systemd user session and
# verify all 5 stage workers reach 'active' state.
#
# Usage:
#   start-workers.sh
#
# POWERCORE_FORCE_REBUILD=true is always written to workflow.env so the
# 04-shallow-scan worker sends ALL packages to deep scan regardless of DB status.
# To disable force-rebuild, set POWERCORE_FORCE_REBUILD=false in workflow.env
# manually before running — the env var takes effect via the adapter priority:
#   CLI flag --force-rebuild  →  1st priority
#   POWERCORE_FORCE_REBUILD env var  →  2nd priority (used here)
#
# Requires: 'powercore' system user to exist (run after install-powercore.sh).
set -euo pipefail

if ! id powercore &>/dev/null; then
  echo "ERROR: 'powercore' user does not exist"
  exit 1
fi

POWERCORE_UID=$(id -u powercore)
XDG_DIR="/run/user/${POWERCORE_UID}"
DBUS="unix:path=/run/user/${POWERCORE_UID}/bus"
PC_HOME=$(getent passwd powercore | cut -d: -f6)
WORKFLOW_ENV="${PC_HOME}/powercore/runtime/config/workflow.env"

echo "--- powercore UID: ${POWERCORE_UID} ---"
echo "--- XDG_RUNTIME_DIR: ${XDG_DIR} ---"

# ── Write workflow.env FIRST — before any systemd interaction ─────────────────
# This must happen before start so workers read the fresh env at launch.
# Also written before loginctl linger so it exists even if XDG setup is slow.
sudo -u powercore mkdir -p "$(dirname "${WORKFLOW_ENV}")"
sudo -u powercore sed -i '/^POWERCORE_FORCE_REBUILD=/d' "${WORKFLOW_ENV}" 2>/dev/null || true
echo "POWERCORE_FORCE_REBUILD=true" | sudo -u powercore tee -a "${WORKFLOW_ENV}" > /dev/null
echo "--- workflow.env contents ---"
sudo -u powercore cat "${WORKFLOW_ENV}"

# Helper: run a systemctl command as the powercore user
_sctl() {
  sudo -u powercore \
    XDG_RUNTIME_DIR="${XDG_DIR}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS}" \
    systemctl --user "$@"
}

# ── Inject --force-rebuild directly into the 04-shallow-scan unit ────────────
# The EnvironmentFile approach is unreliable when Restart=always races with
# the stop/start cycle. Instead, patch ExecStart in the installed service file
# to pass --force-rebuild directly on the command line — the adapter forwards
# it via original_argv (shallow_scan.py adapter L59: '--force-rebuild' in argv).
# This is the most reliable path: no env var timing, no dbus races.
UNIT_FILE="${PC_HOME}/.config/systemd/user/powercore-worker@.service"
echo "--- Patching ExecStart in ${UNIT_FILE} ---"
# Show current ExecStart
sudo grep "ExecStart" "${UNIT_FILE}"
# Add --force-rebuild to ExecStart if not already present
sudo sed -i 's|ExecStart=\(.*powercore-worker\) %i$|ExecStart=\1 %i --force-rebuild|' "${UNIT_FILE}"
sudo grep "ExecStart" "${UNIT_FILE}"
echo "--- ExecStart patched ---"

# Stop each worker individually (target stop alone races with Restart=always)
echo "--- Stopping all worker services ---"
for stage in 03-preprocess 04-shallow-scan 05-deep-scan 06-post-process 07-bookkeeping; do
  _sctl stop "powercore-worker@${stage}.service" 2>/dev/null || true
done
_sctl stop powercore-workflow.target 2>/dev/null || true
sleep 5

echo "--- Reloading systemd user daemon (picks up patched ExecStart) ---"
_sctl daemon-reload

echo "--- Starting powercore-workflow.target ---"
_sctl start powercore-workflow.target || true

echo "--- Waiting 30s for workers to initialise ---"
sleep 30

echo "--- powercore-workflow.target status ---"
_sctl status powercore-workflow.target --no-pager || true

echo "--- Per-worker unit status ---"
ALL_ACTIVE=true
for stage in 03-preprocess 04-shallow-scan 05-deep-scan 06-post-process 07-bookkeeping; do
  STATUS=$(_sctl is-active "powercore-worker@${stage}.service" 2>/dev/null || true)
  echo "  powercore-worker@${stage}: ${STATUS}"
  if [ "$STATUS" != "active" ]; then
    echo "  --- Journal for powercore-worker@${stage} ---"
    sudo -u powercore \
      XDG_RUNTIME_DIR="${XDG_DIR}" \
      DBUS_SESSION_BUS_ADDRESS="${DBUS}" \
      journalctl --user -u "powercore-worker@${stage}.service" \
        --no-pager -n 50 2>/dev/null || true
    ALL_ACTIVE=false
  fi
done

if [ "$ALL_ACTIVE" = "false" ]; then
  echo "ERROR: one or more PowerCore workers failed to reach 'active' state"
  exit 1
fi
echo "--- All PowerCore workers active ---"
