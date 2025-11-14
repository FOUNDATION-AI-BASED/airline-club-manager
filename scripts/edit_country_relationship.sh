#!/usr/bin/env bash

set -euo pipefail

# Edit country-airline relationship via MySQL directly.
# Usage:
#   edit_country_relationship.sh --country US --airline-id 123 --value 25 \
#     [--host 127.0.0.1:3306] [--schema airline_v2_1] [--user sa] [--password testmysql]
#   edit_country_relationship.sh --country US --airline-id 123 --preset approved
# Presets: approved=5, established=20, privileged=40. A value <=0 deletes the entry.

COUNTRY=""
AIRLINE_ID=""
VALUE=""
PRESET=""

# Defaults read from airline-web/conf/application.conf; fall back to typical values
HOST_DEFAULT="127.0.0.1:3306"
SCHEMA_DEFAULT="airline_v2_1"
USER_DEFAULT="sa"
PASSWORD_DEFAULT="testmysql"

DB_HOST="${HOST_DEFAULT}"
DB_SCHEMA="${SCHEMA_DEFAULT}"
DB_USER="${USER_DEFAULT}"
DB_PASSWORD="${PASSWORD_DEFAULT}"

TABLE_NAME="country_airline_relationship"

die() { echo "Error: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Edit country-airline relationship

Required:
  --country <CC>         Country code (2 letters)
  --airline-id <ID>     Airline ID (integer)

One of:
  --value <N>           Relationship value (<=0 will delete row)
  --preset <name>       One of: approved, established, privileged

Optional overrides:
  --host <host:port>    MySQL host:port (default ${HOST_DEFAULT})
  --schema <name>       Database schema (default ${SCHEMA_DEFAULT})
  --user <name>         MySQL user (default ${USER_DEFAULT})
  --password <pass>     MySQL password (default ${PASSWORD_DEFAULT})

Examples:
  $0 --country US --airline-id 3 --preset established
  $0 --country JP --airline-id 42 --value 0   # delete
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --country) COUNTRY="$2"; shift 2;;
    --airline-id) AIRLINE_ID="$2"; shift 2;;
    --value) VALUE="$2"; shift 2;;
    --preset) PRESET="$2"; shift 2;;
    --host) DB_HOST="$2"; shift 2;;
    --schema) DB_SCHEMA="$2"; shift 2;;
    --user) DB_USER="$2"; shift 2;;
    --password) DB_PASSWORD="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

[[ -z "$COUNTRY" ]] && die "--country is required"
[[ -z "$AIRLINE_ID" ]] && die "--airline-id is required"

# Validate country code
if ! [[ "$COUNTRY" =~ ^[A-Za-z]{2}$ ]]; then
  die "Invalid country code: $COUNTRY"
fi

# Validate airline id
if ! [[ "$AIRLINE_ID" =~ ^[0-9]+$ ]]; then
  die "Invalid airline id: $AIRLINE_ID"
fi

# Determine value from preset if provided
if [[ -n "$PRESET" && -n "$VALUE" ]]; then
  die "Specify either --value or --preset, not both"
fi

if [[ -n "$PRESET" ]]; then
  case "$PRESET" in
    approved) VALUE=5;;
    established) VALUE=20;;
    privileged) VALUE=40;;
    *) die "Invalid preset: $PRESET (allowed: approved, established, privileged)";;
  esac
fi

if [[ -z "$VALUE" ]]; then
  die "Must specify --value or --preset"
fi

if ! [[ "$VALUE" =~ ^-?[0-9]+$ ]]; then
  die "Invalid value: $VALUE"
fi

# Build MySQL command
MYSQL_CLI=(mysql -h "${DB_HOST%%:*}" -P "${DB_HOST##*:}" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_SCHEMA" --protocol=tcp --default-character-set=utf8)

# Check connection
"${MYSQL_CLI[@]}" -e "SELECT 1" >/dev/null || die "Cannot connect to MySQL at $DB_HOST using schema $DB_SCHEMA"

echo "Editing relationship: country=$COUNTRY airline_id=$AIRLINE_ID value=$VALUE"

if (( VALUE <= 0 )); then
  SQL="DELETE FROM ${TABLE_NAME} WHERE country = '$COUNTRY' AND airline = $AIRLINE_ID;"
else
  SQL="REPLACE INTO ${TABLE_NAME} (country, airline, relationship) VALUES ('$COUNTRY', $AIRLINE_ID, $VALUE);"
fi

"${MYSQL_CLI[@]}" -e "$SQL"

echo "Done."

