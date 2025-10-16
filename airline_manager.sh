#!/usr/bin/env bash
# Airline Manager Shell Wrapper
# - Ensures a suitable Python3 is installed
# - Creates/uses a virtualenv
# - Delegates install/start/stop/config actions to airline_manager.py (non-interactive)
# - Provides a friendly interactive menu for non-technical users

set -o pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
AIRLINE_MANAGER="$PROJECT_ROOT/airline_manager.py"
VENV_DIR="$PROJECT_ROOT/.venv"
LOG_DIR="$PROJECT_ROOT/logs"

# Detect sudo availability
if [ "$EUID" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi
else
  SUDO=""
fi

# Basic colors for nicer UI (fallback to empty if tput unavailable)
if command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_BLUE="$(tput setaf 4)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED="";
fi

ensure_dirs() {
  mkdir -p "$LOG_DIR"
}

# Return 0 (true) if $1 >= $2 in version sense, else return 1 (false)
version_ge() {
  local a="$1" b="$2"
  local first
  first="$(printf "%s\n%s" "$a" "$b" | sort -V | head -n1)"
  if [ "$first" = "$b" ]; then
    return 0
  else
    return 1
  fi
}

current_py_version() {
  python3 -V 2>/dev/null | awk '{print $2}'
}

install_python() {
  echo "Attempting to install Python3, pip, and venv using the system package manager..."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y python3 python3-pip python3-venv || { echo "Failed to install Python3 via apt-get. Please install Python 3.8+ manually."; return 1; }
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y python3 python3-pip || { echo "Failed to install Python3 via dnf. Please install Python 3.8+ manually."; return 1; }
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y python3 python3-pip || { echo "Failed to install Python3 via yum. Please install Python 3.8+ manually."; return 1; }
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm python python-pip || { echo "Failed to install Python via pacman. Please install Python 3.8+ manually."; return 1; }
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper install -y python3 python3-pip || { echo "Failed to install Python via zypper. Please install Python 3.8+ manually."; return 1; }
  else
    echo "Unsupported package manager. Please install Python 3.8+ manually and re-run."
    return 1
  fi
}

ensure_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    install_python || return 1
  fi
  ver="$(current_py_version)"
  if [ -z "$ver" ]; then
    echo "Could not determine python3 version."
    return 1
  fi
  if version_ge "$ver" "3.8"; then
    :
  else
    echo "Python3 version $ver is too old. Attempting to install a newer Python..."
    install_python || return 1
  fi
  return 0
}

ensure_venv() {
  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "Creating virtual environment at $VENV_DIR..."
    python3 -m venv "$VENV_DIR" || { echo "Failed to create virtualenv. Ensure python3-venv is installed."; return 1; }
  fi
}

venv_python() {
  printf "%s/bin/python" "$VENV_DIR"
}

run_manager() {
  local args=("$@")
  ensure_dirs || return 1
  ensure_python || return 1
  ensure_venv || return 1
  local PY
  PY="$(venv_python)"
  "$PY" "$AIRLINE_MANAGER" "${args[@]}"
}

print_usage() {
  cat <<EOF
${C_BOLD}Airline Manager Shell Wrapper${C_RESET}
Default: run ${C_GREEN}./airline_manager.sh${C_RESET} to open the interactive manager UI.

Advanced CLI usage:
  ./airline_manager.sh [command] [args]

Commands (delegated to airline_manager.py):
  full_install | install_deps | clone | checkout <branch> | publish_local | init_db
  start_web | stop_web | start_simulation | stop_simulation
  set_map_key <key> | config_host_port <host> <port> | config_banner <yes|no>
  config_elasticsearch <enabled:yes|no> <host> <port> | config_trusted_hosts <hosts>
  setup_reverse_proxy <domain> <backend_port> <cert_path> <key_path> [assets_path]
  resume_next | uninstall

Interactive menu:
  ./airline_manager.sh menu
EOF
}

# Simple status header (no Python dependency required)
draw_header() {
  if command -v clear >/dev/null 2>&1; then clear; else printf "\033c"; fi
  echo "${C_BLUE}${C_BOLD}==============================================${C_RESET}"
  echo "${C_BLUE}${C_BOLD}         Airline Manager (Interactive)        ${C_RESET}"
  echo "${C_BLUE}${C_BOLD}==============================================${C_RESET}"
  echo "Project: ${PROJECT_ROOT}"
  echo "Logs:    ${LOG_DIR}"
  if [ -f "$PROJECT_ROOT/manager_state.json" ]; then
    echo "State:   detected (manager_state.json)"
  else
    echo "State:   not initialized yet"
  fi
  echo ""
}

interactive_menu() {
  while true; do
    draw_header
    echo "${C_GREEN}Select an option:${C_RESET}"
    echo " ${C_YELLOW}1${C_RESET}) Full installation and configuration"
    echo " ${C_YELLOW}2${C_RESET}) Install dependencies (JDK, SBT, MySQL)"
    echo " ${C_YELLOW}3${C_RESET}) Clone repository"
    echo " ${C_YELLOW}4${C_RESET}) Checkout branch"
    echo " ${C_YELLOW}5${C_RESET}) Publish local"
    echo " ${C_YELLOW}6${C_RESET}) Initialize DB data"
    echo " ${C_YELLOW}7${C_RESET}) Start web server"
    echo " ${C_YELLOW}8${C_RESET}) Stop web server"
    echo " ${C_YELLOW}9${CRESET}) Start simulation"
    echo " ${C_YELLOW}10${C_RESET}) Stop simulation"
    echo " ${C_YELLOW}11${C_RESET}) Set Google Map API key"
    echo " ${C_YELLOW}12${C_RESET}) Configure host/port"
    echo " ${C_YELLOW}13${C_RESET}) Configure bannerEnabled"
    echo " ${C_YELLOW}14${C_RESET}) Configure Elasticsearch"
    echo " ${C_YELLOW}15${C_RESET}) Setup Nginx reverse proxy"
    echo " ${C_YELLOW}16${C_RESET}) Resume next step"
    echo " ${C_YELLOW}17${C_RESET}) Uninstall"
    echo " ${C_YELLOW}18${C_RESET}) Configure trusted hosts"
    echo " ${C_YELLOW}0${C_RESET}) Exit"
    read -r -p "Enter choice: " choice
    case "$choice" in
      1) run_manager full_install || true ;;
      2) run_manager install_deps || true ;;
      3) run_manager clone || true ;;
      4) read -r -p "Branch (default master): " br; [ -z "$br" ] && br="master"; run_manager checkout "$br" || true ;;
      5) run_manager publish_local || true ;;
      6) run_manager init_db || true ;;
      7) run_manager start_web || true ;;
      8) run_manager stop_web || true ;;
      9) run_manager start_simulation || true ;;
     10) run_manager stop_simulation || true ;;
     11) read -r -p "Google Map API key: " key; run_manager set_map_key "$key" || true ;;
     12) read -r -p "Host/address (default 0.0.0.0): " host; [ -z "$host" ] && host="0.0.0.0"; read -r -p "Port (default 9000): " port; [ -z "$port" ] && port="9000"; run_manager config_host_port "$host" "$port" || true ;;
     13) read -r -p "Enable banner? (yes/no, default no): " be; [ -z "$be" ] && be="no"; run_manager config_banner "$be" || true ;;
     14) read -r -p "Enable Elasticsearch? (yes/no, default no): " esen; [ -z "$esen" ] && esen="no"; if [ "$esen" = "yes" ]; then read -r -p "Elasticsearch host (default localhost): " esh; [ -z "$esh" ] && esh="localhost"; read -r -p "Elasticsearch port (default 9200): " esp; [ -z "$esp" ] && esp="9200"; else esh="localhost"; esp="9200"; fi; run_manager config_elasticsearch "$esen" "$esh" "$esp" || true ;;
     15) read -r -p "Domain (e.g., example.com): " domain; read -r -p "Backend port (default 9000): " bport; [ -z "$bport" ] && bport="9000"; read -r -p "SSL certificate path: " cert; read -r -p "SSL key path: " key; read -r -p "Assets path (default airline-web/public): " ap; run_manager setup_reverse_proxy "$domain" "$bport" "$cert" "$key" "$ap" || true ;;
     16) run_manager resume_next || true ;;
     17) run_manager uninstall || true ;;
     18) read -r -p "Comma-separated trusted hosts (e.g., localhost,127.0.0.1,example.com): " th; [ -z "$th" ] && th="localhost,127.0.0.1"; run_manager config_trusted_hosts "$th" || true ;;
      0) echo "Bye."; break ;;
      *) echo "${C_RED}Invalid choice.${C_RESET}"; sleep 1 ;;
    esac
  done
}

main() {
  if [ ! -f "$AIRLINE_MANAGER" ]; then
    echo "airline_manager.py not found at $AIRLINE_MANAGER"
    echo "Please ensure you are running this script from the project root."
    exit 1
  fi

  if [ $# -lt 1 ]; then
    interactive_menu
    exit 0
  fi

  case "$1" in
    menu)
      interactive_menu ;;
    full_install|install_deps|clone|publish_local|init_db|start_web|stop_web|start_simulation|stop_simulation|resume_next|uninstall)
      cmd="$1"; shift; run_manager "$cmd" "$@" ;;
    checkout|set_map_key|config_host_port|config_banner|config_elasticsearch|config_trusted_hosts|setup_reverse_proxy)
      cmd="$1"; shift; run_manager "$cmd" "$@" ;;
    *)
      print_usage ;;
  esac
}

main "$@"