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

echo "--- powercore UID: ${POWERCORE_UID} ---"
echo "--- XDG_RUNTIME_DIR: ${XDG_DIR} ---"

# Ensure XDG runtime dir exists (loginctl linger creates it)
if [ ! -d "${XDG_DIR}" ]; then
  echo "WARN: ${XDG_DIR} does not exist — enabling loginctl linger"
  sudo loginctl enable-linger powercore || true
  sleep 3
fi
ls -la "${XDG_DIR}" 2>/dev/null || echo "WARN: ${XDG_DIR} still not available"

# ── Write POWERCORE_FORCE_REBUILD=true into workflow.env ─────────────────────
# The service unit EnvironmentFile's this file so every worker picks it up.
# This ensures all packages are sent to deep scan regardless of DB status.
PC_HOME=$(getent passwd powercore | cut -d: -f6)
WORKFLOW_ENV="${PC_HOME}/powercore/runtime/config/workflow.env"
sudo -u powercore mkdir -p "$(dirname "${WORKFLOW_ENV}")"
sudo -u powercore sed -i '/^POWERCORE_FORCE_REBUILD=/d' "${WORKFLOW_ENV}" 2>/dev/null || true
echo "POWERCORE_FORCE_REBUILD=true" | sudo -u powercore tee -a "${WORKFLOW_ENV}" > /dev/null
echo "--- workflow.env ---"
sudo -u powercore cat "${WORKFLOW_ENV}"

# Helper: run a systemctl command as the powercore user
_sctl() {
  sudo -u powercore \
    XDG_RUNTIME_DIR="${XDG_DIR}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS}" \
    systemctl --user "$@"
}

echo "--- Reloading systemd user daemon ---"
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
