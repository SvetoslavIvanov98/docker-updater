#!/usr/bin/env bash
# install.sh — Installer for docker-updater script and systemd units
set -Eeuo pipefail

SCRIPT_NAME="docker-updater"
PREFIX="/usr/local"
BIN_DIR="$PREFIX/bin"
CONF_DIR="/etc"
SYSTEMD_DIR="/etc/systemd/system"
LOG_DIR="/var/log"
STATE_DIR="/var/lib/$SCRIPT_NAME"

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

install_file() {
  local src="$1" dst="$2" mode="$3"
  install -D -m "$mode" "$src" "$dst"
  echo "Installed $dst"
}

# Ensure dirs
mkdir -p "$BIN_DIR" "$CONF_DIR" "$SYSTEMD_DIR" "$LOG_DIR" "$STATE_DIR"

# Script
install_file "$SRC_DIR/$SCRIPT_NAME.sh" "$BIN_DIR/$SCRIPT_NAME" 0755

# Default config if missing
CONF_FILE="$CONF_DIR/$SCRIPT_NAME.conf"
if [[ ! -f "$CONF_FILE" ]]; then
  cat >"$CONF_FILE" <<'EOF'
# docker-updater configuration
# Set to true to simulate actions without making changes
# DRY_RUN=false
# Set to false to skip pruning of dangling images
# PRUNE_UNUSED_IMAGES=true
# Space/comma-separated lists of container names
# ONLY_CONTAINERS=
# EXCLUDE_CONTAINERS=
# Update only compose projects or only standalone
# COMPOSE_ONLY=false
# STANDALONE_ONLY=false
# Log file path
# LOG_FILE=/var/log/docker-updater.log
# Stop timeout for graceful shutdown
# STOP_TIMEOUT=30
EOF
  echo "Created default config at $CONF_FILE"
fi

# Systemd unit and timer
cat >"$SYSTEMD_DIR/$SCRIPT_NAME.service" <<'EOF'
[Unit]
Description=Docker containers updater
Wants=docker.service
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/docker-updater
# Uncomment to use a non-root config file
# EnvironmentFile=-/etc/docker-updater.conf
# Allow using docker without TTY
StandardOutput=journal
StandardError=journal

# Hardening (relaxed because docker cli needs privileges)
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat >"$SYSTEMD_DIR/$SCRIPT_NAME.timer" <<'EOF'
[Unit]
Description=Run Docker updater daily

[Timer]
# Run daily at 03:30
OnCalendar=*-*-* 03:30:00
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
EOF

echo "Reloading systemd daemon"
systemctl daemon-reload

echo "Enabling and starting timer"
systemctl enable --now docker-updater.timer

echo "Install complete. Logs will appear via: journalctl -u docker-updater -f"
