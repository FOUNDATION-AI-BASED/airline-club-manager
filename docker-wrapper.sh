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

Env vars:
  PROJECT_DIR_HOST      Host path to airline-club (default: /home/kali/airline-club)
  HOST_TOOLING_DIR      Host path to airline-club-2 (default: /home/kali/airline-club-2)
  IMAGE_NAME            Docker image name (default: airline-club-java8)
  CONTAINER_NAME        Container name (default: airline-club-runtime)
  EXTRA_PORTS           Additional -p mappings (macOS only), e.g. "-p 3306:3306"
EOF
}

ensure_built() {
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[INFO] Building image '$IMAGE_NAME'..."
    docker build -t "$IMAGE_NAME" "$(dirname "$0")"
  fi
}

ensure_started() {
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[INFO] Starting container '$CONTAINER_NAME'..."
    docker run -d --name "$CONTAINER_NAME" \
      $NETWORK_OPTS \
      $PORT_OPTS $EXTRA_PORTS \
      -v "$PROJECT_DIR_HOST":"$PROJECT_DIR_CONTAINER" \
      -v "$HOST_TOOLING_DIR":"$TOOLING_DIR_CONTAINER" \
      -w "$TOOLING_DIR_CONTAINER" \
      "$IMAGE_NAME"
  fi
}

cmd_build() {
  docker build -t "$IMAGE_NAME" "$(dirname "$0")"
}

cmd_start() {
  ensure_built
  ensure_started
  docker ps --filter name="$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

cmd_stop() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

cmd_shell() {
  ensure_built
  ensure_started
  docker exec -it "$CONTAINER_NAME" bash
}

in_container() {
  local args=("$@")
  ensure_built
  ensure_started
  docker exec -i "$CONTAINER_NAME" bash -lc "chmod +x ./$(basename \"$MANAGER_SCRIPT\"); JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 PATH=\"\$JAVA_HOME/bin:\$PATH\" ./$(basename \"$MANAGER_SCRIPT\") ${args[*]}"
}

cmd_menu() {
  ensure_built
  ensure_started
  docker exec -it "$CONTAINER_NAME" bash -lc "chmod +x ./$(basename \"$MANAGER_SCRIPT\"); JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64 PATH=\"\$JAVA_HOME/bin:\$PATH\" ./$(basename \"$MANAGER_SCRIPT\") menu"
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

main() {
  local cmd=${1:-}
  shift || true
  case "$cmd" in
    build)     cmd_build "$@" ;;
    start)     cmd_start "$@" ;;
    stop)      cmd_stop  "$@" ;;
    shell)     cmd_shell "$@" ;;
    menu)      cmd_menu  "$@" ;;
    install)   cmd_install "$@" ;;
    analyze)   cmd_analyze "$@" ;;
    logs)      cmd_logs "$@" ;;
    run)       cmd_run "$@" ;;
    *)         usage; exit 1 ;;
  esac
}

main "$@"
