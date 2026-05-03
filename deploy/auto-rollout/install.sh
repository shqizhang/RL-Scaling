#!/usr/bin/env bash
# One-shot installer: copy the systemd user unit into ~/.config/systemd/user,
# enable it (so it survives reboot if linger is enabled), and start it.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_SRC="${SCRIPT_DIR}/rl-scaling-auto-rollout.service"
UNIT_DST="${HOME}/.config/systemd/user/rl-scaling-auto-rollout.service"

mkdir -p "${HOME}/.config/systemd/user"
cp "${UNIT_SRC}" "${UNIT_DST}"
chmod +x "${SCRIPT_DIR}/watch-and-rollout.sh" "${SCRIPT_DIR}/rollout-once.sh"

systemctl --user daemon-reload
systemctl --user enable --now rl-scaling-auto-rollout.service

echo
echo "Service installed. Inspect with:"
echo "  systemctl --user status rl-scaling-auto-rollout"
echo "  journalctl --user -u rl-scaling-auto-rollout -f"
echo
echo "To survive logout/reboot, enable user-service linger as root once:"
echo "  sudo loginctl enable-linger ${USER}"
