#!/usr/bin/env bash
# Install a systemd user timer that runs scripts/status.sh every N seconds, so the GUI's
# system page stays fresh between backups. Run on the VM as the user that owns the deploy
# folder (must be in the docker group). No root needed, except for enabling "linger" once.
#
#   scripts/install-status-timer.sh          # every 30 seconds
#   scripts/install-status-timer.sh 15       # every 15 seconds
#   scripts/install-status-timer.sh --remove
#
# Check:  systemctl --user list-timers langrenn-status.timer
# Logs:   journalctl --user -u langrenn-status.service

set -euo pipefail

repo=$(readlink -f "$(dirname "$(readlink -f "$0")")/..")
unit_dir=${UNIT_DIR:-$HOME/.config/systemd/user}
name=langrenn-status

if [[ ${1:-} == --remove ]]; then
    systemctl --user disable --now "$name.timer" 2>/dev/null || true
    rm -f "$unit_dir/$name.service" "$unit_dir/$name.timer"
    systemctl --user daemon-reload
    echo "Removed $name.timer"
    exit 0
fi

interval=${1:-30}
if ! [[ $interval =~ ^[0-9]+$ ]] || ((interval < 5)); then
    echo "Usage: $0 [seconds >= 5] | --remove" >&2
    exit 2
fi

mkdir -p "$unit_dir"
cat > "$unit_dir/$name.service" <<EOF
[Unit]
Description=langrenn-sprint: refresh status/system.json for the GUI system page

[Service]
Type=oneshot
ExecStart=$repo/scripts/status.sh
EOF

cat > "$unit_dir/$name.timer" <<EOF
[Unit]
Description=langrenn-sprint: refresh status/system.json every ${interval}s

[Timer]
OnBootSec=${interval}s
OnUnitActiveSec=${interval}s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

[[ -n ${UNIT_DIR:-} ]] && { echo "Wrote units to $unit_dir (not enabled)"; exit 0; }

# Keep user services running after logout and across reboots.
if [[ $(loginctl show-user "$USER" --property=Linger --value 2>/dev/null) != yes ]]; then
    echo "Enabling linger for $USER (needs sudo once) ..."
    sudo loginctl enable-linger "$USER"
fi

systemctl --user daemon-reload
systemctl --user enable --now "$name.timer"
systemctl --user list-timers "$name.timer" --no-pager
