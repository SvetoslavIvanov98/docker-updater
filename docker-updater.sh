#!/usr/bin/env bash
# docker-updater.sh — Update Docker images and gracefully refresh containers
#
# Features
# - Updates Docker Compose projects (pull + up -d --remove-orphans)
# - Updates standalone containers by pulling images and recreating when image changed
# - Safe lock to avoid concurrent runs, logging, dry-run support, include/exclude filters
# - Optional config at /etc/docker-updater.conf or ~/.config/docker-updater.conf
#
# Requirements: docker, jq. docker compose (plugin) recommended for compose-managed containers.

set -Eeuo pipefail

VERSION="1.0.0"
SCRIPT_NAME="docker-updater"
DEFAULT_LOG_FILE="/var/log/${SCRIPT_NAME}.log"
BACKUP_DIR="/var/lib/${SCRIPT_NAME}/backups"
LOCK_DIR_PRIMARY="/run/lock"
LOCK_DIR_FALLBACK="/tmp"
LOCK_FILE_NAME="${SCRIPT_NAME}.lock"

# Defaults (can be overridden by config or flags)
DRY_RUN=${DRY_RUN:-false}
PRUNE_UNUSED_IMAGES=${PRUNE_UNUSED_IMAGES:-true}
ONLY_CONTAINERS=${ONLY_CONTAINERS:-}
EXCLUDE_CONTAINERS=${EXCLUDE_CONTAINERS:-}
COMPOSE_ONLY=${COMPOSE_ONLY:-false}
STANDALONE_ONLY=${STANDALONE_ONLY:-false}
LOG_FILE=${LOG_FILE:-"$DEFAULT_LOG_FILE"}
STOP_TIMEOUT=${STOP_TIMEOUT:-30}
PULL_ALL_PLATFORMS=${PULL_ALL_PLATFORMS:-false}
ONLY_PROJECTS=${ONLY_PROJECTS:-}
EXCLUDE_PROJECTS=${EXCLUDE_PROJECTS:-}

# Colors for terminal (disabled when not a TTY)
if [[ -t 1 ]]; then
  C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''; C_RESET=''
fi

log_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()    { printf '%s [%s] %s\n' "$(log_ts)" "$1" "${*:2}" | tee -a "$LOG_FILE" >&2; }
info()   { log INFO "$@"; }
warn()   { log WARN "$@"; }
error()  { log ERROR "$@"; }
success(){ log OK   "$@"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Missing dependency: $1"
    exit 1
  fi
}

ensure_dirs() {
  # Ensure log and backup directories
  local log_dir
  log_dir=$(dirname -- "$LOG_FILE")
  if [[ ! -d "$log_dir" ]]; then
    mkdir -p "$log_dir" 2>/dev/null || true
  fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
}

load_config() {
  local xdg=${XDG_CONFIG_HOME:-"$HOME/.config"}
  local cfg_candidates=(
    "/etc/${SCRIPT_NAME}.conf"
    "${xdg}/${SCRIPT_NAME}.conf"
    "${xdg}/${SCRIPT_NAME}/${SCRIPT_NAME}.conf"
  )
  for cfg in "${cfg_candidates[@]}"; do
    if [[ -f "$cfg" ]]; then
      # shellcheck disable=SC1090
      source "$cfg"
      info "Loaded config: $cfg"
      break
    fi
  done
}

show_help() {
  cat <<EOF
$SCRIPT_NAME v$VERSION — Update Docker containers and Compose projects

Usage: $0 [options]

Options:
  -n, --dry-run            Show actions without executing
  --no-prune               Do not prune dangling images after update
  --only CONTAINERS        Space/comma-separated list of container names to update only
  --exclude CONTAINERS     Space/comma-separated list of container names to skip
  --compose-only           Only update docker compose projects
  --standalone-only        Only update standalone (non-compose) containers
  --only-projects NAMES    Space/comma-separated list of compose project names to update only
  --exclude-projects NAMES Space/comma-separated list of compose project names to skip
  --log-file PATH          Write logs to PATH (default: $DEFAULT_LOG_FILE)
  --stop-timeout SECS      Timeout for docker stop (default: $STOP_TIMEOUT)
  -h, --help               Show this help
  -v, --version            Print version

Config file (optional): /etc/${SCRIPT_NAME}.conf or ~/.config/${SCRIPT_NAME}.conf
Supported variables: DRY_RUN, PRUNE_UNUSED_IMAGES, ONLY_CONTAINERS, EXCLUDE_CONTAINERS,
COMPOSE_ONLY, STANDALONE_ONLY, ONLY_PROJECTS, EXCLUDE_PROJECTS, LOG_FILE, STOP_TIMEOUT
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run) DRY_RUN=true; shift;;
      --no-prune) PRUNE_UNUSED_IMAGES=false; shift;;
      --only) ONLY_CONTAINERS=${2:-}; shift 2;;
      --exclude) EXCLUDE_CONTAINERS=${2:-}; shift 2;;
      --compose-only) COMPOSE_ONLY=true; shift;;
      --standalone-only) STANDALONE_ONLY=true; shift;;
  --only-projects) ONLY_PROJECTS=${2:-}; shift 2;;
  --exclude-projects) EXCLUDE_PROJECTS=${2:-}; shift 2;;
      --log-file) LOG_FILE=${2:-"$DEFAULT_LOG_FILE"}; shift 2;;
      --stop-timeout) STOP_TIMEOUT=${2:-30}; shift 2;;
      -h|--help) show_help; exit 0;;
      -v|--version) echo "$VERSION"; exit 0;;
      *) error "Unknown argument: $1"; show_help; exit 2;;
    esac
  done
}

acquire_lock() {
  local lock_dir="$LOCK_DIR_PRIMARY"
  if [[ ! -w "$lock_dir" ]]; then lock_dir="$LOCK_DIR_FALLBACK"; fi
  local lock_file="$lock_dir/$LOCK_FILE_NAME"
  exec 9>"$lock_file" || { error "Cannot open lock file $lock_file"; exit 1; }
  if ! flock -n 9; then
    warn "Another $SCRIPT_NAME is already running. Exiting."
    exit 0
  fi
}

check_docker_access() {
  if ! docker info >/dev/null 2>&1; then
    error "Cannot access Docker. Ensure Docker is running and you have permission (root or in docker group)."
    exit 1
  fi
}

# Convert comma/space/semicolon-separated to array
split_list() {
  local s=${1:-}
  s=${s//,/ } ; s=${s//;/ } ; s=${s//$'\n'/ } ; s=${s//$'\t'/ }
  echo "$s"
}

in_list() {
  local needle="$1"; shift
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

should_process_container() {
  local name="$1"
  local only_list exclude_list
  only_list=( $(split_list "$ONLY_CONTAINERS") )
  exclude_list=( $(split_list "$EXCLUDE_CONTAINERS") )
  if [[ -n "$ONLY_CONTAINERS" ]] && ! in_list "$name" "${only_list[@]}"; then
    return 1
  fi
  if [[ -n "$EXCLUDE_CONTAINERS" ]] && in_list "$name" "${exclude_list[@]}"; then
    return 1
  fi
  return 0
}

should_process_project() {
  local name="$1"
  local only_list exclude_list
  only_list=( $(split_list "$ONLY_PROJECTS") )
  exclude_list=( $(split_list "$EXCLUDE_PROJECTS") )
  if [[ -n "$ONLY_PROJECTS" ]] && ! in_list "$name" "${only_list[@]}"; then
    return 1
  fi
  if [[ -n "$EXCLUDE_PROJECTS" ]] && in_list "$name" "${exclude_list[@]}"; then
    return 1
  fi
  return 0
}

pull_image_if_needed() {
  local image_ref="$1"
  if [[ "$PULL_ALL_PLATFORMS" == true ]]; then
    drun docker pull --all-tags "$image_ref"
  else
    drun docker pull "$image_ref"
  fi
}

drun() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] $*" | tee -a "$LOG_FILE"
  else
    "$@"
  fi
}

# Update Compose projects by label on running containers
update_compose_projects() {
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    warn "docker compose not available; skipping Compose projects"
    return 0
  fi

  # Gather unique projects from running containers
  local projects
  projects=$(docker ps --format '{{.ID}}' | xargs -r docker inspect \
    --format '{{ index .Config.Labels "com.docker.compose.project" }}|{{ index .Config.Labels "com.docker.compose.project.working_dir" }}|{{ index .Config.Labels "com.docker.compose.project.config_files" }}' \
    | awk -F '|' 'NF>=2 && $1!="" && $2!="" {print $0}' | sort -u) || true

  [[ -z "$projects" ]] && { info "No Compose projects detected"; return 0; }

  IFS=$'\n' read -r -d '' -a proj_lines < <(printf '%s\0' "$projects") || true
  for line in "${proj_lines[@]}"; do
    IFS='|' read -r project wdir cfgs <<<"$line"
    [[ -z "$project" || -z "$wdir" ]] && continue

    # Respect project filters
    if ! should_process_project "$project"; then
      info "Skipping Compose project (filtered): $project"
      continue
    fi

    # Normalize config files list: support ; or , or space separators
    local cfg_args=( ) cfg_files=( )
    local sep_repl
    sep_repl=${cfgs//;/ } ; sep_repl=${sep_repl//,/ }
    for f in $sep_repl; do
      [[ -z "$f" ]] && continue
      cfg_args+=( -f "$f" )
      cfg_files+=( "$f" )
    done

    if [[ "$COMPOSE_ONLY" == false && "$STANDALONE_ONLY" == true ]]; then
      continue
    fi

    local run_dir="$wdir"
    if [[ ! -d "$run_dir" ]]; then
      # Fallback: if we have absolute config files that exist, use the first one's directory
      local alt_dir=""
      for cf in "${cfg_files[@]}"; do
        if [[ "$cf" = /* && -f "$cf" ]]; then
          alt_dir=$(dirname -- "$cf")
          break
        fi
      done
      if [[ -n "$alt_dir" && -d "$alt_dir" ]]; then
        run_dir="$alt_dir"
        info "Working dir missing; using config dir for '$project': $run_dir"
      else
        warn "Working dir for project '$project' not found: $wdir"
        continue
      fi
    fi

    info "Updating Compose project '$project' in $run_dir"
    (
      cd "$run_dir"
      # Ensure compose variable interpolation has needed env vars
      if [[ -f .env ]]; then
        # Export variables from .env without failing the whole script on minor issues
        set +e
        set -a
        # shellcheck disable=SC1091
        . ./.env
        set +a
        set -e
      fi
      if [[ ${#cfg_args[@]} -gt 0 ]]; then
        drun docker compose "${cfg_args[@]}" pull
        drun docker compose "${cfg_args[@]}" up -d --remove-orphans
      else
        drun docker compose pull
        drun docker compose up -d --remove-orphans
      fi
    )
    success "Compose project '$project' updated"
  done
}

# Generate docker run command array from container inspect (best-effort)
# Outputs a bash array declaration: RUN_CMD=(docker run ...)
# Globals used: STOP_TIMEOUT
generate_run_cmd_from_inspect() {
  local inspect_json="$1"

  # Basic fields
  local name image_ref hostname user workdir net_mode restart_name restart_max
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$inspect_json")
  image_ref=$(jq -r '.[0].Config.Image' <<<"$inspect_json")
  hostname=$(jq -r '.[0].Config.Hostname // empty' <<<"$inspect_json")
  user=$(jq -r '.[0].Config.User // empty' <<<"$inspect_json")
  workdir=$(jq -r '.[0].Config.WorkingDir // empty' <<<"$inspect_json")
  net_mode=$(jq -r '.[0].HostConfig.NetworkMode // "bridge"' <<<"$inspect_json")
  restart_name=$(jq -r '.[0].HostConfig.RestartPolicy.Name // empty' <<<"$inspect_json")
  restart_max=$(jq -r '.[0].HostConfig.RestartPolicy.MaximumRetryCount // 0' <<<"$inspect_json")

  # Start building array
  echo 'RUN_CMD=(docker run -d)'
  printf 'RUN_CMD+=("--name" %q)\n' "$name"
  if [[ -n "$hostname" ]]; then printf 'RUN_CMD+=("--hostname=%s")\n' "$hostname"; fi
  if [[ -n "$user" ]]; then printf 'RUN_CMD+=("--user=%s")\n' "$user"; fi
  if [[ -n "$workdir" ]]; then printf 'RUN_CMD+=("--workdir=%s")\n' "$workdir"; fi
  if [[ -n "$net_mode" && "$net_mode" != "default" ]]; then printf 'RUN_CMD+=("--network=%s")\n' "$net_mode"; fi
  if [[ -n "$restart_name" && "$restart_name" != "no" ]]; then
    if [[ "$restart_name" == "on-failure" && "$restart_max" -gt 0 ]]; then
      printf 'RUN_CMD+=("--restart=on-failure:%s")\n' "$restart_max"
    else
      printf 'RUN_CMD+=("--restart=%s")\n' "$restart_name"
    fi
  fi

  # Privileged
  local privileged
  privileged=$(jq -r '.[0].HostConfig.Privileged' <<<"$inspect_json")
  if [[ "$privileged" == "true" ]]; then echo 'RUN_CMD+=("--privileged")'; fi

  # Capabilities
  jq -r '.[0].HostConfig.CapAdd[]? | @sh "--cap-add=\(.)"' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done
  jq -r '.[0].HostConfig.CapDrop[]? | @sh "--cap-drop=\(.)"' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Extra hosts
  jq -r '.[0].HostConfig.ExtraHosts[]? | @sh "--add-host=\(.)"' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Ports
  jq -r '
    .[0].HostConfig.PortBindings // {} | to_entries[]? |
    .key as $cport |
    .value[]? | [(.HostIp // ""), (.HostPort // ""), $cport] |
    @sh ("--publish=\(if .[0] != "" then .[0] + ":" else "" end)\(if .[1] != "" then .[1] + ":" else "" end)\(.[2])")
  ' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Volumes & mounts
  jq -r '
    .[0].Mounts[]? | 
    if .Type == "bind" then
      @sh ("--volume=\(.Source):\(.Destination)\(if .RW then "" else ":ro" end)")
    elif .Type == "volume" then
      @sh ("--volume=\(.Name):\(.Destination)\(if .RW then "" else ":ro" end)")
    elif .Type == "tmpfs" then
      @sh ("--tmpfs=\(.Destination)")
    else empty end
  ' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Devices
  jq -r '
    .[0].HostConfig.Devices[]? | @sh "--device=\(.PathOnHost):\(.PathInContainer):\(.CgroupPermissions)"
  ' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Shm size
  local shm_size
  shm_size=$(jq -r '.[0].HostConfig.ShmSize // 0' <<<"$inspect_json")
  if [[ "$shm_size" -gt 0 ]]; then printf 'RUN_CMD+=("--shm-size=%s")\n' "$shm_size"; fi

  # Environment
  jq -r '.[0].Config.Env[]? | @sh "--env=\(.)"' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Labels (avoid compose labels to prevent accidental coupling)
  jq -r '
    .[0].Config.Labels // {} | to_entries[]? | select(.key|test("^com\\.docker\\.compose\\." )|not) |
    @sh "--label=\(.key)=\(.value)"
  ' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done

  # Entrypoint
  local entrypoint
  entrypoint=$(jq -cr '.[0].Config.Entrypoint // empty' <<<"$inspect_json")
  if [[ -n "$entrypoint" && "$entrypoint" != "null" ]]; then
    # Join array into a single string
    local ep
    ep=$(jq -r '.[0].Config.Entrypoint | @sh join(" ")' <<<"$inspect_json")
    echo 'RUN_CMD+=("--entrypoint")'
    printf 'RUN_CMD+=(%s)\n' "$ep"
  fi

  # Image
  printf 'RUN_CMD+=(%q)\n' "$image_ref"

  # Command
  jq -r '.[0].Config.Cmd[]? | @sh "\(.)"' <<<"$inspect_json" | while IFS= read -r line; do printf 'RUN_CMD+=(%s)\n' "$line"; done
}

recreate_container_if_needed() {
  local cid="$1"
  local inspect_json
  inspect_json=$(docker inspect "$cid")
  if ! jq -e '.[0] | objects' >/dev/null 2>&1 <<<"$inspect_json"; then
    warn "Failed to parse inspect JSON for $cid; skipping"
    return 0
  fi
  local name image_ref curr_img_id latest_img_id
  name=$(jq -r '.[0].Name | ltrimstr("/")' <<<"$inspect_json")
  image_ref=$(jq -r '.[0].Config.Image' <<<"$inspect_json")

  # Current container image ID
  curr_img_id=$(jq -r '.[0].Image' <<<"$inspect_json")

  info "Checking $name ($image_ref)"
  # Pull latest image
  pull_image_if_needed "$image_ref" || warn "Failed to pull $image_ref"

  # Latest image ID
  latest_img_id=$(docker image inspect "$image_ref" --format '{{.Id}}' 2>/dev/null || echo "")
  if [[ -z "$latest_img_id" ]]; then
    warn "Image not found after pull: $image_ref"
    return 0
  fi

  if [[ "$curr_img_id" == "$latest_img_id" ]]; then
    info "Up-to-date: $name"
    return 0
  fi

  info "Updating container: $name (image changed)"
  local backup_file="$BACKUP_DIR/${name}_$(date +%Y%m%d%H%M%S).run.sh"

  # Build run command array from inspect
  local gen
  gen=$(generate_run_cmd_from_inspect "$inspect_json")

  # Write backup script
  {
    echo "#!/usr/bin/env bash"
    echo "set -Eeuo pipefail"
    echo "# Regenerate and run container $name"
    echo "$gen"
    echo 'printf "Regenerating container: %s\\n"' "$name"
    echo 'printf "Command:"; for a in "${RUN_CMD[@]}"; do printf " %q" "$a"; done; echo'
    echo 'exec "${RUN_CMD[@]}"'
  } >"$backup_file"
  chmod +x "$backup_file"
  info "Saved recreate command: $backup_file"

  # Stop and remove old container
  drun docker stop --time "$STOP_TIMEOUT" "$name" || true
  drun docker rm "$name" || true

  # shellcheck disable=SC1090
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would run: $backup_file" | tee -a "$LOG_FILE"
  else
    source "$backup_file"
  fi

  success "Container refreshed: $name"
}

update_standalone_containers() {
  local ids names
  ids=$(docker ps --format '{{.ID}}') || true
  [[ -z "$ids" ]] && { info "No running containers"; return 0; }

  local processed=0
  while IFS= read -r cid; do
    local name
    name=$(docker inspect --format '{{.Name}}' "$cid" | sed 's#^/##')

    # Skip compose-managed containers
    local is_compose
    is_compose=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$cid" 2>/dev/null || true)
    if [[ -n "$is_compose" ]]; then
      continue
    fi

    if ! should_process_container "$name"; then
      info "Skipping (filtered): $name"
      continue
    fi

    recreate_container_if_needed "$cid" || warn "Failed to process $name"
    processed=$((processed+1))
  done <<<"$ids"

  info "Standalone containers processed: $processed"
}

prune_images() {
  if [[ "$PRUNE_UNUSED_IMAGES" == true ]]; then
    info "Pruning dangling images"
    drun docker image prune -f || true
  fi
}

main() {
  load_config
  parse_args "$@"
  ensure_dirs
  acquire_lock

  need_cmd docker
  need_cmd jq
  check_docker_access

  info "Starting $SCRIPT_NAME v$VERSION"

  if [[ "$STANDALONE_ONLY" == true && "$COMPOSE_ONLY" == true ]]; then
    error "Cannot set both --compose-only and --standalone-only"
    exit 2
  fi

  # Perform updates
  if [[ "$STANDALONE_ONLY" != true ]]; then
    update_compose_projects
  fi
  if [[ "$COMPOSE_ONLY" != true ]]; then
    update_standalone_containers
  fi

  prune_images
  success "All done"
}

main "$@"
