# Docker Updater

A robust Bash script and systemd timer to automatically update Docker images and refresh containers daily.

## What it does

- Updates Docker Compose projects: `docker compose pull && docker compose up -d --remove-orphans`
- Updates standalone containers: pulls image and recreates container if the image changed, preserving settings
- Safe: single-run lock, logs to `/var/log/docker-updater.log`, dry-run mode
- Filters: include/exclude containers by name
- Prunes dangling images when done (optional)

## Requirements

- Linux with systemd
- Docker CLI and daemon
- jq
- docker compose plugin (recommended for compose projects)

## Quick install

Run the installer as root:

```bash
sudo bash install.sh
```

This installs:

- `/usr/local/bin/docker-updater`
- `/etc/docker-updater.conf` (if not present)
- systemd unit `docker-updater.service` and timer `docker-updater.timer` (daily at 03:30 + random delay up to 10m)

View timer status and next run time:

```bash
systemctl list-timers docker-updater.timer
```

Check logs:

```bash
journalctl -u docker-updater --since today
```

## Configuration

Edit `/etc/docker-updater.conf`:

```bash
# DRY_RUN=false
# PRUNE_UNUSED_IMAGES=true
# ONLY_CONTAINERS="name1 name2"
# EXCLUDE_CONTAINERS="name3 name4"
# COMPOSE_ONLY=false
# STANDALONE_ONLY=false
# LOG_FILE=/var/log/docker-updater.log
# STOP_TIMEOUT=30
```

Per-user config is also supported at `~/.config/docker-updater.conf`.

## Manual usage

You can run the script manually:

```bash
sudo /usr/local/bin/docker-updater --dry-run
```

Options:

- `-n, --dry-run`
- `--no-prune`
- `--only <names>`
- `--exclude <names>`
- `--compose-only` or `--standalone-only`
- `--log-file <path>`
- `--stop-timeout <secs>`

## Notes

- Compose projects are detected from running containers via the label `com.docker.compose.project` and updated from their original working directory and compose files.
- Standalone container recreation uses `docker inspect` to regenerate a `docker run` command. This is best-effort and covers common flags, env, volumes, ports, caps, labels, devices, tmpfs, shm-size, restart policy, etc.
- Images are pulled only for the specific platform by default.

## Uninstall

```bash
sudo systemctl disable --now docker-updater.timer
sudo rm -f /etc/systemd/system/docker-updater.timer /etc/systemd/system/docker-updater.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/docker-updater /etc/docker-updater.conf
```
