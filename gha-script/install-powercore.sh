#!/usr/bin/env bash
# install-powercore.sh — Install powercore_installer wheel then run powercore-install.
#
# Usage:
#   install-powercore.sh <path-to-powercore-config.env>
#
# Expects powercore-wheels/ to already exist in CWD (populated by download-wheels.sh).
set -euo pipefail

CONFIG_ENV="${1:?config env path required}"

echo "--- Upgrading pip ---"
python3.12 -m pip install --upgrade pip --user --quiet

echo "--- Installing powercore_installer wheel ---"
installer_wheel=$(ls powercore-wheels/powercore_installer-*.whl 2>/dev/null | head -1)
if [[ -z "$installer_wheel" ]]; then
  echo "ERROR: powercore_installer wheel not found in powercore-wheels/"
  ls powercore-wheels/ || true
  exit 1
fi
echo "  Installing from: ${installer_wheel}"
sudo python3.12 -m pip install "$installer_wheel" --force-reinstall

echo "--- Installed powercore packages ---"
python3.12 -m pip list | grep -i powercore || true

echo "--- Running powercore-install ---"
echo "  Config: ${CONFIG_ENV}"
cat "${CONFIG_ENV}"
sudo powercore-install --config "${CONFIG_ENV}" --non-interactive

echo "--- Verifying powercore system user ---"
if ! id powercore &>/dev/null; then
  echo "ERROR: 'powercore' system user was not created by powercore-install"
  exit 1
fi
echo "powercore user: $(id powercore)"

PC_HOME=$(getent passwd powercore | cut -d: -f6)
echo "powercore HOME: ${PC_HOME}"
ls -la "${PC_HOME}" || echo "WARN: could not list powercore HOME"

echo "--- Powercore packages (root pip) ---"
sudo python3.12 -m pip list 2>/dev/null | grep -i powercore \
  || echo "WARN: no powercore packages under root pip"

echo "--- Powercore packages (powercore user pip) ---"
sudo -u powercore python3.12 -m pip list 2>/dev/null | grep -i powercore \
  || echo "WARN: no powercore packages under powercore user pip"

echo "--- Locating powercore-worker binary ---"
for bin_path in /usr/local/bin/powercore-worker /usr/bin/powercore-worker \
                "${PC_HOME}/.local/bin/powercore-worker"; do
  [ -x "$bin_path" ] && echo "  Found: ${bin_path}" || echo "  Not found: ${bin_path}"
done

echo "--- Installed systemd unit files ---"
find "${PC_HOME}/.config/systemd/user/" -name "*.service" -o -name "*.target" \
  2>/dev/null | sort || echo "WARN: no unit files found"
