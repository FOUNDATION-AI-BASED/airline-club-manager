#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIRLINE_WEB_CONF="$ROOT_DIR/airline-web/conf/application.conf"
AIRLINE_DATA_CONF="$ROOT_DIR/airline-data/src/main/resources/application.conf"
CONSTANTS_SCALA="$ROOT_DIR/airline-data/src/main/scala/com/patson/data/Constants.scala"

db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"
db_user="${DB_USER:-}"
db_pass="${DB_PASS:-}"
db_name="${DB_NAME:-}"

die(){ printf "%s\n" "$*" >&2; exit 1; }

require_tools() {
  command -v mysqldump >/dev/null || die "mysqldump not found. Install MySQL client tools."
  command -v mysql >/dev/null || die "mysql client not found. Install MySQL client tools."
}

trim() { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

# --- Pretty printing helpers ---
color_init() {
  if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
  else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
  fi
}

print_title() {
  color_init
  printf "${BOLD}${BLUE}==============================================\n"; printf "  %s\n" "$1"; printf "==============================================${RESET}\n"
}

print_info() { color_init; printf "${CYAN}➤ %s${RESET}\n" "$*"; }
print_ok()   { color_init; printf "${GREEN}✔ %s${RESET}\n" "$*"; }
print_warn() { color_init; printf "${YELLOW}⚠ %s${RESET}\n" "$*"; }
print_err()  { color_init; printf "${RED}✖ %s${RESET}\n" "$*"; }

parse_conf() {
  if [[ -f "$AIRLINE_WEB_CONF" ]]; then
    local url_line
    url_line=$(grep -E '^db\.default\.url *= *"jdbc:mysql://' "$AIRLINE_WEB_CONF" || true)
    if [[ -n "$url_line" ]]; then
      local url hostportdb port_and_db
      url=$(echo "$url_line" | sed -E 's/.*"jdbc:mysql:\/\/([^"]+)".*/\1/')
      hostportdb="${url%%\?*}"
      [[ -z "$db_host" ]] && db_host="${hostportdb%%:*}"
      port_and_db="${hostportdb#*:}"
      [[ -z "$db_port" ]] && db_port="${port_and_db%%/*}"
      [[ -z "$db_name" ]] && db_name="${port_and_db#*/}"
    fi
    local user_line pass_line
    user_line=$(grep -E '^db\.default\.username' "$AIRLINE_WEB_CONF" || true)
    pass_line=$(grep -E '^db\.default\.password' "$AIRLINE_WEB_CONF" || true)
    [[ -z "$db_user" && -n "$user_line" ]] && db_user=$(trim "$(echo "$user_line" | awk -F= '{print $2}' | tr -d '"')")
    [[ -z "$db_pass" && -n "$pass_line" ]] && db_pass=$(trim "$(echo "$pass_line" | awk -F= '{print $2}' | tr -d '"')")
  fi

  if [[ -f "$AIRLINE_DATA_CONF" ]]; then
    local h u p s h_line u_line p_line s_line
    h_line=$(grep -E '^mysqldb\.host' "$AIRLINE_DATA_CONF" || true)
    u_line=$(grep -E '^mysqldb\.user' "$AIRLINE_DATA_CONF" || true)
    p_line=$(grep -E '^mysqldb\.password' "$AIRLINE_DATA_CONF" || true)
    s_line=$(grep -E '^mysqldb\.schema' "$AIRLINE_DATA_CONF" || true)
    h=$(echo "$h_line" | awk -F= '{print $2}' | tr -d ' "')
    u=$(echo "$u_line" | awk -F= '{print $2}' | tr -d ' "')
    p=$(echo "$p_line" | awk -F= '{print $2}' | tr -d ' "')
    s=$(echo "$s_line" | awk -F= '{print $2}' | tr -d ' "')
    [[ -z "$db_host" && -n "$h" ]] && db_host="$h"
    [[ -z "$db_user" && -n "$u" ]] && db_user="$u"
    [[ -z "$db_pass" && -n "$p" ]] && db_pass="$p"
    [[ -z "$db_name" && -n "$s" ]] && db_name="$s"
  fi

  if [[ -z "$db_name" && -f "$CONSTANTS_SCALA" ]]; then
    local s
    s=$(grep -E 'val SCHEMA_NAME' "$CONSTANTS_SCALA" | sed -E 's/.*"([^"]+)".*/\1/')
    [[ -n "$s" ]] && db_name="$s"
  fi

  db_port="${db_port:-3306}"
  db_name="${db_name:-airline_v2_1}"
  db_host="${db_host:-127.0.0.1}"
  db_user="${db_user:-sa}"
  db_pass="${db_pass:-testmysql}"
}

show_config() {
  printf "DB host: %s\n" "$db_host"
  printf "DB port: %s\n" "$db_port"
  printf "DB name: %s\n" "$db_name"
  printf "DB user: %s\n" "$db_user"
}

ensure_db_exists() {
  mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null
}

backup_sql() {
  require_tools
  parse_conf
  ensure_db_exists
  local out="${1:-}"
  local compress="${2:-0}"
  mkdir -p "$ROOT_DIR/backups"
  local ts fname
  ts=$(date +%Y%m%d_%H%M%S)
  fname="${out:-$ROOT_DIR/backups/${db_name}_${ts}.sql}"
  mysqldump -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" \
    --single-transaction --quick --routines --triggers --events --hex-blob --set-gtid-purged=OFF \
    --default-character-set=utf8mb4 "$db_name" > "$fname"
  if [[ "$compress" == "1" ]]; then
    gzip -f "$fname"
    fname="${fname}.gz"
  fi
  printf "Backup complete: %s\n" "$fname"
}

restore_sql() {
  require_tools
  parse_conf
  local file="$1"
  [[ -z "$file" ]] && die "Missing dump file"
  [[ ! -f "$file" ]] && die "Dump file not found: $file"
  local drop_first="${2:-0}"
  local fast="${3:-1}"
  if [[ "$drop_first" == "1" ]]; then
    mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" \
      -e "DROP DATABASE IF EXISTS \`$db_name\`; CREATE DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  else
    ensure_db_exists
  fi
  if [[ "$file" == *.gz ]]; then
    if [[ "$fast" == "1" ]]; then
      { printf "SET autocommit=0; SET unique_checks=0; SET foreign_key_checks=0; SET sql_log_bin=0;\n"; gunzip -c "$file"; printf "COMMIT; SET foreign_key_checks=1; SET unique_checks=1; SET autocommit=1;\n"; } | \
        mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name"
    else
      gunzip -c "$file" | mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name"
    fi
  else
    if [[ "$fast" == "1" ]]; then
      { printf "SET autocommit=0; SET unique_checks=0; SET foreign_key_checks=0; SET sql_log_bin=0;\n"; cat "$file"; printf "COMMIT; SET foreign_key_checks=1; SET unique_checks=1; SET autocommit=1;\n"; } | \
        mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name"
    else
      mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" "$db_name" < "$file"
    fi
  fi
  printf "Restore complete into database: %s\n" "$db_name"
}

prompt_overrides() {
  parse_conf
  if command -v whiptail >/dev/null 2>&1; then
    db_host=$(whiptail --title "DB Host" --inputbox "Enter DB host" 10 60 "$db_host" 3>&1 1>&2 2>&3) || true
    db_port=$(whiptail --title "DB Port" --inputbox "Enter DB port" 10 60 "$db_port" 3>&1 1>&2 2>&3) || true
    db_name=$(whiptail --title "DB Name" --inputbox "Enter DB name" 10 60 "$db_name" 3>&1 1>&2 2>&3) || true
    db_user=$(whiptail --title "DB User" --inputbox "Enter DB user" 10 60 "$db_user" 3>&1 1>&2 2>&3) || true
    db_pass=$(whiptail --title "DB Password" --passwordbox "Enter DB password" 10 60 3>&1 1>&2 2>&3) || true
  elif command -v dialog >/dev/null 2>&1; then
    tmp_out=$(mktemp)
    dialog --title "DB Host" --inputbox "Enter DB host" 10 60 "$db_host" 2>"$tmp_out" || true; db_host=$(cat "$tmp_out");
    dialog --title "DB Port" --inputbox "Enter DB port" 10 60 "$db_port" 2>"$tmp_out" || true; db_port=$(cat "$tmp_out");
    dialog --title "DB Name" --inputbox "Enter DB name" 10 60 "$db_name" 2>"$tmp_out" || true; db_name=$(cat "$tmp_out");
    dialog --title "DB User" --inputbox "Enter DB user" 10 60 "$db_user" 2>"$tmp_out" || true; db_user=$(cat "$tmp_out");
    dialog --title "DB Password" --passwordbox "Enter DB password" 10 60 2>"$tmp_out" || true; db_pass=$(cat "$tmp_out");
    rm -f "$tmp_out"
  else
    printf "Enter DB host [%s]: " "$db_host"; read -r inp; [[ -n "$inp" ]] && db_host="$inp"
    printf "Enter DB port [%s]: " "$db_port"; read -r inp; [[ -n "$inp" ]] && db_port="$inp"
    printf "Enter DB name [%s]: " "$db_name"; read -r inp; [[ -n "$inp" ]] && db_name="$inp"
    printf "Enter DB user [%s]: " "$db_user"; read -r inp; [[ -n "$inp" ]] && db_user="$inp"
    printf "Enter DB password [hidden]: "; read -rs inp; echo; [[ -n "$inp" ]] && db_pass="$inp"
  fi
}

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--backup [--gz] [--output FILE]] | [--restore FILE [--drop-first] [--no-fast]] | [--show-config] | [--interactive]

Environment overrides:
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS

Examples:
  $(basename "$0") --backup --gz
  $(basename "$0") --restore backups/airline_YYYYMMDD.sql --drop-first
  $(basename "$0") --show-config
EOF
}

test_connection() {
  if ! command -v mysql >/dev/null 2>&1; then print_err "mysql client not found"; return 1; fi
  parse_conf
  if mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" -e "SELECT VERSION();" >/dev/null 2>&1; then
    print_ok "Connection successful"
  else
    print_err "Connection failed. Check host/port/user/password."
    return 1
  fi
}

select_backup_file_tui() {
  local f
  if command -v whiptail >/dev/null 2>&1; then
    local items=()
    local files
    files=$(compgen -G "$ROOT_DIR/backups/*.sql"; compgen -G "$ROOT_DIR/backups/*.sql.gz" || true)
    local count=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      items+=("$count" "$line")
      count=$((count+1))
    done <<< "$files"
    items+=("custom" "Enter custom path")
    local choice
    choice=$(whiptail --title "Choose backup file" --menu "Select a file" 20 78 12 "${items[@]}" 3>&1 1>&2 2>&3) || return 1
    if [[ "$choice" == "custom" ]]; then
      f=$(whiptail --title "Backup file" --inputbox "Enter path to .sql/.gz" 10 60 3>&1 1>&2 2>&3) || return 1
    else
      # map index to file
      local i=0
      while IFS= read -r line; do
        [[ "$i" == "$choice" ]] && f="$line" && break
        i=$((i+1))
      done <<< "$files"
    fi
  elif command -v dialog >/dev/null 2>&1; then
    local tmp_out
    tmp_out=$(mktemp)
    dialog --title "Backup file" --inputbox "Enter path to .sql/.gz (or use backups folder)" 10 60 "$ROOT_DIR/backups/" 2>"$tmp_out" || { rm -f "$tmp_out"; return 1; }
    f=$(cat "$tmp_out"); rm -f "$tmp_out"
  else
    read -rp "SQL/SQL.gz file path: " f
  fi
  [[ -z "$f" ]] && return 1
  printf "%s" "$f"
}

interactive() {
  parse_conf
  if command -v whiptail >/dev/null 2>&1; then
    while true; do
      local choice
      choice=$(whiptail --title "Database Manager" --menu "Choose an option" 20 78 10 \
        "1" "Backup to SQL" \
        "2" "Backup to SQL.gz" \
        "3" "Restore from SQL" \
        "4" "Restore from SQL.gz" \
        "5" "Change DB settings" \
        "6" "Show config" \
        "7" "Test connection" \
        "0" "Exit" 3>&1 1>&2 2>&3) || exit 0
      case "$choice" in
        1) out=$(whiptail --title "Output file" --inputbox "Optional output path (.sql)" 10 60 3>&1 1>&2 2>&3) || out=""; whiptail --title "Backup" --infobox "Backing up..." 8 40; backup_sql "${out:-}" ; whiptail --title "Done" --msgbox "Backup completed" 8 40;;
        2) out=$(whiptail --title "Output file" --inputbox "Optional output path (.sql.gz)" 10 60 3>&1 1>&2 2>&3) || out=""; whiptail --title "Backup" --infobox "Backing up..." 8 40; backup_sql "${out:-}" "1" ; whiptail --title "Done" --msgbox "Backup completed" 8 40;;
        3) f=$(select_backup_file_tui) || continue; yn=$(whiptail --title "Drop first" --yesno "Drop & recreate database before restore?" 8 60 && echo yes || echo no); drop=0; [[ "$yn" == "yes" ]] && drop=1; whiptail --title "Restore" --infobox "Restoring..." 8 40; restore_sql "$f" "$drop" "1"; whiptail --title "Done" --msgbox "Restore completed" 8 40;;
        4) f=$(select_backup_file_tui) || continue; yn=$(whiptail --title "Drop first" --yesno "Drop & recreate database before restore?" 8 60 && echo yes || echo no); drop=0; [[ "$yn" == "yes" ]] && drop=1; whiptail --title "Restore" --infobox "Restoring..." 8 40; restore_sql "$f" "$drop" "1"; whiptail --title "Done" --msgbox "Restore completed" 8 40;;
        5) prompt_overrides;;
        6) whiptail --title "Current Config" --msgbox "Host: $db_host\nPort: $db_port\nDB: $db_name\nUser: $db_user" 12 60;;
        7) test_connection; sleep 1;;
        0) exit 0;;
      esac
    done
  elif command -v dialog >/dev/null 2>&1; then
    while true; do
      local tmp_out choice
      tmp_out=$(mktemp)
      dialog --title "Database Manager" --menu "Choose an option" 20 78 10 \
        1 "Backup to SQL" \
        2 "Backup to SQL.gz" \
        3 "Restore from SQL" \
        4 "Restore from SQL.gz" \
        5 "Change DB settings" \
        6 "Show config" \
        7 "Test connection" \
        0 "Exit" 2>"$tmp_out" || { rm -f "$tmp_out"; exit 0; }
      choice=$(cat "$tmp_out"); rm -f "$tmp_out"
      case "$choice" in
        1) tmp=$(mktemp); dialog --title "Output file" --inputbox "Optional output path (.sql)" 10 60 2>"$tmp" || true; out=$(cat "$tmp"); rm -f "$tmp"; backup_sql "${out:-}"; dialog --msgbox "Backup completed" 8 40;;
        2) tmp=$(mktemp); dialog --title "Output file" --inputbox "Optional output path (.sql.gz)" 10 60 2>"$tmp" || true; out=$(cat "$tmp"); rm -f "$tmp"; backup_sql "${out:-}" "1"; dialog --msgbox "Backup completed" 8 40;;
        3) f=$(select_backup_file_tui) || continue; dialog --yesno "Drop & recreate database before restore?" 8 60 && drop=1 || drop=0; restore_sql "$f" "$drop" "1"; dialog --msgbox "Restore completed" 8 40;;
        4) f=$(select_backup_file_tui) || continue; dialog --yesno "Drop & recreate database before restore?" 8 60 && drop=1 || drop=0; restore_sql "$f" "$drop" "1"; dialog --msgbox "Restore completed" 8 40;;
        5) prompt_overrides;;
        6) dialog --msgbox "Host: $db_host\nPort: $db_port\nDB: $db_name\nUser: $db_user" 12 60;;
        7) test_connection; sleep 1;;
        0) exit 0;;
      esac
    done
  else
    while true; do
      clear; print_title "Database Manager"; show_config
      echo "1) Backup to SQL"
      echo "2) Backup to SQL.gz"
      echo "3) Restore from SQL"
      echo "4) Restore from SQL.gz"
      echo "5) Change DB settings"
      echo "6) Show config"
      echo "7) Test connection"
      echo "0) Exit"
      read -rp "Choose option: " choice
      case "$choice" in
        1) read -rp "Output file (optional): " out; backup_sql "${out:-}";;
        2) read -rp "Output file (optional): " out; backup_sql "${out:-}" "1";;
        3) read -rp "SQL file path: " f; [[ -z "$f" ]] && continue; read -rp "Drop and recreate database first? [y/N]: " yn; [[ "$yn" =~ ^[Yy]$ ]] && drop=1 || drop=0; restore_sql "$f" "$drop" "1";;
        4) read -rp "SQL.gz file path: " f; [[ -z "$f" ]] && continue; read -rp "Drop and recreate database first? [y/N]: " yn; [[ "$yn" =~ ^[Yy]$ ]] && drop=1 || drop=0; restore_sql "$f" "$drop" "1";;
        5) prompt_overrides;;
        6) show_config;;
        7) test_connection;;
        0) exit 0;;
        *) print_warn "Invalid option";;
      esac
    done
  fi
}

main() {
  if [[ $# -eq 0 ]]; then
    interactive
    exit 0
  fi

  case "${1:-}" in
    --backup)
      shift
      out=""
      gz="0"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --output) out="$2"; shift 2;;
          --gz) gz="1"; shift;;
          *) usage; exit 1;;
        esac
      done
      backup_sql "$out" "$gz"
      ;;
    --restore)
      shift
      [[ $# -lt 1 ]] && usage && exit 1
      file="$1"; shift
      drop="0"; fast="1"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --drop-first) drop="1"; shift;;
          --no-fast) fast="0"; shift;;
          *) usage; exit 1;;
        esac
      done
      restore_sql "$file" "$drop" "$fast"
      ;;
    --show-config)
      parse_conf
      show_config
      ;;
    --interactive)
      interactive
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage; exit 1;;
  esac
}

main "$@"
