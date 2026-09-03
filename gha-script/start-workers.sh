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
CONFIG_ENV="$(pwd)/powercore-config.env"

echo "--- powercore UID: ${POWERCORE_UID} ---"
echo "--- XDG_RUNTIME_DIR: ${XDG_DIR} ---"
echo "--- PC_HOME: ${PC_HOME} ---"

# ── Resolve POWERCORE_RUNTIME from installed systemd.env ─────────────────────
# powercore-install runs deploy-workflow.sh which writes systemd.env at the
# actual runtime path.  The default fallback chain (deploy-workflow.sh line 34):
#   $POWERCORE_RUNTIME > $BULKSEARCH_RUNTIME > $HOME/bulksearch/runtime
# We search the most common candidate paths first, then fall back to find.
SYSTEMD_ENV=""
for candidate in \
  "${PC_HOME}/powercore/runtime/config/systemd.env" \
  "${PC_HOME}/bulksearch/runtime/config/systemd.env" \
  "${PC_HOME}/.local/share/powercore/runtime/config/systemd.env"; do
  if sudo -u powercore test -f "${candidate}" 2>/dev/null; then
    SYSTEMD_ENV="${candidate}"
    echo "--- Found systemd.env: ${SYSTEMD_ENV} ---"
    break
  fi
done

if [ -z "${SYSTEMD_ENV}" ]; then
  echo "--- Searching for systemd.env under ${PC_HOME} ---"
  SYSTEMD_ENV=$(sudo -u powercore find "${PC_HOME}" \
    -maxdepth 6 -name "systemd.env" -path "*/runtime/config/systemd.env" \
    2>/dev/null | head -1)
  [ -n "${SYSTEMD_ENV}" ] && echo "--- Found via search: ${SYSTEMD_ENV} ---"
fi

if [ -z "${SYSTEMD_ENV}" ]; then
  echo "ERROR: systemd.env not found under ${PC_HOME} — has powercore-install completed?"
  echo "--- Directory tree under ${PC_HOME} (depth 5) ---"
  sudo -u powercore find "${PC_HOME}" -maxdepth 5 -type d 2>/dev/null | sort | head -40 || true
  exit 1
fi

# Derive config dir and workflow.env from the same base
CONFIG_DIR=$(dirname "${SYSTEMD_ENV}")
WORKFLOW_ENV="${CONFIG_DIR}/workflow.env"

# Read actual POWERCORE_RUNTIME from systemd.env (the canonical source)
POWERCORE_RUNTIME=$(sudo -u powercore grep -m1 '^POWERCORE_RUNTIME=' "${SYSTEMD_ENV}" \
  | cut -d= -f2- | tr -d ' "' || true)
if [ -z "${POWERCORE_RUNTIME}" ]; then
  echo "WARN: POWERCORE_RUNTIME not found in systemd.env — deriving from config dir"
  POWERCORE_RUNTIME=$(dirname "${CONFIG_DIR}")
fi
echo "--- POWERCORE_RUNTIME: ${POWERCORE_RUNTIME} ---"

echo "--- Current systemd.env ---"
sudo -u powercore cat "${SYSTEMD_ENV}" | grep -v '^#\|^$' | head -30 || true

# ── Read registry/credentials from powercore-config.env ──────────────────────
# Config uses ICR_* as primary keys; POWERCORE_* are derived/aliases (same values).
# Three problems solved here:
#
# 1. powercore-install writes POWERCORE_REGISTRY="" + POWERCORE_IMAGE_TAG="" in
#    systemd.env (vars not in installer subprocess env) → env.sh default
#    localhost:5000 wins at runtime.
# 2. workflow.env (EnvironmentFile= loaded AFTER systemd.env) also carries
#    POWERCORE_REGISTRY=localhost:5000 imported from env.sh → overrides fix.
# 3. ICR_API_KEY never reached the worker → ensure_images_available() in
#    docker_manager.py (run_core.py L349) couldn't authenticate to pull images.
#
# Fix: read ICR_* (primary) with POWERCORE_* as fallback, patch POWERCORE_REGISTRY,
# POWERCORE_IMAGE_TAG, and ICR_API_KEY into both systemd.env and workflow.env.
# Note: deep scan (docker_manager.ensure_images_available) handles docker login
# itself using ICR_API_KEY from env — no pre-login needed here.
_reg=""; _tag=""; _icr_key=""
if [ -f "${CONFIG_ENV}" ]; then
  # Primary: ICR_* keys (always set in powercore-config.env)
  _icr_reg=$(grep -m1 '^ICR_REGISTRY='  "${CONFIG_ENV}" | cut -d= -f2- | tr -d '"' || true)
  _icr_tag=$(grep -m1 '^ICR_IMAGE_TAG=' "${CONFIG_ENV}" | cut -d= -f2- | tr -d '"' || true)
  _icr_key=$(grep -m1 '^ICR_API_KEY='   "${CONFIG_ENV}" | cut -d= -f2- | tr -d '"' || true)
  # Fallback: POWERCORE_* keys (same values, belt-and-suspenders)
  _pc_reg=$(grep -m1 '^POWERCORE_REGISTRY='  "${CONFIG_ENV}" | cut -d= -f2- | tr -d '"' || true)
  _pc_tag=$(grep -m1 '^POWERCORE_IMAGE_TAG=' "${CONFIG_ENV}" | cut -d= -f2- | tr -d '"' || true)
  # Use ICR_* values; fall back to POWERCORE_* if ICR_* absent
  _reg="${_icr_reg:-${_pc_reg}}"
  _tag="${_icr_tag:-${_pc_tag}}"
  echo "--- Registry config from powercore-config.env ---"
  echo "  ICR_REGISTRY  (primary)  = ${_icr_reg}"
  echo "  ICR_IMAGE_TAG (primary)  = ${_icr_tag}"
  echo "  POWERCORE_REGISTRY  (fb) = ${_pc_reg}"
  echo "  POWERCORE_IMAGE_TAG (fb) = ${_pc_tag}"
  echo "  Resolved POWERCORE_REGISTRY  = ${_reg}"
  echo "  Resolved POWERCORE_IMAGE_TAG = ${_tag}"
  echo "  ICR_API_KEY = ${_icr_key:0:8}***"
else
  echo "WARN: powercore-config.env not found at ${CONFIG_ENV} — registry not patched"
fi

# ── Helper: set/replace a KEY=VALUE line in an env file ───────────────────────
_set_env_var() {
  local file="$1" key="$2" val="$3"
  [ -f "${file}" ] || return
  if sudo -u powercore grep -q "^${key}=" "${file}" 2>/dev/null; then
    sudo -u powercore sed -i "s|^${key}=.*|${key}=${val}|" "${file}"
  else
    echo "${key}=${val}" | sudo -u powercore tee -a "${file}" > /dev/null
  fi
}

# ── Patch systemd.env ─────────────────────────────────────────────────────────
if [ -f "${SYSTEMD_ENV}" ]; then
  [ -n "${_reg}"     ] && _set_env_var "${SYSTEMD_ENV}" "POWERCORE_REGISTRY"  "${_reg}"
  [ -n "${_tag}"     ] && _set_env_var "${SYSTEMD_ENV}" "POWERCORE_IMAGE_TAG" "${_tag}"
  [ -n "${_icr_key}" ] && _set_env_var "${SYSTEMD_ENV}" "ICR_API_KEY"         "${_icr_key}"
  echo "--- systemd.env after patch ---"
  sudo -u powercore grep -E \
    '^POWERCORE_REGISTRY=|^POWERCORE_IMAGE_TAG=|^ICR_API_KEY=' "${SYSTEMD_ENV}" || true
fi

# ── Write workflow.env ────────────────────────────────────────────────────────
# Must be done before any systemd interaction so workers read it at launch.
sudo -u powercore mkdir -p "${CONFIG_DIR}"
sudo -u powercore touch "${WORKFLOW_ENV}" 2>/dev/null || true
sudo -u powercore sed -i '/^POWERCORE_FORCE_REBUILD=/d' "${WORKFLOW_ENV}" 2>/dev/null || true
echo "POWERCORE_FORCE_REBUILD=true" | sudo -u powercore tee -a "${WORKFLOW_ENV}" > /dev/null
# Patch registry + ICR credentials into workflow.env (loaded last → wins over systemd.env)
[ -n "${_reg}"     ] && _set_env_var "${WORKFLOW_ENV}" "POWERCORE_REGISTRY"  "${_reg}"
[ -n "${_tag}"     ] && _set_env_var "${WORKFLOW_ENV}" "POWERCORE_IMAGE_TAG" "${_tag}"
[ -n "${_icr_key}" ] && _set_env_var "${WORKFLOW_ENV}" "ICR_API_KEY"         "${_icr_key}"

echo "--- workflow.env after patch ---"
sudo -u powercore grep -E \
  '^POWERCORE_REGISTRY=|^POWERCORE_IMAGE_TAG=|^ICR_API_KEY=|^POWERCORE_FORCE_REBUILD=' \
  "${WORKFLOW_ENV}" || true

# Helper: run a systemctl command as the powercore user
_sctl() {
  sudo -u powercore \
    XDG_RUNTIME_DIR="${XDG_DIR}" \
    DBUS_SESSION_BUS_ADDRESS="${DBUS}" \
    systemctl --user "$@"
}

# ── Locate the installed service unit file ────────────────────────────────────
# deploy-workflow.sh copies the unit to ~/.config/systemd/user/ (for local mode)
# or /etc/systemd/user/ (for production).  Try common locations.
UNIT_FILE=""
for candidate in \
  "${PC_HOME}/.config/systemd/user/powercore-worker@.service" \
  "/etc/systemd/user/powercore-worker@.service" \
  "/usr/lib/systemd/user/powercore-worker@.service"; do
  if sudo -u powercore test -f "${candidate}" 2>/dev/null; then
    UNIT_FILE="${candidate}"
    break
  fi
done

if [ -z "${UNIT_FILE}" ]; then
  echo "ERROR: powercore-worker@.service not found — has deploy-workflow.sh run?"
  echo "--- Searched paths ---"
  echo "  ${PC_HOME}/.config/systemd/user/powercore-worker@.service"
  echo "  /etc/systemd/user/powercore-worker@.service"
  echo "--- ~/.config/systemd/user/ content ---"
  sudo -u powercore ls -la "${PC_HOME}/.config/systemd/user/" 2>/dev/null || true
  exit 1
fi
echo "--- Unit file: ${UNIT_FILE} ---"

# ── Inject --force-rebuild directly into the 04-shallow-scan unit ────────────
# The EnvironmentFile approach is unreliable when Restart=always races with
# the stop/start cycle. Instead, patch ExecStart in the installed service file
# to pass --force-rebuild directly on the command line — the adapter forwards
# it via original_argv (shallow_scan.py adapter L59: '--force-rebuild' in argv).
# This is the most reliable path: no env var timing, no dbus races.
echo "--- Patching ExecStart in ${UNIT_FILE} ---"
echo "  Before patch:"
sudo -u powercore grep "ExecStart" "${UNIT_FILE}" | sed 's/^/    /'
# Add --force-rebuild to ExecStart if not already present
sudo -u powercore sed -i 's|ExecStart=\(.*powercore-worker\) %i$|ExecStart=\1 %i --force-rebuild|' "${UNIT_FILE}"
echo "  After patch:"
sudo -u powercore grep "ExecStart" "${UNIT_FILE}" | sed 's/^/    /'
echo "--- ExecStart patched ---"

# ── Show effective environment before starting ────────────────────────────────
echo "--- Effective worker environment (EnvironmentFile chain) ---"
echo "  env.sh   (loaded first — provides defaults)"
echo "  systemd.env (overrides env.sh):"
sudo -u powercore grep -v '^#\|^$' "${SYSTEMD_ENV}" 2>/dev/null | head -20 | sed 's/^/    /' || true
echo "  workflow.env (loaded last — wins over systemd.env):"
sudo -u powercore grep -v '^#\|^$' "${WORKFLOW_ENV}" 2>/dev/null | head -20 | sed 's/^/    /' || true

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
