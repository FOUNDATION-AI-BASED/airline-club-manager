#!/usr/bin/env bash
set -euo pipefail

# docker-wrapper.sh
# Build a Docker image and run airline-club manager inside a container.
# Provides subcommands to install, analyze, run menu, and tail logs from the host-mounted project.

IMAGE_NAME="airline-club-java8"
CONTAINER_NAME="airline-club-runtime"
PROJECT_DIR_HOST="${PROJECT_DIR_HOST:-/home/kali/airline-club}"
PROJECT_DIR_CONTAINER="/workspace/airline-club"
HOST_TOOLING_DIR="${HOST_TOOLING_DIR:-/home/kali/airline-club-2}"
TOOLING_DIR_CONTAINER="/workspace/airline-club-2"
MANAGER_SCRIPT="airline-club-manager.sh"
LOG_FILES=("datainit.log" "repair.out" "simulation.log" "webserver.log")

# Cross-platform networking defaults
OS_NAME="$(uname -s)"
NETWORK_OPTS=""
PORT_OPTS=""
EXTRA_PORTS="${EXTRA_PORTS:-}"
if [[ "$OS_NAME" == "Darwin" ]]; then
  # Docker Desktop for macOS does not support --network host
  NETWORK_OPTS=""
  # Publish common server ports so you can reach them via localhost
  PORT_OPTS="-p 9000:9000 -p 7777:7777"
else
  # Linux: use host networking so container can access services on 127.0.0.1
  NETWORK_OPTS="--network host"
  PORT_OPTS=""
fi

# Sudo-aware Docker invoker
DOCKER=()
detect_docker() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
      DOCKER=(sudo docker)
      return 0
    else
      # Fallback to sudo docker (may prompt for password)
      DOCKER=(sudo docker)
      return 0
    fi
  fi
  echo "[ERROR] Docker is not accessible. Install Docker or run with appropriate privileges."
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  build                 Build Docker image
  start                 Start container (detached) with host project mounted
  stop                  Stop and remove container
  shell                 Open interactive shell in running container
  menu                  Run installer menu inside container
  install               Run full installation flow inside container
  analyze               Run analyze & repair inside container
  logs [file]           Tail logs from host project (default: all known logs)
  run <args...>         Pass-through to airline-club-manager.sh inside container
  build-install         Build image, run install inside container, then commit to a new tag
  push [repo] [tag]     Tag committed image and push to Docker registry (e.g., docker.io/user/airline-club-java8 installed)

Env vars:
  PROJECT_DIR_HOST      Host path to airline-club (default: /home/kali/airline-club)
  HOST_TOOLING_DIR      Host path to airline-club-2 (default: /home/kali/airline-club-2)
  IMAGE_NAME            Docker image name (default: airline-club-java8)
  CONTAINER_NAME        Container name (default: airline-club-runtime)
  EXTRA_PORTS           Additional -p mappings (macOS only), e.g. "-p 3306:3306"
  INSTALLED_TAG         Tag name for committed image (default: installed)
  PUSH_REPO             Registry repository (e.g., docker.io/user/airline-club-java8)
  PUSH_TAG              Tag to push (default: installed)
  DOCKER_USERNAME       Registry username for login (optional)
  DOCKER_PASSWORD       Registry password/token for login (optional)

Tip: Run without arguments to open an interactive menu (1=Build, 2=Start, ...). If Docker requires elevated rights, this script will automatically try 'sudo'.
EOF
}

ensure_built() {
  detect_docker
  if ! "${DOCKER[@]}" image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[INFO] Building image '$IMAGE_NAME'..."
    "${DOCKER[@]}" build -t "$IMAGE_NAME" "$(dirname "$0")"
  fi
}

ensure_started() {
  detect_docker
  if ! "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[INFO] Starting container '$CONTAINER_NAME'..."
    "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
      $NETWORK_OPTS \
      $PORT_OPTS $EXTRA_PORTS \
      -v "$PROJECT_DIR_HOST":"$PROJECT_DIR_CONTAINER" \
      -v "$HOST_TOOLING_DIR":"$TOOLING_DIR_CONTAINER" \
      -w "$TOOLING_DIR_CONTAINER" \
      "$IMAGE_NAME"
  fi
}

cmd_build() {
  detect_docker
  "${DOCKER[@]}" build -t "$IMAGE_NAME" "$(dirname "$0")"
}

cmd_start() {
  ensure_built
  ensure_started
  detect_docker
  "${DOCKER[@]}" ps --filter name="$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

cmd_stop() {
  detect_docker
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

cmd_shell() {
  ensure_built
  ensure_started
  detect_docker
  "${DOCKER[@]}" exec -it "$CONTAINER_NAME" bash
}

in_container() {
  local args=("$@")
  ensure_built
  ensure_started
  detect_docker
  "${DOCKER[@]}" exec -i "$CONTAINER_NAME" bash -lc "chmod +x ./$(basename \"$MANAGER_SCRIPT\"); JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 PATH=\"\$JAVA_HOME/bin:\$PATH\" ./$(basename \"$MANAGER_SCRIPT\") ${args[*]}"
}

cmd_menu() {
  ensure_built
  ensure_started
  detect_docker
  "${DOCKER[@]}" exec -it "$CONTAINER_NAME" bash -lc "chmod +x ./$(basename \"$MANAGER_SCRIPT\"); JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 PATH=\"\$JAVA_HOME/bin:\$PATH\" ./$(basename \"$MANAGER_SCRIPT\") menu"
}

cmd_install() {
  in_container install
}

cmd_analyze() {
  in_container analyze
}

cmd_run() {
  in_container "$@"
}

cmd_logs() {
  local chosen=${1:-}
  if [[ -n "$chosen" ]]; then
    local file="$PROJECT_DIR_HOST/$chosen"
    if [[ -f "$file" ]]; then
      echo "[TAIL] $file" && tail -n +1 -f "$file"
    else
      echo "[ERROR] Log file not found: $file" && exit 1
    fi
  else
    echo "[INFO] Tailing common logs in $PROJECT_DIR_HOST"
    for log in "${LOG_FILES[@]}"; do
      local file="$PROJECT_DIR_HOST/$log"
      if [[ -f "$file" ]]; then
        echo "===== TAILING $file ====="
        tail -n +1 -f "$file" &
      else
        echo "[WARN] Missing log: $file"
      fi
    done
    wait
  fi
}

# Build + Install (in container) + Commit image
cmd_build_install() {
  local installed_tag="${INSTALLED_TAG:-installed}"
  ensure_built
  ensure_started
  echo "[INFO] Running installation inside container (HOME=/opt to bake into image)..."
  detect_docker
  "${DOCKER[@]}" exec -i "$CONTAINER_NAME" bash -lc "export HOME=/opt; chmod +x ./$(basename \"$MANAGER_SCRIPT\"); JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 PATH=\"\$JAVA_HOME/bin:\$PATH\" ./$(basename \"$MANAGER_SCRIPT\") install"
  echo "[INFO] Committing container '$CONTAINER_NAME' to image '$IMAGE_NAME:$installed_tag'..."
  "${DOCKER[@]}" commit "$CONTAINER_NAME" "$IMAGE_NAME:$installed_tag"
  echo "[DONE] Image committed: $IMAGE_NAME:$installed_tag"
}

# Tag & Push to registry
cmd_push() {
  detect_docker
  local default_tag="${INSTALLED_TAG:-installed}"
  local repo="${1:-${PUSH_REPO:-}}"
  local tag="${2:-${PUSH_TAG:-$default_tag}}"
  if [[ -z "$repo" ]]; then
    echo "[ERROR] No repository specified. Provide PUSH_REPO env or pass 'push <repo> [tag]'."
    echo "Example: push docker.io/username/airline-club-java8 installed"
    exit 1
  fi
  echo "[INFO] Tagging '$IMAGE_NAME:$default_tag' as '$repo:$tag'..."
  "${DOCKER[@]}" tag "$IMAGE_NAME:$default_tag" "$repo:$tag"

  if [[ -n "${DOCKER_USERNAME:-}" && -n "${DOCKER_PASSWORD:-}" ]]; then
    # Try to infer registry server from repo (first path segment if it looks like a domain)
    local registry_server
    registry_server=$(printf "%s" "$repo" | cut -d'/' -f1)
    if [[ "$registry_server" == *.* ]]; then
      echo "[INFO] Logging into registry '$registry_server' as '$DOCKER_USERNAME'..."
      printf "%s" "$DOCKER_PASSWORD" | "${DOCKER[@]}" login "$registry_server" -u "$DOCKER_USERNAME" --password-stdin || true
    else
      echo "[INFO] Logging into default registry as '$DOCKER_USERNAME'..."
      printf "%s" "$DOCKER_PASSWORD" | "${DOCKER[@]}" login -u "$DOCKER_USERNAME" --password-stdin || true
    fi
  fi

  echo "[INFO] Pushing '$repo:$tag'..."
  "${DOCKER[@]}" push "$repo:$tag"
}

interactive_menu() {
  while true; do
    echo ""
    echo "=== Airline-Club Docker Wrapper ==="
    echo "1) Build image"
    echo "2) Start container"
    echo "3) Stop container"
    echo "4) Open shell in container"
    echo "5) Run installer menu in container"
    echo "6) Install (full setup)"
    echo "7) Analyze & Repair"
    echo "8) Tail logs"
    echo "9) Run custom manager args"
    echo "10) Build + Install + Commit image"
    echo "11) Tag & Push to registry"
    echo "0) Exit"
    read -r -p "Select an option: " choice
    case "$choice" in
      1) cmd_build ;;
      2) cmd_start ;;
      3) cmd_stop  ;;
      4) cmd_shell ;;
      5) cmd_menu  ;;
      6) cmd_install ;;
      7) cmd_analyze ;;
      8)
        read -r -p "Enter log filename (or leave blank for all): " lf
        if [[ -n "$lf" ]]; then
          cmd_logs "$lf"
        else
          cmd_logs
        fi
        ;;
      9)
        read -r -p "Enter manager args (e.g., 'install' or 'analyze'): " line
        # shellcheck disable=SC2206
        ARGS=( $line )
        cmd_run "${ARGS[@]}"
        ;;
      10)
        cmd_build_install
        ;;
      11)
        read -r -p "Enter registry repo (e.g., docker.io/username/airline-club-java8): " repo
        read -r -p "Enter tag (default: installed): " tag
        if [[ -z "$tag" ]]; then tag="installed"; fi
        cmd_push "$repo" "$tag"
        ;;
      0) exit 0 ;;
      *) echo "[WARN] Invalid selection" ;;
    esac
  done
}

main() {
  local cmd=${1:-}
  shift || true
  if [[ -z "$cmd" ]]; then
    interactive_menu
    return 0
  fi
  case "$cmd" in
    build)           cmd_build "$@" ;;
    start)           cmd_start "$@" ;;
    stop)            cmd_stop  "$@" ;;
    shell)           cmd_shell "$@" ;;
    menu)            cmd_menu  "$@" ;;
    install)         cmd_install "$@" ;;
    analyze)         cmd_analyze "$@" ;;
    logs)            cmd_logs "$@" ;;
    run)             cmd_run "$@" ;;
    build-install)   cmd_build_install "$@" ;;
    push)            cmd_push "$@" ;;
    *)               usage; exit 1 ;;
  esac
}

main "$@"
