#!/usr/bin/env bash

set -euo pipefail

# Interactive Admin Tool for Airline Game DB
# Features:
# - Search/select users (with pagination) and view their airline, money, and delegate details
# - Edit airline money (set/add/subtract)
# - Edit delegate boosts (add presets/custom, list, remove expired/by id)
# - Edit country relationships (presets or custom), with country search
#
# Defaults are aligned with previous scripts; override via flags.

DB_HOST="127.0.0.1"
DB_PORT="3306"
DB_SCHEMA="airline_v2_1"
DB_USER="sa"
DB_PASS="testmysql"

PAGE_SIZE=20

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --host <host>           Database host (default: ${DB_HOST})
  --port <port>           Database port (default: ${DB_PORT})
  --schema <schema>       Database schema (default: ${DB_SCHEMA})
  --user <user>           Database user (default: ${DB_USER})
  --password <password>   Database password (default: ${DB_PASS})
  --page-size <n>         Page size for list views (default: ${PAGE_SIZE})
  -h, --help              Show this help

Interactive flow:
  1) Search or list users. Pick a user to view their airline, money, and delegates.
  2) Choose actions: edit money, edit delegates, edit country relationships, or go back.

Delegate boosts:
  - Presets: +3 for 4 weeks, +5 for 8 weeks, +10 for 12 weeks
  - Custom: enter "<amount> <duration_weeks>" (e.g., "3 4"). Duration is in cycles/weeks.

Country relationships:
  - Presets: approved=5, established=20, privileged=40
  - Custom: enter an integer (e.g., 13). Enter 0 or negative to delete.

EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) DB_HOST="$2"; shift 2 ;;
    --port) DB_PORT="$2"; shift 2 ;;
    --schema) DB_SCHEMA="$2"; shift 2 ;;
    --user) DB_USER="$2"; shift 2 ;;
    --password) DB_PASS="$2"; shift 2 ;;
    --page-size) PAGE_SIZE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_mysql() {
  if ! command -v mysql >/dev/null 2>&1; then
    echo "Error: 'mysql' CLI not found. Please install MySQL client." >&2
    exit 1
  fi
}

# Execute SQL and print rows as tab-separated values
mysql_query() {
  local sql="$1"
  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_SCHEMA" -N -e "$sql"
}

# Execute multiple SQL statements in one connection (semicolon-separated)
mysql_multi() {
  local sql="$1"
  mysql --protocol=TCP -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" -D "$DB_SCHEMA" --skip-column-names --raw <<SQL
$sql
SQL
}

get_current_cycle() {
  mysql_query "SELECT cycle FROM cycle LIMIT 1" | head -n1
}

prompt() {
  local msg="$1"
  local var
  read -r -p "$msg" var || true
  echo "$var"
}

confirm() {
  local msg="$1"
  local ans
  read -r -p "$msg [y/N]: " ans || true
  case "${ans,,}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

hr() { printf '%*s\n' "$(tput cols 2>/dev/null || echo 80)" '' | tr ' ' -; }

calc_grade_value() {
  # Input: reputation (float). Output: grade value (int 1..19)
  local rep="$1"
  # Thresholds per AirlineGrade.reputationCeiling
  local thresholds=(20 40 60 80 100 120 140 160 180 200 225 250 300 350 400 500 600 700 800)
  local i=1
  for t in "${thresholds[@]}"; do
    awk -v rep="$rep" -v t="$t" -v i="$i" 'BEGIN{ if (rep < t) { print i; } else { exit 1 } }' 2>/dev/null && return 0 || true
    i=$((i+1))
  done
  echo 19
}

fetch_user_page() {
  local search="$1"; local offset="$2"; local limit="$3"
  local where=""
  if [[ -n "$search" ]]; then
    local s="$(printf %s "$search" | sed "s/'/''/g")"
    where="WHERE LOWER(u.user_name) LIKE LOWER('%$s%') OR LOWER(u.email) LIKE LOWER('%$s%') OR LOWER(a.name) LIKE LOWER('%$s%')"
  fi
  mysql_query "SELECT u.user_name, u.email, a.id, a.name FROM user u LEFT JOIN user_airline ua ON ua.user_name = u.user_name LEFT JOIN airline a ON a.id = ua.airline $where ORDER BY u.user_name LIMIT $limit OFFSET $offset" || true
}

fetch_airline_info() {
  local airline_id="$1"
  mysql_query "SELECT a.id, a.name, ai.balance, ai.reputation FROM airline a LEFT JOIN airline_info ai ON ai.airline = a.id WHERE a.id = $airline_id"
}

count_delegate_recruiter_bases() {
  local airline_id="$1"
  # Each base with scale >= 12 yields +3 delegates (free DelegateSpecialization)
  mysql_query "SELECT COUNT(*) FROM airline_base WHERE airline = $airline_id AND scale >= 12" | head -n1
}

sum_active_delegate_boosts() {
  local airline_id="$1"
  local cycle="$(get_current_cycle)"
  mysql_query "SELECT COALESCE(SUM(p.value),0) FROM airline_modifier am JOIN airline_modifier_property p ON p.id = am.id AND p.name = 'STRENGTH' WHERE am.airline = $airline_id AND am.modifier_name = 'DELEGATE_BOOST' AND (am.expiry IS NULL OR am.expiry > $cycle)" | head -n1
}

count_busy_delegates() {
  local airline_id="$1"
  mysql_query "SELECT COUNT(*) FROM busy_delegate WHERE airline = $airline_id" | head -n1
}

count_cooldown_delegates() {
  local airline_id="$1"
  mysql_query "SELECT COUNT(*) FROM busy_delegate WHERE airline = $airline_id AND available_cycle IS NOT NULL" | head -n1
}

print_user_page() {
  local search="$1"; local page="$2"
  local offset=$(((page-1) * PAGE_SIZE))
  local rows
  rows="$(fetch_user_page "$search" "$offset" "$PAGE_SIZE")"
  local idx=1
  if [[ -z "$rows" ]]; then
    echo "No users found."
    return
  fi
  printf "#  %-20s | %-25s | %-6s | %s\n" "User" "Email" "A.ID" "Airline"
  hr
  while IFS=$'\t' read -r user email airline_id airline_name; do
    printf "%2d  %-20s | %-25s | %-6s | %s\n" "$idx" "$user" "$email" "${airline_id:-}" "${airline_name:-}"
    idx=$((idx+1))
  done <<< "$rows"
}

select_user_flow() {
  local search=""
  local page=1
  while true; do
    clear || true
    echo "User Search/Selection"
    hr
    echo "Search: '${search:-<none>}'  Page: $page (size $PAGE_SIZE)"
    print_user_page "$search" "$page"
    echo
    echo "Commands: [s]earch  [n]ext  [p]rev  number to select  [x] exit"
    local cmd
    read -r -p "> " cmd || cmd="x"
    case "${cmd,,}" in
      s) search="$(prompt "Enter search text: ")" ; page=1 ;;
      n) page=$((page+1)) ;;
      p) if [[ $page -gt 1 ]]; then page=$((page-1)); fi ;;
      x) return 1 ;;
      ''|*[!0-9]*) ;; # ignore invalid
      *)
        local sel_idx="$cmd"
        local offset=$(((page-1) * PAGE_SIZE))
        local rows
        rows="$(fetch_user_page "$search" "$offset" "$PAGE_SIZE")"
        local i=1
        while IFS=$'\t' read -r user email airline_id airline_name; do
          if [[ "$i" == "$sel_idx" ]]; then
            view_user_actions "$user" "$airline_id" "$airline_name"
            break
          fi
          i=$((i+1))
        done <<< "$rows"
        ;;
    esac
  done
}

view_user_actions() {
  local user_name="$1"; local airline_id="$2"; local airline_name="$3"
  clear || true
  echo "User: $user_name"
  echo "Airline: ${airline_name:-<none>} (ID: ${airline_id:-N/A})"

  if [[ -z "${airline_id:-}" ]]; then
    echo "This user does not have a primary airline assigned."
    echo "Press Enter to return."
    read -r || true
    return
  fi

  local info
  info="$(fetch_airline_info "$airline_id")"
  local id name balance reputation
  IFS=$'\t' read -r id name balance reputation <<< "$info"
  local grade_value; grade_value="$(calc_grade_value "$reputation")"
  local base_delegate_bases; base_delegate_bases="$(count_delegate_recruiter_bases "$airline_id")"
  local base_delegate_boost=$(( base_delegate_bases * 3 ))
  local boosts_sum; boosts_sum="$(sum_active_delegate_boosts "$airline_id")"
  local busy_count; busy_count="$(count_busy_delegates "$airline_id")"
  local cooldown_count; cooldown_count="$(count_cooldown_delegates "$airline_id")"

  local BASE=5
  local PER_LEVEL=3
  local delegate_total=$(( BASE + grade_value * PER_LEVEL + base_delegate_boost + boosts_sum ))
  local available_count=$(( delegate_total - busy_count ))
  local unoccupied_bonus=$(( boosts_sum - cooldown_count ))
  if [[ $unoccupied_bonus -gt 0 ]]; then
    permanent_available=$(( available_count - unoccupied_bonus ))
  else
    permanent_available=$available_count
  fi

  echo
  echo "Money (balance): $balance"
  echo "Reputation: $reputation  Grade value: $grade_value"
  echo "Delegates: total=$delegate_total, available=$available_count, permanent-available=$permanent_available"
  echo "  - Base: $BASE"
  echo "  - Grade: $((grade_value * PER_LEVEL)) (=$PER_LEVEL per grade level)"
  echo "  - Base specializations (Delegate Recruiter): +$base_delegate_boost (bases >=12 scale: $base_delegate_bases)"
  echo "  - Active boosts: +$boosts_sum"
  echo "  - Busy delegates: $busy_count (cooldown: $cooldown_count)"
  echo
  echo "Actions: [1] Edit money  [2] Edit delegates  [3] Edit country relationships  [b] Back  [x] Exit"
  local cmd
  read -r -p "> " cmd || cmd="b"
  case "${cmd,,}" in
    1) edit_money "$airline_id" ; view_user_actions "$user_name" "$airline_id" "$airline_name" ;;
    2) edit_delegates "$airline_id" "$name" ; view_user_actions "$user_name" "$airline_id" "$airline_name" ;;
    3) edit_country_relationships "$airline_id" "$name" ; view_user_actions "$user_name" "$airline_id" "$airline_name" ;;
    x) exit 0 ;;
    *) ;;
  esac
}

edit_money() {
  local airline_id="$1"
  clear || true
  echo "Edit Money for airline ID: $airline_id"
  echo "Options: [1] Set absolute  [2] Add amount  [3] Subtract amount  [b] Back"
  local cmd; read -r -p "> " cmd || cmd="b"
  case "${cmd,,}" in
    1)
      local amt; amt="$(prompt "Enter new absolute balance (integer): ")"
      [[ -z "$amt" ]] && return
      if confirm "Set balance to $amt?"; then
        mysql_query "UPDATE airline_info SET balance = $amt WHERE airline = $airline_id"
        echo "Balance set to $amt."
      fi
      ;;
    2)
      local delta; delta="$(prompt "Enter amount to add (integer): ")"
      [[ -z "$delta" ]] && return
      if confirm "Add $delta to balance?"; then
        mysql_query "UPDATE airline_info SET balance = balance + $delta WHERE airline = $airline_id"
        echo "Added $delta."
      fi
      ;;
    3)
      local delta; delta="$(prompt "Enter amount to subtract (integer): ")"
      [[ -z "$delta" ]] && return
      if confirm "Subtract $delta from balance?"; then
        mysql_query "UPDATE airline_info SET balance = balance - $delta WHERE airline = $airline_id"
        echo "Subtracted $delta."
      fi
      ;;
    *) ;;
  esac
  echo "Press Enter to continue."; read -r || true
}

list_delegate_boosts() {
  local airline_id="$1"
  mysql_query "SELECT am.id, COALESCE(s.value,0) AS strength, COALESCE(d.value,0) AS duration, am.creation, am.expiry FROM airline_modifier am LEFT JOIN airline_modifier_property s ON s.id = am.id AND s.name='STRENGTH' LEFT JOIN airline_modifier_property d ON d.id = am.id AND d.name='DURATION' WHERE am.airline=$airline_id AND am.modifier_name='DELEGATE_BOOST' ORDER BY am.id"
}

edit_delegates() {
  local airline_id="$1"; local airline_name="$2"
  while true; do
    clear || true
    echo "Edit Delegates for $airline_name (ID: $airline_id)"
    echo "Current active boosts:"
    local rows
    rows="$(list_delegate_boosts "$airline_id")"
    if [[ -z "$rows" ]]; then
      echo "  <none>"
    else
      printf "%-6s | %-8s | %-8s | %-8s | %-8s\n" "ID" "Strength" "Duration" "Creation" "Expiry"
      hr
      while IFS=$'\t' read -r id strength duration creation expiry; do
        printf "%-6s | %-8s | %-8s | %-8s | %-8s\n" "$id" "$strength" "$duration" "$creation" "${expiry:-}" 
      done <<< "$rows"
    fi
    echo
    echo "Options: [1] Add boost  [2] Remove expired  [3] Remove by ID  [b] Back"
    local cmd; read -r -p "> " cmd || cmd="b"
    case "${cmd,,}" in
      1)
        echo "Presets: [a] +3 for 4 weeks  [b] +5 for 8 weeks  [c] +10 for 12 weeks  [cst] custom"
        local p; read -r -p "Pick preset (a/b/c) or type 'cst' for custom: " p || p=""
        local amount duration
        case "${p,,}" in
          a) amount=3; duration=4 ;;
          b) amount=5; duration=8 ;;
          c) amount=10; duration=12 ;;
          cst)
            echo "Enter custom amount and duration (weeks) in format: '<amount> <duration>' e.g., '3 4'"
            local line; read -r -p "Input: " line || line=""
            amount="${line%% *}"; duration="${line##* }"
            ;;
          *) echo "Invalid preset."; sleep 1; continue ;;
        esac
        [[ -z "${amount:-}" || -z "${duration:-}" ]] && { echo "Missing amount/duration"; sleep 1; continue; }
        if ! [[ "$amount" =~ ^[0-9]+$ && "$duration" =~ ^[0-9]+$ ]]; then
          echo "Amount and duration must be positive integers."; sleep 1; continue
        fi
        local cycle; cycle="$(get_current_cycle)"
        if confirm "Add +$amount delegates for $duration weeks (creation=$cycle, expiry=$((cycle+duration)))?"; then
          # Insert modifier and properties atomically in one connection
          mysql_multi "INSERT INTO airline_modifier (airline, modifier_name, creation, expiry) VALUES ($airline_id, 'DELEGATE_BOOST', $cycle, $((cycle+duration)));\nSELECT MAX(id) FROM airline_modifier WHERE airline=$airline_id AND modifier_name='DELEGATE_BOOST';" | {
            read -r new_id
            if [[ -z "$new_id" ]]; then
              # Fallback: fetch max id
              new_id="$(mysql_query "SELECT MAX(id) FROM airline_modifier WHERE airline=$airline_id AND modifier_name='DELEGATE_BOOST'" | head -n1)"
            fi
            mysql_multi "REPLACE INTO airline_modifier_property (id, name, value) VALUES ($new_id, 'STRENGTH', $amount);\nREPLACE INTO airline_modifier_property (id, name, value) VALUES ($new_id, 'DURATION', $duration);"
            echo "Added delegate boost id=$new_id (+$amount for $duration weeks)."
          }
        fi
        ;;
      2)
        local cycle; cycle="$(get_current_cycle)"
        if confirm "Remove expired delegate boosts (expiry <= $cycle)?"; then
          mysql_query "DELETE FROM airline_modifier WHERE airline=$airline_id AND modifier_name='DELEGATE_BOOST' AND expiry IS NOT NULL AND expiry <= $cycle"
          echo "Removed expired boosts."
        fi
        ;;
      3)
        local bid; bid="$(prompt "Enter boost ID to remove: ")"; [[ -z "$bid" ]] && continue
        if confirm "Delete boost ID $bid?"; then
          mysql_query "DELETE FROM airline_modifier WHERE id=$bid AND airline=$airline_id AND modifier_name='DELEGATE_BOOST'"
          echo "Deleted boost $bid."
        fi
        ;;
      *) break ;;
    esac
    echo "Press Enter to continue."; read -r || true
  done
}

search_country_menu() {
  local term="$1"
  mysql_query "SELECT code, name FROM country WHERE LOWER(name) LIKE LOWER('%$term%') OR LOWER(code) LIKE LOWER('%$term%') ORDER BY name LIMIT 50"
}

get_relationship() {
  local airline_id="$1"; local country_code="$2"
  mysql_query "SELECT relationship FROM country_airline_relationship WHERE airline=$airline_id AND country='$country_code'" | head -n1
}

set_relationship() {
  local airline_id="$1"; local country_code="$2"; local value="$3"
  if [[ "$value" -le 0 ]]; then
    mysql_query "DELETE FROM country_airline_relationship WHERE airline=$airline_id AND country='$country_code'"
  else
    mysql_query "REPLACE INTO country_airline_relationship (country, airline, relationship) VALUES ('$country_code', $airline_id, $value)"
  fi
}

edit_country_relationships() {
  local airline_id="$1"; local airline_name="$2"
  while true; do
    clear || true
    echo "Edit Country Relationships for $airline_name (ID: $airline_id)"
    local term; term="$(prompt "Search country by code or name (or 'b' to back): ")"
    [[ "${term,,}" == "b" ]] && break
    local rows; rows="$(search_country_menu "$term")"
    if [[ -z "$rows" ]]; then
      echo "No countries matched."; sleep 1; continue
    fi
    local idx=1
    printf "#  %-6s | %s\n" "Code" "Name"
    hr
    while IFS=$'\t' read -r code name; do
      printf "%2d  %-6s | %s\n" "$idx" "$code" "$name"
      idx=$((idx+1))
    done <<< "$rows"
    local sel; read -r -p "Select number (or 'b' to back): " sel || sel="b"
    [[ "${sel,,}" == "b" ]] && continue
    if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
      continue
    fi
    local i=1 country_code country_name
    while IFS=$'\t' read -r code name; do
      if [[ "$i" == "$sel" ]]; then country_code="$code"; country_name="$name"; break; fi
      i=$((i+1))
    done <<< "$rows"
    if [[ -z "${country_code:-}" ]]; then continue; fi
    local current_rel; current_rel="$(get_relationship "$airline_id" "$country_code")"
    echo "\nSelected: $country_name ($country_code). Current relationship: ${current_rel:-<none>}"
    echo "Options: [1] approved(5)  [2] established(20)  [3] privileged(40)  [4] custom  [5] delete  [b] back"
    local cmd; read -r -p "> " cmd || cmd="b"
    local value
    case "${cmd,,}" in
      1) value=5 ;;
      2) value=20 ;;
      3) value=40 ;;
      4)
        echo "Enter custom integer value (e.g., 13). Enter 0 or negative to delete."
        read -r -p "Value: " value || value=0
        if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then echo "Invalid integer."; sleep 1; continue; fi
        ;;
      5) value=0 ;;
      *) continue ;;
    esac
    if confirm "Apply relationship value '$value' for $country_name ($country_code)?"; then
      set_relationship "$airline_id" "$country_code" "$value"
      echo "Updated."
    fi
    echo "Press Enter to continue."; read -r || true
  done
}

main_menu() {
  require_mysql
  while true; do
    clear || true
    echo "Interactive Admin Tool"
    hr
    echo "DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_SCHEMA  Page size: $PAGE_SIZE"
    echo "Options: [1] Search/list users  [x] Exit"
    local cmd; read -r -p "> " cmd || cmd="x"
    case "${cmd,,}" in
      1) select_user_flow || true ;;
      x) exit 0 ;;
      *) ;;
    esac
  done
}

main_menu
