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

# ── Kill any already-running workers so they restart with the fresh env ───────
# systemd reads EnvironmentFile only at service start — running workers keep
# their original env. Kill the processes directly (works even without XDG) so
# systemd's Restart=always brings them back clean with the updated workflow.env.
echo "--- Killing any running powercore-worker processes ---"
sudo pkill -u powercore -f "powercore-worker" 2>/dev/null || true
sleep 3

# ── Ensure XDG runtime dir exists — retry up to 30 s ─────────────────────────
# loginctl linger creates /run/user/<uid> asynchronously; poll until it appears.
if [ ! -d "${XDG_DIR}" ]; then
  echo "--- Enabling loginctl linger for powercore ---"
  sudo loginctl enable-linger powercore || true
fi
for i in $(seq 1 30); do
  [ -d "${XDG_DIR}" ] && break
  echo "  [${i}s] Waiting for ${XDG_DIR}..."
  sleep 1
done
ls -la "${XDG_DIR}" 2>/dev/null || echo "WARN: ${XDG_DIR} still not available after 30s"

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
