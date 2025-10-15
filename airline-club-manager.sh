#!/bin/bash

# Airline Club Auto Installer
# Supports Ubuntu Server (more distributions coming soon)
# Author: Auto-generated installer script
# Version: 1.0

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://github.com/patsonluk/airline.git"
INSTALL_DIR="$HOME/airline-club"
DB_NAME="airline_v2"
DB_USER="sa"
DB_PASS="admin"
DEFAULT_PORT="9000"
BIND_ADDRESS="0.0.0.0"
PROGRESS_FILE="$HOME/.airline-club-progress"

# Global variables
GOOGLE_API_KEY=""
SERVER_PORT="$DEFAULT_PORT"
ELASTICSEARCH_ENABLED=false
BANNER_ENABLED=false
TRUSTED_HOSTS="${TRUSTED_HOSTS:-localhost,127.0.0.1}"

# Installation steps
INSTALL_STEPS=(
    "dependencies"
    "mysql"
    "elasticsearch"
    "repository"
    "configure"
    "build"
    "database"
)

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Trusted hosts helpers
create_hosts_line() {
    ensure_server_ips_in_trusted
    # Safely split by commas and avoid pathname expansion
    local IFS=','
    local -a arr
    read -r -a arr <<< "$TRUSTED_HOSTS"
    set -f  # disable globbing
    local items=()
    for h in "${arr[@]}"; do
        h=$(echo "$h" | xargs)
        if [[ -n "$h" ]]; then
            items+=("\"$h\"")
        fi
    done
    set +f
    local joined
    if [[ ${#items[@]} -gt 0 ]]; then
        joined=$(IFS=, ; echo "${items[*]}")
    else
        joined="\"localhost\",\"127.0.0.1\""
    fi
    echo "play.filters.hosts.allowed=[${joined}]"
}

ensure_server_ips_in_trusted() {
    local current="$TRUSTED_HOSTS"
    [[ -z "$current" ]] && current="localhost,127.0.0.1"
    local ips=$(hostname -I 2>/dev/null || true)
    if [[ -z "$ips" ]]; then
        ips=$(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | xargs || true)
    fi
    local list=","$current"," # sentinel commas
    for base in localhost 127.0.0.1; do
        if [[ "$list" != *",$base,"* ]]; then list="$list$base,"; fi
    done
    for ip in $ips; do
        if [[ -n "$ip" && "$list" != *",$ip,"* ]]; then list="$list$ip,"; fi
    done
    if [[ "$BIND_ADDRESS" == "0.0.0.0" ]]; then
        if [[ "$list" != *",.*,"* ]]; then list="$list.*,"; fi
    fi
    # Normalize, trim spaces, and dedupe safely
    list=$(echo "$list" | sed 's/^,//; s/,$//' | awk -F',' '
        {
          for (i=1; i<=NF; i++) {
            gsub(/^ +| +$/, "", $i)
            if (length($i) > 0 && !seen[$i]++) {
              out = out (out ? "," : "") $i
            }
          }
        }
        END { print out }
    ')
    TRUSTED_HOSTS="$list"
}

apply_hosts_to_conf() {
    local conf_path="$1"
    if [[ -f "$conf_path" ]]; then
        sed -i -e '$a\' "$conf_path"
        sed -i '/^play\.filters\.hosts\.allowed/d' "$conf_path"
        local line=$(create_hosts_line)
        printf '%s\n' "$line" >> "$conf_path"
        log "Applied trusted hosts to $(basename "$conf_path"): $line"
    else
        warn "Config file not found for trusted hosts: $conf_path"
    fi
}

# Progress tracking functions
save_progress() {
    local step=$1
    echo "$step" > "$PROGRESS_FILE"
    log "Progress saved: $step"
}

load_progress() {
    if [[ -f "$PROGRESS_FILE" ]]; then
        cat "$PROGRESS_FILE"
    else
        echo ""
    fi
}

# Trusted Hosts menu
trusted_hosts_menu() {
    echo -e "${BLUE}Trusted Hosts Configuration${NC}"
    echo "Current allowed hosts: ${TRUSTED_HOSTS}"
    echo "Enter a comma-separated list of IPs/domains (examples: localhost,127.0.0.1,example.com,10.0.0.5)."
    echo "Special: Use .* to allow any host (not recommended)."
    if [[ -t 0 ]]; then
        read -p "New trusted hosts (leave blank to keep current): " new_hosts
    else
        read new_hosts || true
    fi
    if [[ -n "$new_hosts" ]]; then
        TRUSTED_HOSTS="$new_hosts"
        ensure_server_ips_in_trusted
        save_configuration
        log "Trusted hosts updated to: $TRUSTED_HOSTS"
        # Optionally apply immediately if configs exist
        if [[ -f "conf/application.conf" ]]; then apply_hosts_to_conf "conf/application.conf"; fi
        if [[ -f "target/universal/stage/conf/application.conf" ]]; then apply_hosts_to_conf "target/universal/stage/conf/application.conf"; fi
    else
        log "Trusted hosts unchanged."
    fi
}

clear_progress() {
    rm -f "$PROGRESS_FILE"
    log "Installation progress cleared"
}

get_step_index() {
    local step=$1
    for i in "${!INSTALL_STEPS[@]}"; do
        if [[ "${INSTALL_STEPS[$i]}" == "$step" ]]; then
            echo $i
            return
        fi
    done
    echo -1
}

check_resume_installation() {
    local last_step=$(load_progress)
    if [[ -n "$last_step" ]]; then
        echo -e "${YELLOW}Previous installation detected!${NC}"
        echo "Last completed step: $last_step"
        echo
        echo "1) Resume installation from next step"
        echo "2) Restart installation completely"
        echo "3) Cancel"
        echo
        read -p "Please select an option (1-3): " resume_choice
        
        case $resume_choice in
            1)
                return $(get_step_index "$last_step")
                ;;
            2)
                clear_progress
                return -1
                ;;
            3)
                log "Installation cancelled"
                exit 0
                ;;
            *)
                error "Invalid option. Installation cancelled."
                ;;
        esac
    fi
    return -1
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as a regular user."
    fi
}

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        error "Cannot detect OS. This script currently supports Ubuntu Server only."
    fi
    
    case $OS in
        "Ubuntu"*)
            log "Detected Ubuntu $VER"
            PACKAGE_MANAGER="apt"
            ;;
        *)
            error "Unsupported OS: $OS. Currently only Ubuntu Server is supported."
            ;;
    esac
}

# Check if service is running
is_service_running() {
    local service_name=$1
    if pgrep -f "$service_name" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Detect system resources and configure low-resource mode
detect_system_resources() {
    MEM_TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    CPU_CORES=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    CPU_MODEL=$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo | xargs)

    LOW_MEMORY=false
    LOW_CPU=false
    LOW_RESOURCE_MODE=false
    TIGHT_MODE=${TIGHT_MODE:-false}
    NICE_CMD=""
    IONICE_CMD=""
    SBT_JAVA_OPTS_LOW="-Xms256m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC -XX:CICompilerCount=2"
SBT_JAVA_OPTS_TIGHT="-Xms256m -Xmx768m -XX:MaxMetaspaceSize=192m -XX:+UseSerialGC -XX:CICompilerCount=2"

    if [[ $MEM_TOTAL_MB -le 4096 ]]; then LOW_MEMORY=true; fi
    if [[ $CPU_CORES -le 2 ]]; then LOW_CPU=true; fi

    if [[ "$LOW_MEMORY" == "true" || "$LOW_CPU" == "true" ]]; then
        LOW_RESOURCE_MODE=true
    fi

    set_resource_profile
}

# Apply resource profile to environment based on LOW_RESOURCE_MODE and TIGHT_MODE
set_resource_profile() {
    if [[ "$TIGHT_MODE" == "true" ]]; then
        export SBT_OPTS="$SBT_JAVA_OPTS_TIGHT"
        export JAVA_OPTS="$SBT_JAVA_OPTS_TIGHT"
        NICE_CMD="nice -n 15"
        IONICE_CMD="ionice -c2 -n 7"
        log "Tight mode enabled. Applied JVM limits: $SBT_JAVA_OPTS_TIGHT; using $NICE_CMD and $IONICE_CMD"
    elif [[ "$LOW_RESOURCE_MODE" == "true" ]]; then
        export SBT_OPTS="$SBT_JAVA_OPTS_LOW"
        export JAVA_OPTS="$SBT_JAVA_OPTS_LOW"
        NICE_CMD="nice -n 10"
        IONICE_CMD="ionice -c2 -n 7"
        log "Low resource mode enabled (RAM: ${MEM_TOTAL_MB}MB, CPU cores: ${CPU_CORES}, CPU: ${CPU_MODEL})"
        log "Applied JVM limits: $SBT_JAVA_OPTS_LOW; using $NICE_CMD and $IONICE_CMD for heavy processes"
    else
        NICE_CMD=""
        IONICE_CMD=""
        export SBT_OPTS=""
        export JAVA_OPTS=""
        log "Resource profile: normal (RAM: ${MEM_TOTAL_MB}MB, CPU cores: ${CPU_CORES}, CPU: ${CPU_MODEL})"
    fi
}

# Install dependencies
install_dependencies() {
    log "Installing system dependencies..."
    
    # Update package list
    sudo apt update
    
    # Install basic dependencies
    sudo apt install -y git curl wget unzip software-properties-common
    
    # Install Java 8+
    log "Installing OpenJDK 11..."
    sudo apt install -y openjdk-11-jdk
    
    # Install SBT (Scala Build Tool)
    log "Installing SBT..."
    echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" | sudo tee /etc/apt/sources.list.d/sbt.list
    echo "deb https://repo.scala-sbt.org/scalasbt/debian /" | sudo tee /etc/apt/sources.list.d/sbt_old.list
    curl -sL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x2EE0EA64E40A89B84B2DF73499E82A75642AC823" | sudo apt-key add
    sudo apt update
    sudo apt install -y sbt
    # Install Node.js and npm to speed up Play asset pipeline (avoids slow Rhino/Trireme fallback)
    sudo apt install -y nodejs npm
    
    # Install MySQL 5.7
    log "Installing MySQL 5.7..."
    sudo apt install -y mysql-server-5.7 mysql-client-5.7 || {
        warn "MySQL 5.7 not available, installing MySQL 8.0 (may cause compatibility issues)"
        sudo apt install -y mysql-server mysql-client
    }
    
    log "Dependencies installed successfully!"
    save_progress "dependencies"
}

# Configure MySQL
configure_mysql() {
    log "Configuring MySQL..."
    
    # Start MySQL service
    sudo systemctl start mysql
    sudo systemctl enable mysql
    
    # Configure UTF-8 support and legacy auth for MySQL 8
    log "Configuring MySQL for UTF-8 support..."
    sudo tee -a /etc/mysql/mysql.conf.d/mysqld.cnf > /dev/null <<'EOF'

# Airline Club UTF-8 Configuration
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
init_connect='SET NAMES utf8mb4'
# Force MySQL 8 to use legacy auth for older JDBC
default_authentication_plugin=mysql_native_password
EOF
    
    # Restart MySQL to apply changes
    sudo systemctl restart mysql
    
    # Create database and user
    log "Creating database and user..."
    sudo mysql -e "CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    sudo mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    sudo mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
    
    # If MySQL 8.x, switch user auth plugin to mysql_native_password
    MYSQL_VERSION=$(mysql --version 2>/dev/null || true)
    if [[ "$MYSQL_VERSION" == *"Ver 8."* || "$MYSQL_VERSION" == *"Distrib 8."* ]]; then
        log "Detected MySQL 8.x - switching '$DB_USER' to mysql_native_password..."
        sudo mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS';"
    fi
    
    sudo mysql -e "FLUSH PRIVILEGES;"
    
    log "MySQL configured successfully!"
    save_progress "mysql"
}

# Install Elasticsearch (optional)
install_elasticsearch() {
    if [[ "$ELASTICSEARCH_ENABLED" == "true" ]]; then
        log "Installing Elasticsearch 7.x..."
        
        # Add Elasticsearch repository
        wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
        echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list
        
        sudo apt update
        sudo apt install -y elasticsearch
        
        # Configure Elasticsearch
        sudo systemctl enable elasticsearch
        sudo systemctl start elasticsearch
        
        log "Elasticsearch installed and started!"
    else
        log "Elasticsearch installation skipped (disabled in configuration)"
        mark_elasticsearch_skipped
    fi
    save_progress "elasticsearch"
}

# Mark elasticsearch as intentionally skipped
mark_elasticsearch_skipped() {
    echo "elasticsearch_skipped=$(date)" >> "$PROGRESS_FILE"
}

# Clone and setup repository
setup_repository() {
    log "Cloning Airline Club repository..."
    
    if [[ -d "$INSTALL_DIR" ]]; then
        warn "Installation directory already exists: $INSTALL_DIR"
        read -p "Do you want to overwrite it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
        else
            while true; do
                read -p "Enter alternate installation directory path: " new_dir
                if [[ -z "$new_dir" ]]; then
                    warn "No path entered. Keeping existing directory. Aborting repository setup."
                    return
                fi
                if [[ -d "$new_dir" ]]; then
                    warn "Directory '$new_dir' already exists."
                    read -p "Overwrite it? (y/N): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        rm -rf "$new_dir"
                        INSTALL_DIR="$new_dir"
                        break
                    else
                        continue
                    fi
                else
                    INSTALL_DIR="$new_dir"
                    mkdir -p "$INSTALL_DIR"
                    break
                fi
            done
        fi
    fi
    
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    
    # Checkout V2 branch
    log "Switching to V2 branch..."
    git checkout v2
    
    log "Repository setup complete!"
    save_progress "repository"
}

# Configure application
configure_application() {
    log "Configuring Airline Club application..."
    
    cd "$INSTALL_DIR"
    
    # Update database configuration in Constants.scala
    log "Updating database configuration..."
    sed -i "s/password = \".*\"/password = \"$DB_PASS\"/g" airline-data/src/main/scala/com/patson/data/Constants.scala
    
    # Configure Google API key if provided
    if [[ -n "$GOOGLE_API_KEY" ]]; then
        log "Configuring Google Maps API key..."
        if [[ -f "airline-web/conf/application.conf" ]]; then
            sed -i "s/google.mapKey=.*/google.mapKey=\"$GOOGLE_API_KEY\"/g" airline-web/conf/application.conf
        else
            echo "google.mapKey=\"$GOOGLE_API_KEY\"" >> airline-web/conf/application.conf
        fi
    fi
    
    # Configure server port and bind address
    log "Configuring server to bind on $BIND_ADDRESS:$SERVER_PORT..."
    if [[ -f "airline-web/conf/application.conf" ]]; then
        sed -i "s/http.port=.*/http.port=$SERVER_PORT/g" airline-web/conf/application.conf
        sed -i "s/http.address=.*/http.address=\"$BIND_ADDRESS\"/g" airline-web/conf/application.conf
        # Ensure Play application secret is set for prod mode
        APP_SECRET=${APP_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}
        # Replace deprecated key if present
        sed -i "s/^play.crypto.secret.*/play.http.secret.key=\"$APP_SECRET\"/g" airline-web/conf/application.conf
        if ! grep -q '^play.http.secret.key' airline-web/conf/application.conf; then
            echo "play.http.secret.key=\"$APP_SECRET\"" >> airline-web/conf/application.conf
        fi
    else
        echo "http.port=$SERVER_PORT" >> airline-web/conf/application.conf
        echo "http.address=\"$BIND_ADDRESS\"" >> airline-web/conf/application.conf
        # Add secret if file was just created
        APP_SECRET=${APP_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}
        echo "play.http.secret.key=\"$APP_SECRET\"" >> airline-web/conf/application.conf
    fi
    
    # Configure banner if enabled
    if [[ "$BANNER_ENABLED" == "true" ]]; then
        log "Enabling banner functionality..."
        sed -i "s/bannerEnabled=.*/bannerEnabled=true/g" airline-web/conf/application.conf
    fi
    
    log "Application configured successfully!"
    save_progress "configure"
}

# Build application
build_application() {
    log "Building Airline Club application..."
    
    cd "$INSTALL_DIR/airline-data"
    
    # Publish airline-data locally
    log "Publishing airline-data..."
    $NICE_CMD $IONICE_CMD sbt -batch publishLocal
    
    log "Application built successfully!"
    save_progress "build"
}

# Initialize database
init_database() {
    log "Initializing database (this may take a while)..."

    cd "$INSTALL_DIR/airline-data"

    # Skip if already initialized
    if check_step_completed "database"; then
        log "Database already initialized. Skipping initialization step."
        return 0
    fi

    # If a previous init is still running, do not start another
    if [[ -f "$INSTALL_DIR/datainit.pid" ]]; then
        local pid
        pid=$(cat "$INSTALL_DIR/datainit.pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
            log "Database initialization already in progress (PID: $pid). Monitor with: tail -f \"$INSTALL_DIR/datainit.log\""
            return 0
        else
            warn "Found stale datainit.pid. Removing and starting a new initialization."
            rm -f "$INSTALL_DIR/datainit.pid"
        fi
    fi

    # Run MainInit in background with nohup, logging and PID
    log "Launching MainInit in background (nohup) with logging to $INSTALL_DIR/datainit.log ..."
    $NICE_CMD $IONICE_CMD nohup bash -lc 'echo "1" | sbt -batch "runMain com.patson.init.MainInit"' > "$INSTALL_DIR/datainit.log" 2>&1 &
    pid=$!
    # Fallback if PID is not captured due to subshell/nohup edge cases
    if [[ -z "$pid" ]]; then
        pid=$(pgrep -f "com.patson.init.MainInit" | head -n 1 || true)
    fi
    if [[ -n "$pid" ]]; then
        echo "$pid" > "$INSTALL_DIR/datainit.pid"
        log "MainInit started (PID: $pid). Monitor progress with: tail -f \"$INSTALL_DIR/datainit.log\""
    else
        warn "Could not determine MainInit PID automatically. Use 'pgrep -f com.patson.init.MainInit' to locate it."
    fi

    log "Database initialization started in background. It will continue even if your SSH session disconnects."
    save_progress "database"

    # Create installation completion marker
    cat > "$INSTALL_DIR/.installation_complete" << EOF
# Airline Club Installation Complete
# This file indicates that the Airline Club installation has been successfully completed
# Created: $(date)
# Installation Directory: $INSTALL_DIR
# Components Installed:
# - Dependencies (Java, SBT, MySQL)
# - MySQL Database (airline_club)
# - Repository (airline-club)
# - Application Configuration
# - Build Process
# - Database Initialization

INSTALLATION_STATUS=COMPLETE
INSTALLATION_DATE=$(date '+%Y-%m-%d %H:%M:%S')
INSTALL_DIR=$INSTALL_DIR
COMPONENTS=dependencies,mysql,elasticsearch,repository,configure,build,database
EOF

    log "Installation completion marker created!"
    clear_progress  # Installation complete
}

# Analyzer: ensure resource profile, config integrity, and database readiness
analyze_database_status() {
    log "Analyzing database schema..."
    # Verify MySQL connectivity first
    if ! mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
        warn "Initial DB connectivity failed. Attempting MySQL 8 native auth fix..."
        ensure_mysql_native_auth || true
        if ! mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1;" >/dev/null 2>&1; then
            error "Cannot connect to MySQL with configured credentials for $DB_NAME"
            return 1
        fi
    fi
    local issues=0
    local critical=(user airplane_model airport airline cycle)
    for tbl in "${critical[@]}"; do
        if ! mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT 1 FROM \`$tbl\` LIMIT 1;" >/dev/null 2>&1; then
            warn "Missing table: $tbl"
            issues=$((issues+1))
        fi
    done
    # Minimal data sanity checks
    # airplane_model should have at least 1 row
    if mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT COUNT(*) AS c FROM \`airplane_model\`;" 2>/dev/null | awk 'NR==2 { if ($1+0 < 1) exit 1 }'; then
        :
    else
        warn "Insufficient airplane models (expected >= 1)"
        issues=$((issues+1))
    fi
    # airport should have many rows; ensure at least 100
    if mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SELECT COUNT(*) AS c FROM \`airport\`;" 2>/dev/null | awk 'NR==2 { if ($1+0 < 100) exit 1 }'; then
        :
    else
        warn "Insufficient airports loaded (expected >= 100)"
        issues=$((issues+1))
    fi
    if (( issues == 0 )); then
        log "Database schema and baseline data look healthy."
        return 0
    else
        warn "Database has ${issues} schema/data issues."
        return 1
    fi
}

# Ensure MySQL 8 uses legacy auth for JDBC (mysql_native_password)
ensure_mysql_native_auth() {
    local ver
    ver=$(mysql --version 2>/dev/null || true)
    if [[ "$ver" == *"Ver 8."* || "$ver" == *"Distrib 8."* ]]; then
        log "Detected MySQL 8.x - enforcing mysql_native_password for user '$DB_USER'"
        if sudo mysql -e "ALTER USER '$DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$DB_PASS'; FLUSH PRIVILEGES;" >/dev/null 2>&1; then
            log "MySQL native auth applied to '$DB_USER'@'localhost'"
            return 0
        else
            warn "Failed to apply mysql_native_password automatically. You may need to run as a user with sufficient privileges."
            return 1
        fi
    fi
    return 0
}

ensure_conf_integrity() {
    local conf_path="$1"
    if [[ -f "$conf_path" ]]; then
        # Normalize file and secrets, apply trusted hosts
        sed -i -e '$a\' "$conf_path"
        sed -i 's/}\s*play\.http\.secret\.key.*/}/' "$conf_path"
        sed -i '/^play\.http\.secret\.key/d' "$conf_path"
        sed -i '/play\.http\.secret\.key/d' "$conf_path"
        sed -i '/application\.secret/d' "$conf_path"
        sed -i '/play\.crypto\.secret/d' "$conf_path"
        apply_hosts_to_conf "$conf_path"
        if ! grep -q '^play\.http\.secret\.key' "$conf_path"; then
            APP_SECRET=${APP_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}
            printf '\nplay.http.secret.key="%s"\napplication.secret="%s"\n' "$APP_SECRET" "$APP_SECRET" >> "$conf_path"
        fi
        log "Ensured conf integrity for $(basename "$conf_path")"
    else
        warn "Config not found: $conf_path"
    fi
}

init_database_blocking() {
    log "Running blocking database initialization via MainInit..."
    cd "$INSTALL_DIR/airline-data"
    # Build/publish locally in case dependencies are needed
    $NICE_CMD $IONICE_CMD sbt -batch publishLocal >> "$INSTALL_DIR/datainit.log" 2>&1 || true
    # Run MainInit in foreground and stream logs
    $NICE_CMD $IONICE_CMD sbt -batch "runMain com.patson.init.MainInit" >> "$INSTALL_DIR/datainit.log" 2>&1 || {
        warn "MainInit run encountered errors; see $INSTALL_DIR/datainit.log"
    }
    # Verify tables appear within a grace period
    local wait=0
    while [[ $wait -le 120 ]]; do
        if analyze_database_status; then
            log "Database initialization confirmed."
            return 0
        fi
        sleep 5
        wait=$((wait+5))
        if [[ $((wait % 30)) -eq 0 ]]; then
            log "Waiting for tables to appear... ($wait/120s)"
        fi
    done
    warn "Database still incomplete after MainInit blocking run."
    return 1
}

analyze_and_fix() {
    log "Running analyzer: resource profile, config integrity, database schema..."
    # Ensure resource profile is applied (LOW/TIGHT modes)
    detect_system_resources
    # Ensure config integrity (source and staged)
    if [[ -d "$INSTALL_DIR/airline-web" ]]; then
        ensure_conf_integrity "$INSTALL_DIR/airline-web/conf/application.conf"
        if [[ -f "$INSTALL_DIR/airline-web/target/universal/stage/conf/application.conf" ]]; then
            ensure_conf_integrity "$INSTALL_DIR/airline-web/target/universal/stage/conf/application.conf"
        fi
    fi
    # Check DB; repair if needed
    if ! analyze_database_status; then
        warn "Database not initialized; attempting repair..."
        stop_services
        if init_database_blocking; then
            log "Database repair completed."
            return 0
        else
            warn "Database repair failed or incomplete. Proceeding may cause startup failures."
            return 1
        fi
    fi
    return 0
}

# Start services
start_services() {
    log "Starting Airline Club services..."
    
    cd "$INSTALL_DIR"
    
    # Pre-start analyzer
    log "Running pre-start analyzer (DB, configs, resources)..."
    if ! analyze_and_fix; then
        warn "Pre-start analyzer reported issues; continuing with service start."
    fi
    
    # Start background simulation
    log "Starting background simulation..."
    cd airline-data
    $NICE_CMD $IONICE_CMD nohup sbt "runMain com.patson.MainSimulation" > ../simulation.log 2>&1 &
    echo $! > ../simulation.pid
    
    log "Waiting for simulation to initialize..."
    log "This may take 2-3 minutes for SBT to compile and start..."
    
    # Wait and check simulation startup
    local sim_wait=0
    while [[ $sim_wait -lt 180 ]]; do
        if [[ -s ../simulation.log ]] && (grep -q "started" ../simulation.log 2>/dev/null || grep -q "running" ../simulation.log 2>/dev/null); then
            log "Simulation started successfully!"
            break
        fi
        if [[ $((sim_wait % 30)) -eq 0 ]]; then
            log "Still waiting for simulation... ($sim_wait/180 seconds)"
        fi
        sleep 5
        sim_wait=$((sim_wait + 5))
    done
    
    # Start web server
    log "Starting web server..."
    cd ../airline-web
    # Ensure Play secret exists in source conf before staging
    # Ensure newline at end to avoid concatenation causing HOCON parse errors
    if [[ -f conf/application.conf ]]; then
        sed -i -e '$a\' conf/application.conf
        # Fix cases where a secret got concatenated on the same line as a closing brace
        sed -i 's/}\s*play\.http\.secret\.key.*/}/' conf/application.conf
        # Remove any existing secret lines to avoid duplicates
        sed -i '/^play\.http\.secret\.key/d' conf/application.conf
        sed -i '/play\.http\.secret\.key/d' conf/application.conf
        sed -i '/application\.secret/d' conf/application.conf
        sed -i '/play\.crypto\.secret/d' conf/application.conf
        # Apply trusted hosts to source conf
        apply_hosts_to_conf "conf/application.conf"
        # Append a canonical secret if none exists
        if ! grep -q '^play\.http\.secret\.key' conf/application.conf; then
            APP_SECRET=${APP_SECRET:-$(head -c 48 /dev/urandom | base64 | tr -d '\n')}
            printf '\nplay.http.secret.key=\"%s\"\napplication.secret=\"%s\"\n' "$APP_SECRET" "$APP_SECRET" >> conf/application.conf
        fi
    fi
    # Build a staged (prod) distribution so the server can run detached reliably (no dev-mode console shutdown)
    # Ensure APP_SECRET is set even if already present in source
    if [[ -z "$APP_SECRET" ]]; then
        APP_SECRET=$(head -c 48 /dev/urandom | base64 | tr -d '\n')
    fi
    $NICE_CMD $IONICE_CMD sbt stage >> ../webserver.log 2>&1
    # Normalize staged conf to avoid HOCON parse errors (ensure trailing newline, preserve braces, and canonical keys)
    if [[ -f target/universal/stage/conf/application.conf ]]; then
        # Ensure file ends with newline
        sed -i -e '$a\' target/universal/stage/conf/application.conf
        # If a secret was concatenated on the same line as a closing brace, split it back out by keeping the brace
        sed -i 's/}\s*play\.http\.secret\.key.*/}/' target/universal/stage/conf/application.conf
        # Remove any remaining secret lines to avoid duplicates
        sed -i '/^play\.http\.secret\.key/d' target/universal/stage/conf/application.conf
        sed -i '/play\.http\.secret\.key/d' target/universal/stage/conf/application.conf
        sed -i '/application\.secret/d' target/universal/stage/conf/application.conf
        sed -i '/play\.crypto\.secret/d' target/universal/stage/conf/application.conf
        # Apply trusted hosts to staged conf
        apply_hosts_to_conf "target/universal/stage/conf/application.conf"
        # Append canonical secrets with explicit newline
        printf '\nplay.http.secret.key=\"%s\"\napplication.secret=\"%s\"\n' "$APP_SECRET" "$APP_SECRET" >> target/universal/stage/conf/application.conf
    fi
    # Pass secret via JVM properties to ensure runtime recognizes it across Play versions
    APP_SECRET_PROP="-Dplay.http.secret.key=$APP_SECRET -Dapplication.secret=$APP_SECRET -Dplay.crypto.secret=$APP_SECRET"
    # Start the staged binary with explicit bind address, port, and secret
    $NICE_CMD $IONICE_CMD nohup ./target/universal/stage/bin/airline-web $APP_SECRET_PROP -Dhttp.port=$SERVER_PORT -Dhttp.address=$BIND_ADDRESS >> ../webserver.log 2>&1 &
    echo $! > ../webserver.pid
    
    log "Waiting for web server to start..."
    log "This may take 2-3 minutes for SBT to compile and start..."
    
    # Wait and check web server startup
    local web_wait=0
    while [[ $web_wait -lt 180 ]]; do
        if [[ -s ../webserver.log ]] && (grep -q "started" ../webserver.log 2>/dev/null || ss -ln | grep -q ":$SERVER_PORT "); then
            log "Web server started successfully!"
            break
        fi
        if [[ $((web_wait % 30)) -eq 0 ]]; then
            log "Still waiting for web server... ($web_wait/180 seconds)"
        fi
        sleep 5
        web_wait=$((web_wait + 5))
    done
    
    # Final status check
    if ss -ln | grep -q ":$SERVER_PORT " && (is_service_running "MainSimulation" || pgrep -f "airline-data"); then
        log "Airline Club started successfully!"
        log "Web interface available at: http://$BIND_ADDRESS:$SERVER_PORT"
    else
        error "Failed to start services. Check logs for details:"
        error "  - Simulation log: $INSTALL_DIR/simulation.log"
        error "  - Web server log: $INSTALL_DIR/webserver.log"
        error "  - Use 'tail -f $INSTALL_DIR/simulation.log' to monitor simulation startup"
        error "  - Use 'tail -f $INSTALL_DIR/webserver.log' to monitor web server startup"
        error "  - Services may still be starting - check logs in a few minutes"
        error "  - Current simulation log size: $(wc -l < $INSTALL_DIR/simulation.log 2>/dev/null || echo '0') lines"
        error "  - Current webserver log size: $(wc -l < $INSTALL_DIR/webserver.log 2>/dev/null || echo '0') lines"
    fi
}

# Stop services
stop_services() {
    log "Stopping Airline Club services..."
    
    cd "$INSTALL_DIR"
    
    # Stop web server
    if [[ -f webserver.pid ]]; then
        local webserver_pid=$(cat webserver.pid)
        if kill -0 "$webserver_pid" 2>/dev/null; then
            kill "$webserver_pid"
            log "Web server stopped"
        fi
        rm -f webserver.pid
    fi
    
    # Stop simulation
    if [[ -f simulation.pid ]]; then
        local simulation_pid=$(cat simulation.pid)
        if kill -0 "$simulation_pid" 2>/dev/null; then
            kill "$simulation_pid"
            log "Background simulation stopped"
        fi
        rm -f simulation.pid
    fi
    
    # Kill any remaining processes
    pkill -f "MainSimulation" 2>/dev/null || true
    pkill -f "airline-web" 2>/dev/null || true
    
    log "All services stopped"
}

# Get service status
get_status() {
    log "Checking Airline Club service status..."
    
    # Database initialization status
    if [[ -f "$INSTALL_DIR/datainit.pid" ]]; then
        local init_pid
        init_pid=$(cat "$INSTALL_DIR/datainit.pid" 2>/dev/null || true)
        if [[ -n "$init_pid" ]] && kill -0 "$init_pid" 2>/dev/null; then
            echo -e "${YELLOW}•${NC} Database initialization: In progress (PID: $init_pid)"
            echo -e "${BLUE}→${NC} Log: $INSTALL_DIR/datainit.log"
        else
            if pgrep -f "com.patson.init.MainInit" > /dev/null; then
                echo -e "${YELLOW}•${NC} Database initialization: In progress (detected running process)"
            else
                echo -e "${GREEN}✓${NC} Database initialization: Completed/Not running"
            fi
        fi
    else
        if pgrep -f "com.patson.init.MainInit" > /dev/null; then
            echo -e "${YELLOW}•${NC} Database initialization: In progress (process detected)"
            echo -e "${BLUE}→${NC} Log: $INSTALL_DIR/datainit.log"
        else
            echo -e "${YELLOW}•${NC} Database initialization: Not started"
        fi
    fi

    # Services
    if is_service_running "MainSimulation"; then
        echo -e "${GREEN}✓${NC} Background simulation: Running"
    else
        echo -e "${RED}✗${NC} Background simulation: Stopped"
    fi

    if is_service_running "airline-web"; then
        echo -e "${GREEN}✓${NC} Web server: Running"
        echo -e "${BLUE}→${NC} Web interface: http://$BIND_ADDRESS:$SERVER_PORT"
    else
        echo -e "${RED}✗${NC} Web server: Stopped"
    fi

    # System resource profile
    if [[ "$TIGHT_MODE" == "true" ]]; then
        echo -e "${YELLOW}•${NC} Resource mode: TIGHT (JVM very limited, processes high nice)"
    elif [[ "$LOW_RESOURCE_MODE" == "true" ]]; then
        echo -e "${YELLOW}•${NC} Resource mode: LOW (JVM limits applied, processes nice/ionice)"
    else
        echo -e "${GREEN}✓${NC} Resource mode: NORMAL"
    fi

    echo
    echo -e "${BLUE}Component installation status:${NC}"
    for step in "${INSTALL_STEPS[@]}"; do
        local desc=""
        case $step in
            "dependencies") desc="System dependencies (Java, SBT, MySQL)" ;;
            "mysql") desc="MySQL configuration and user" ;;
            "elasticsearch") desc="Elasticsearch (optional)" ;;
            "repository") desc="Repository cloned and branch checked out" ;;
            "configure") desc="Application configuration" ;;
            "build") desc="Build and publish application" ;;
            "database") desc="Database initialized" ;;
        esac
        if check_step_completed "$step"; then
            echo -e "${GREEN}✓${NC} $desc: Installed/Completed"
        else
            echo -e "${YELLOW}•${NC} $desc: Not completed"
        fi
    done

    # Installation directory status
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${GREEN}✓${NC} Installation directory present: $INSTALL_DIR"
    else
        echo -e "${RED}✗${NC} Installation directory not found: $INSTALL_DIR"
    fi

    # Enhanced dashboard: database overview
    echo
    echo -e "${BLUE}Database status:${NC}"
    echo -e "${BLUE}→${NC} Name: $DB_NAME, User: $DB_USER"
    # Try basic counts (may show N/A if DB not initialized)
    user_count=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "SELECT COUNT(*) FROM \`user\`" 2>/dev/null || echo "")
    airline_count=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "SELECT COUNT(*) FROM \`airline\`" 2>/dev/null || echo "")
    delegate_count=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "SELECT COUNT(*) FROM \`busy_delegate\`" 2>/dev/null || echo "")
    last_cycle=$(mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "SELECT MAX(\`cycle\`) FROM \`cycle\`" 2>/dev/null || echo "")
    if [[ -n "$user_count" ]]; then echo -e "${GREEN}✓${NC} Users: $user_count"; else echo -e "${YELLOW}•${NC} Users: N/A"; fi
    if [[ -n "$airline_count" ]]; then echo -e "${GREEN}✓${NC} Airlines: $airline_count"; else echo -e "${YELLOW}•${NC} Airlines: N/A"; fi
    if [[ -n "$delegate_count" ]]; then echo -e "${GREEN}✓${NC} Busy Delegates: $delegate_count"; else echo -e "${YELLOW}•${NC} Busy Delegates: N/A"; fi
    if [[ -n "$last_cycle" ]]; then echo -e "${GREEN}✓${NC} Current Cycle: $last_cycle"; else echo -e "${YELLOW}•${NC} Current Cycle: N/A"; fi
}

# --- Admin helpers ---
mysql_exec() {
    local query="$1"
    mysql -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -N -e "$query"
}

generate_user_secret() {
    local password="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    # 8-byte salt
    openssl rand -out "$tmpdir/salt.bin" 8
    # initial digest: sha1(salt || password)
    cat "$tmpdir/salt.bin" <(printf "%s" "$password") | openssl dgst -binary -sha1 > "$tmpdir/digest.bin"
    # 1000 iterations over previous digest bytes
    for i in $(seq 1 1000); do
        openssl dgst -binary -sha1 < "$tmpdir/digest.bin" > "$tmpdir/digest2.bin"
        mv "$tmpdir/digest2.bin" "$tmpdir/digest.bin"
    done
    local salt_b64 digest_b64
    salt_b64=$(base64 -w 0 < "$tmpdir/salt.bin")
    digest_b64=$(base64 -w 0 < "$tmpdir/digest.bin")
    echo "$salt_b64|$digest_b64"
    rm -rf "$tmpdir"
}

user_add() {
    echo -e "${BLUE}Add User${NC}"
    read -p "Enter user name: " user_name
    read -p "Enter email: " email
    read -p "Enter status [ACTIVE|INACTIVE|CHAT_BANNED|BANNED] (default ACTIVE): " status
    status=${status:-ACTIVE}
    case "$status" in ACTIVE|INACTIVE|CHAT_BANNED|BANNED) ;; *) error "Invalid status"; return ;; esac
    read -p "Enter level (default 0): " level
    level=${level:-0}
    read -s -p "Enter password: " password; echo
    if [[ -z "$user_name" || -z "$email" || -z "$password" ]]; then error "user_name, email and password are required"; return; fi
    mysql_exec "INSERT INTO \`user\` (user_name, email, status, level) VALUES ('$user_name', '$email', '$status', $level) ON DUPLICATE KEY UPDATE email=VALUES(email), status=VALUES(status), level=VALUES(level)"
    local sec
    sec=$(generate_user_secret "$password")
    local salt_b64="${sec%%|*}"
    local digest_b64="${sec##*|}"
    mysql_exec "REPLACE INTO \`user_secret\` (user_name, digest, salt) VALUES ('$user_name', '$digest_b64', '$salt_b64')"
    log "User '$user_name' created/updated successfully."
}

user_edit() {
    echo -e "${BLUE}Edit User${NC}"
    read -p "Enter user name: " user_name
    if [[ -z "$user_name" ]]; then error "User name required"; return; fi
    read -p "New email (leave blank to keep): " email
    read -p "New status [ACTIVE|INACTIVE|CHAT_BANNED|BANNED] (leave blank to keep): " status
    if [[ -n "$status" ]]; then case "$status" in ACTIVE|INACTIVE|CHAT_BANNED|BANNED) ;; *) error "Invalid status"; return ;; esac; fi
    read -p "New level (leave blank to keep): " level
    read -p "Reset password? (y/N): " -n 1 reset_pw; echo
    local sets=()
    if [[ -n "$email" ]]; then sets+=("email='$email'"); fi
    if [[ -n "$status" ]]; then sets+=("status='$status'"); fi
    if [[ -n "$level" ]]; then sets+=("level=$level"); fi
    if [[ ${#sets[@]} -gt 0 ]]; then
        local set_clause=$(IFS=,; echo "${sets[*]}")
        mysql_exec "UPDATE user SET $set_clause WHERE user_name='$user_name'"
    fi
    if [[ "$reset_pw" =~ ^[Yy]$ ]]; then
        read -s -p "Enter new password: " password; echo
        if [[ -z "$password" ]]; then error "Password cannot be empty"; return; fi
        local sec
        sec=$(generate_user_secret "$password")
        local salt_b64="${sec%%|*}"
        local digest_b64="${sec##*|}"
        mysql_exec "REPLACE INTO \`user_secret\` (user_name, digest, salt) VALUES ('$user_name', '$digest_b64', '$salt_b64')"
        log "Password updated for '$user_name'"
    fi
    log "User '$user_name' updated."
}

user_delete() {
    echo -e "${BLUE}Delete User${NC}"
    read -p "Enter user name: " user_name
    if [[ -z "$user_name" ]]; then error "User name required"; return; fi
    read -p "Are you sure you want to delete '$user_name'? (y/N): " -n 1 confirm; echo
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mysql_exec "DELETE FROM user WHERE user_name='$user_name'"
        log "User '$user_name' deleted."
    else
        log "Deletion cancelled."
    fi
}

resolve_airline_id() {
    echo -e "${BLUE}Resolve Airline${NC}"
    echo "1) Enter airline ID"
    echo "2) Enter user name (mapped via user_airline)"
    read -p "Select (1-2): " sel
    local airline_id=""
    case "$sel" in
        1) read -p "Airline ID: " airline_id ;;
        2) read -p "User name: " user_name; airline_id=$(mysql_exec "SELECT airline FROM \`user_airline\` WHERE user_name='$user_name' LIMIT 1"); if [[ -z "$airline_id" ]]; then error "No airline mapped to user '$user_name'"; return 1; fi ;;
        *) error "Invalid selection"; return 1 ;;
    esac
    if [[ -z "$airline_id" ]]; then error "Airline ID required"; return 1; fi
    echo "$airline_id"
}

get_current_cycle() {
    mysql_exec "SELECT MAX(cycle) FROM cycle"
}

money_add() {
    local airline_id amount
    airline_id=$(resolve_airline_id) || return
    read -p "Amount to add: " amount
    if [[ -z "$amount" ]]; then error "Amount required"; return; fi
    mysql_exec "UPDATE airline_info SET balance = balance + $amount WHERE airline=$airline_id"
    log "Added $amount to airline $airline_id"
}

money_remove() {
    local airline_id amount
    airline_id=$(resolve_airline_id) || return
    read -p "Amount to remove: " amount
    if [[ -z "$amount" ]]; then error "Amount required"; return; fi
    mysql_exec "UPDATE airline_info SET balance = balance - $amount WHERE airline=$airline_id"
    log "Removed $amount from airline $airline_id"
}

money_overwrite() {
    local airline_id amount
    airline_id=$(resolve_airline_id) || return
    read -p "Overwrite balance to: " amount
    if [[ -z "$amount" ]]; then error "Amount required"; return; fi
    mysql_exec "UPDATE airline_info SET balance = $amount WHERE airline=$airline_id"
    log "Set balance of airline $airline_id to $amount"
}

delegate_add() {
    local airline_id task_type count available_after
    airline_id=$(resolve_airline_id) || return
    read -p "Task type (numeric): " task_type
    read -p "How many delegates to add: " count
    read -p "Available after how many cycles (default 0): " available_after; available_after=${available_after:-0}
    local current_cycle=$(get_current_cycle)
    local available_cycle=$((current_cycle + available_after))
    for ((i=1;i<=count;i++)); do
        mysql_exec "INSERT INTO busy_delegate (airline, task_type, available_cycle) VALUES ($airline_id, $task_type, $available_cycle)"
    done
    log "Added $count delegates for airline $airline_id (task_type=$task_type, available_cycle=$available_cycle)"
}

delegate_remove() {
    local airline_id task_type count
    airline_id=$(resolve_airline_id) || return
    read -p "Task type (numeric): " task_type
    read -p "How many delegates to remove: " count
    mysql_exec "DELETE FROM busy_delegate WHERE airline=$airline_id AND task_type=$task_type LIMIT $count"
    log "Removed up to $count delegates for airline $airline_id (task_type=$task_type)"
}

delegate_overwrite() {
    local airline_id task_type desired available_after
    airline_id=$(resolve_airline_id) || return
    read -p "Task type (numeric): " task_type
    read -p "Set total delegates to: " desired
    read -p "Available after how many cycles for new delegates (default 0): " available_after; available_after=${available_after:-0}
    local current=$(mysql_exec "SELECT COUNT(*) FROM \`busy_delegate\` WHERE airline=$airline_id AND task_type=$task_type")
    if [[ -z "$current" ]]; then error "Unable to read current delegate count"; return; fi
    local diff=$((desired - current))
    if (( diff > 0 )); then
        local current_cycle=$(get_current_cycle)
        local available_cycle=$((current_cycle + available_after))
        for ((i=1;i<=diff;i++)); do
            mysql_exec "INSERT INTO busy_delegate (airline, task_type, available_cycle) VALUES ($airline_id, $task_type, $available_cycle)"
        done
        log "Added $diff delegates to reach $desired"
    elif (( diff < 0 )); then
        local remove_count=$(( -diff ))
        mysql_exec "DELETE FROM busy_delegate WHERE airline=$airline_id AND task_type=$task_type LIMIT $remove_count"
        log "Removed $remove_count delegates to reach $desired"
    else
        log "Delegate count already at $desired"
    fi
}

delegate_remove_all() {
    local airline_id
    airline_id=$(resolve_airline_id) || return
    mysql_exec "DELETE FROM busy_delegate WHERE airline=$airline_id"
    log "Removed all delegates for airline $airline_id"
}

admin_user_menu() {
    while true; do
        clear
        echo -e "${BLUE}User Management${NC}"
        echo "1) Add User"
        echo "2) Edit User"
        echo "3) Delete User"
        echo "4) Back"
        echo
        read -p "Select an option (1-4): " uchoice
        case $uchoice in
            1) user_add ;;
            2) user_edit ;;
            3) user_delete ;;
            4) break ;;
            *) error "Invalid option." ;;
        esac
        if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
    done
}

admin_money_delegate_menu() {
    while true; do
        clear
        echo -e "${BLUE}Money/Delegate Management${NC}"
        echo "1) Add money"
        echo "2) Remove money"
        echo "3) Overwrite balance"
        echo "4) Add delegates"
        echo "5) Remove delegates"
        echo "6) Overwrite delegates"
        echo "7) Remove all delegates"
        echo "8) Back"
        echo
        read -p "Select an option (1-8): " mchoice
        case $mchoice in
            1) money_add ;;
            2) money_remove ;;
            3) money_overwrite ;;
            4) delegate_add ;;
            5) delegate_remove ;;
            6) delegate_overwrite ;;
            7) delegate_remove_all ;;
            8) break ;;
            *) error "Invalid option." ;;
        esac
        if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
    done
}

# Uninstall application
uninstall_application() {
    log "Uninstalling Airline Club..."
    
    # Stop services first
    stop_services
    
    # Remove installation directory
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        log "Installation directory removed"
    fi
    
    # Remove database (optional)
    read -p "Do you want to remove the database as well? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo mysql -e "DROP DATABASE IF EXISTS $DB_NAME;"
        sudo mysql -e "DROP USER IF EXISTS '$DB_USER'@'localhost';"
        log "Database removed"
    fi
    
    log "Airline Club uninstalled successfully!"
}

# Cleanup installation files
cleanup_installation() {
    log "Cleaning up installation files..."
    
    # Remove downloaded packages and cache
    sudo apt autoremove -y
    sudo apt autoclean
    # Purge Node.js and npm installed for asset pipeline (optional)
    read -p "Do you want to remove Node.js and npm? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo apt purge -y nodejs npm || true
        sudo apt autoremove -y
        log "Node.js and npm removed"
    fi
    
    # Remove SBT cache (optional)
    read -p "Do you want to remove SBT cache? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf ~/.sbt
        rm -rf ~/.ivy2
        log "SBT cache removed"
    fi
    
    log "Cleanup completed!"
}

# User input functions
get_user_input() {
    echo
    echo -e "${BLUE}=== Configuration ===${NC}"
    
    # Google API Key
    read -p "Enter Google Maps API Key (optional, press Enter to skip): " GOOGLE_API_KEY
    
    # Server port
    read -p "Enter server port (default: $DEFAULT_PORT): " input_port
    SERVER_PORT=${input_port:-$DEFAULT_PORT}
    
    # Elasticsearch
    read -p "Install Elasticsearch for flight search? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ELASTICSEARCH_ENABLED=true
    fi
    
    # Banner functionality
    read -p "Enable banner functionality? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        BANNER_ENABLED=true
        warn "Banner functionality requires additional Google Photos API setup"
    fi
}

# Check if step is actually completed by verifying system state
check_step_completed() {
    local step_name="$1"
    
    # Check for installation completion marker file as additional verification
    if [[ -f "$INSTALL_DIR/.installation_complete" ]]; then
        # If installation is marked as complete, verify the specific component exists
        case "$step_name" in
            "dependencies")
                command -v java >/dev/null 2>&1 && command -v sbt >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1 && return 0
                ;;
            "mysql")
                systemctl is-active --quiet mysql 2>/dev/null && return 0
                ;;
            "elasticsearch")
                # Always consider elasticsearch complete if installation is marked complete
                return 0
                ;;
            "repository")
                if [[ -d "$INSTALL_DIR" ]] && \
                   [[ -d "$INSTALL_DIR/airline-web" ]] && \
                   [[ -d "$INSTALL_DIR/airline-data" ]]; then
                return 0
                fi
                ;;
            "configure")
                if [[ -f "$INSTALL_DIR/airline-web/conf/application.conf" ]] && \
                   [[ -f "$INSTALL_DIR/airline-data/src/main/resources/application.conf" ]]; then
                # Verify database configuration is present
                if grep -q "db.default.url" "$INSTALL_DIR/airline-web/conf/application.conf" 2>/dev/null; then
                    return 0
                fi
            fi
            ;;
        "build")
            if [[ -d "$INSTALL_DIR/airline-web/target" ]] && \
               [[ -d "$INSTALL_DIR/airline-data/target" ]]; then
                # Check for published local artifacts
                if find ~/.ivy2/local -name "*airline*" -type d 2>/dev/null | grep -q airline; then
                    return 0
                fi
            fi
            ;;
        "database")
            # Check if database is initialized with critical tables
            if [[ -n "$DB_USER" && -n "$DB_PASS" && -n "$DB_NAME" ]]; then
                if mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1 FROM airport LIMIT 1;" >/dev/null 2>&1 && \
                   mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1 FROM user LIMIT 1;" >/dev/null 2>&1 && \
                   mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT 1 FROM alliance LIMIT 1;" >/dev/null 2>&1; then
                    return 0
                fi
            elif [[ -n "$MYSQL_ROOT_PASSWORD" && -n "$DB_NAME" ]]; then
                if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D "$DB_NAME" -e "SELECT 1 FROM airport LIMIT 1;" >/dev/null 2>&1 && \
                   mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D "$DB_NAME" -e "SELECT 1 FROM user LIMIT 1;" >/dev/null 2>&1 && \
                   mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D "$DB_NAME" -e "SELECT 1 FROM alliance LIMIT 1;" >/dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
    esac
    fi
    
    case "$step_name" in
        "dependencies")
            # Check if Java, SBT, and MySQL are installed
            if command -v java >/dev/null 2>&1 && \
               command -v sbt >/dev/null 2>&1 && \
               command -v mysql >/dev/null 2>&1; then
                return 0
            fi
            ;;
        "mysql")
            # Check if MySQL is running and airline_club database exists
            if systemctl is-active --quiet mysql 2>/dev/null; then
                # Try to connect with saved credentials or check if database exists
                if [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
                    if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "USE airline_club;" >/dev/null 2>&1; then
                        return 0
                    fi
                elif mysql -u root -e "USE airline_club;" >/dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
        "elasticsearch")
            # Check if Elasticsearch is installed and running (optional step)
            if command -v elasticsearch >/dev/null 2>&1; then
                if systemctl is-active --quiet elasticsearch 2>/dev/null || \
                   pgrep -f elasticsearch >/dev/null 2>&1; then
                    return 0
                fi
            fi
            # For elasticsearch, we also consider it "completed" if it's intentionally skipped
            # Check if there's a skip marker or if other steps are completed without it
            if [[ -f "$PROGRESS_FILE" ]] && grep -q "elasticsearch_skipped" "$PROGRESS_FILE" 2>/dev/null; then
                return 0
            fi
            ;;
        "repository")
            # Check if repository directory exists with proper structure
            if [[ -d "$INSTALL_DIR" ]] && \
               [[ -d "$INSTALL_DIR/airline-web" ]] && \
               [[ -d "$INSTALL_DIR/airline-data" ]]; then
                return 0
            fi
            ;;
        "configure")
            # Check if configuration files exist and are properly set up
            if [[ -f "$INSTALL_DIR/airline-web/conf/application.conf" ]] && \
               [[ -f "$INSTALL_DIR/airline-data/src/main/resources/application.conf" ]]; then
                # Verify database configuration is present
                if grep -q "db.default.url" "$INSTALL_DIR/airline-web/conf/application.conf" 2>/dev/null; then
                    return 0
                fi
            fi
            ;;
        "build")
            # Check if application has been built (look for compiled artifacts)
            if [[ -d "$INSTALL_DIR/airline-web/target" ]] && \
               [[ -d "$INSTALL_DIR/airline-data/target" ]]; then
                # Check for published local artifacts
                if find ~/.ivy2/local -name "*airline*" -type d 2>/dev/null | grep -q airline; then
                    return 0
                fi
            fi
            ;;
        "database")
            # Check if database is initialized with data
            if [[ -n "$DB_USER" && -n "$DB_PASSWORD" && -n "$DB_NAME" ]]; then
                if mysql -u "$DB_USER" -p"$DB_PASS" -D "$DB_NAME" -e "SELECT COUNT(*) FROM airport LIMIT 1;" >/dev/null 2>&1; then
                    return 0
                fi
            elif [[ -n "$MYSQL_ROOT_PASSWORD" ]]; then
                if mysql -u root -p"$MYSQL_ROOT_PASSWORD" -D airline_club -e "SELECT COUNT(*) FROM airport LIMIT 1;" >/dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
    esac
    
    return 1  # Step is not completed
}

# Show step selection menu
show_step_selection_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║     Installation Step Selection      ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
        echo
        echo "Choose installation option:"
        echo
        
        # Check completion status for each step
        local step_status=()
        for step in "${INSTALL_STEPS[@]}"; do
            if check_step_completed "$step"; then
                step_status+=("✓")
            else
                step_status+=("✗")
            fi
        done
        
        echo "1) Full Installation (all steps)"
        echo "2) Start from Dependencies ${step_status[0]}"
        echo "3) Start from MySQL Configuration ${step_status[1]}"
        echo "4) Start from Elasticsearch ${step_status[2]}"
        echo "5) Start from Repository Setup ${step_status[3]}"
        echo "6) Start from Application Configuration ${step_status[4]}"
        echo "7) Start from Build Process ${step_status[5]}"
        echo "8) Start from Database Initialization ${step_status[6]}"
        echo "9) Custom Step Selection"
        echo "10) Back to Main Menu"
        echo
        echo -e "${YELLOW}Legend: ✓ = Completed, ✗ = Not completed${NC}"
        echo
        read -p "Please select an option (1-10): " step_choice
        
        case $step_choice in
            1)
                return 0  # Full installation
                ;;
            2)
                return 0  # Start from dependencies (index 0)
                ;;
            3)
                return 1  # Start from mysql (index 1)
                ;;
            4)
                return 2  # Start from elasticsearch (index 2)
                ;;
            5)
                return 3  # Start from repository (index 3)
                ;;
            6)
                return 4  # Start from configure (index 4)
                ;;
            7)
                return 5  # Start from build (index 5)
                ;;
            8)
                return 6  # Start from database (index 6)
                ;;
            9)
                show_custom_step_selection
                return $?
                ;;
            10)
                return -2  # Back to main menu
                ;;
            *)
                echo -e "${RED}Invalid option. Please select 1-10.${NC}"
                if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                ;;
        esac
    done
}

# Show custom step selection menu
show_custom_step_selection() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Custom Step Selection          ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo "Select which steps to execute (space-separated numbers):"
    echo
    for i in "${!INSTALL_STEPS[@]}"; do
        local step_num=$((i + 1))
        local step_name="${INSTALL_STEPS[$i]}"
        local step_desc=""
        local status_icon="✗"
        
        if check_step_completed "$step_name"; then
            status_icon="✓"
        fi
        
        case $step_name in
            "dependencies") step_desc="Install Java, SBT, MySQL" ;;
            "mysql") step_desc="Configure MySQL database and user" ;;
            "elasticsearch") step_desc="Install Elasticsearch (optional)" ;;
            "repository") step_desc="Repository cloned and checkout v2 branch" ;;
            "configure") step_desc="Configure application settings" ;;
            "build") step_desc="Build and publish application" ;;
            "database") step_desc="Initialize database with MainInit" ;;
        esac
        echo "$step_num) $step_name - $step_desc $status_icon"
    done
    echo
    echo -e "${YELLOW}Legend: ✓ = Completed, ✗ = Not completed${NC}"
    echo
    read -p "Enter step numbers (e.g., '1 3 5' or 'all'): " custom_steps
    
    if [[ "$custom_steps" == "all" ]]; then
        return 0  # Full installation
    fi
    
    # Parse custom steps and create a custom steps array
    CUSTOM_STEPS=()
    for step_num in $custom_steps; do
        if [[ $step_num -ge 1 && $step_num -le ${#INSTALL_STEPS[@]} ]]; then
            local step_index=$((step_num - 1))
            CUSTOM_STEPS+=("${INSTALL_STEPS[$step_index]}")
        else
            warn "Invalid step number: $step_num (ignored)"
        fi
    done
    
    if [[ ${#CUSTOM_STEPS[@]} -eq 0 ]]; then
        error "No valid steps selected."
    fi
    
    return -1  # Custom selection
}

# Full installation
full_install() {
    log "Starting Airline Club installation..."
    
    # Check for previous installation first
    local resume_from_index=-1
    local last_step=$(load_progress)
    if [[ -n "$last_step" ]]; then
        echo -e "${YELLOW}Previous installation detected!${NC}"
        echo "Last completed step: $last_step"
        echo
        echo "1) Resume from next step"
        echo "2) Show step selection menu"
        echo "3) Restart completely"
        echo "4) Cancel"
        echo
        if ! read -p "Please select an option (1-4): " resume_choice; then
            # Default to showing step selection when stdin is not interactive
            resume_choice=2
        fi
        
        case $resume_choice in
            1)
                resume_from_index=$(get_step_index "$last_step")
                ;;
            2)
                set +e
                show_step_selection_menu
                local menu_result=$?
                set -e
                if [[ $menu_result -eq -2 || $menu_result -eq 254 ]]; then
                    return  # Back to main menu
                elif [[ $menu_result -eq -1 || $menu_result -eq 255 ]]; then
                    # Custom selection
                    execute_custom_steps
                    return
                else
                    resume_from_index=$menu_result
                    clear_progress  # Clear old progress for new selection
                fi
                ;;
            3)
                clear_progress
                set +e
                show_step_selection_menu
                local menu_result=$?
                set -e
                if [[ $menu_result -eq -2 || $menu_result -eq 254 ]]; then
                    return  # Back to main menu
                elif [[ $menu_result -eq -1 || $menu_result -eq 255 ]]; then
                    # Custom selection
                    execute_custom_steps
                    return
                else
                    resume_from_index=$menu_result
                fi
                ;;
            4)
                log "Installation cancelled"
                return
                ;;
            *)
                error "Invalid option. Installation cancelled."
                ;;
        esac
    else
        # No previous installation, show step selection menu
        set +e
        show_step_selection_menu
        local menu_result=$?
        set -e
        if [[ $menu_result -eq -2 || $menu_result -eq 254 ]]; then
            return  # Back to main menu
        elif [[ $menu_result -eq -1 || $menu_result -eq 255 ]]; then
            # Custom selection
            execute_custom_steps
            return
        else
            resume_from_index=$menu_result
        fi
    fi
    
    # Get user input if starting from early steps
    if [[ $resume_from_index -le 0 ]]; then
        get_user_input
    else
        log "Loading configuration for partial installation..."
        # Load saved configuration if available
        if [[ -f "$HOME/.airline-club-config" ]]; then
            source "$HOME/.airline-club-config"
            log "Previous configuration loaded"
        else
            warn "Previous configuration not found, using defaults"
            # Get minimal input for later steps
            if [[ $resume_from_index -le 4 ]]; then  # If configure step or earlier
                get_user_input
            fi
        fi
    fi
    
    # Execute installation steps based on resume point
    local steps_to_run=()
    if [[ $resume_from_index -eq 0 ]]; then
        steps_to_run=("${INSTALL_STEPS[@]}")
    else
        # Start from selected step
        for ((i=resume_from_index; i<${#INSTALL_STEPS[@]}; i++)); do
            steps_to_run+=("${INSTALL_STEPS[$i]}")
        done
    fi
    
    # Save configuration for potential resume
    save_configuration
    
    # Execute installation steps
    execute_steps "${steps_to_run[@]}"
    
    # Clean up configuration file
    rm -f "$HOME/.airline-club-config"
    
    log "Installation completed successfully!"
    log "Use './airline-club-manager.sh start' to start the services"
}

# Execute custom steps
execute_custom_steps() {
    log "Starting custom installation steps..."
    
    # Get user input if any early steps are selected
    local needs_input=false
    for step in "${CUSTOM_STEPS[@]}"; do
        local step_index=$(get_step_index "$step")
        if [[ $step_index -le 4 ]]; then  # If configure step or earlier
            needs_input=true
            break
        fi
    done
    
    if [[ $needs_input == true ]]; then
        get_user_input
    else
        # Load saved configuration if available
        if [[ -f "$HOME/.airline-club-config" ]]; then
            source "$HOME/.airline-club-config"
            log "Previous configuration loaded"
        else
            warn "Previous configuration not found, using defaults"
        fi
    fi
    
    # Save configuration
    save_configuration
    
    # Execute selected steps
    execute_steps "${CUSTOM_STEPS[@]}"
    
    # Clean up configuration file
    rm -f "$HOME/.airline-club-config"
    
    log "Custom installation completed successfully!"
    log "Use './airline-club-manager.sh start' to start the services"
}

# Execute installation steps
execute_steps() {
    local steps=("$@")
    
    for step in "${steps[@]}"; do
        # Check if step is already completed
        if check_step_completed "$step"; then
            log "Step '$step' is already completed, skipping..."
            continue
        fi
        
        log "Executing step: $step"
        case $step in
            "dependencies")
                install_dependencies
                ;;
            "mysql")
                configure_mysql
                ;;
            "elasticsearch")
                install_elasticsearch
                ;;
            "repository")
                setup_repository
                ;;
            "configure")
                configure_application
                ;;
            "build")
                build_application
                ;;
            "database")
                init_database
                ;;
            *)
                error "Unknown installation step: $step"
                ;;
        esac
    done
}

# Save configuration for resume
save_configuration() {
    cat > "$HOME/.airline-club-config" << EOF
GOOGLE_API_KEY="$GOOGLE_API_KEY"
SERVER_PORT="$SERVER_PORT"
ELASTICSEARCH_ENABLED=$ELASTICSEARCH_ENABLED
BANNER_ENABLED=$BANNER_ENABLED
TRUSTED_HOSTS="$TRUSTED_HOSTS"
EOF
}

# Main menu
show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Airline Club Installer        ║${NC}"
    echo -e "${BLUE}║              Version 1.0             ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo
    echo "1) Install Airline Club"
    echo "2) Start Services"
    echo "3) Stop Services"
    echo "4) Service Status"
    echo "5) Uninstall"
    echo "6) Cleanup Installation Files"
    echo "7) Admin: User Management"
    echo "8) Admin: Money/Delegate Management"
    echo "9) Exit"
    echo "10) Resource Mode"
    echo "11) Trusted Hosts (Allow IPs/Domains)"
    echo "12) Analyze & Repair (DB & Config)"
    echo
    if ! read -p "Please select an option (1-12): " choice; then
        # If stdin is not available (e.g., piped input ended), default to Exit
        choice=9
    fi
}

# Main function
main() {
    check_root
    detect_os
    detect_system_resources
    
    if [[ $# -eq 0 ]]; then
        while true; do
            show_menu
            case $choice in
                1)
                    full_install
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                2)
                    start_services
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                3)
                    stop_services
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                4)
                    get_status
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                5)
                    uninstall_application
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                6)
                    cleanup_installation
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                7)
                    admin_user_menu
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                8)
                    admin_money_delegate_menu
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                9)
                    log "Goodbye!"
                    exit 0
                    ;;
                10)
                    resource_mode_menu
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                11)
                    trusted_hosts_menu
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                12)
                    log "Manual Analyze & Repair invoked..."
                    if analyze_and_fix; then
                        log "Analyze & Repair completed successfully."
                    else
                        warn "Analyze & Repair reported issues; check $INSTALL_DIR/datainit.log and MySQL."
                    fi
                    if [[ -t 0 ]]; then read -p "Press Enter to continue..." -r; fi
                    ;;
                *)
                    error "Invalid option. Please select 1-12."
                    ;;
            esac
        done
    else
        case $1 in
            "install")
                full_install
                ;;
            "start")
                start_services
                ;;
            "stop")
                stop_services
                ;;
            "status")
                get_status
                ;;
            "uninstall")
                uninstall_application
                ;;
            "cleanup")
                cleanup_installation
                ;;
            "resource-mode")
                resource_mode_menu
                ;;
            "trusted-hosts")
                shift
                if [[ $# -gt 0 ]]; then
                    TRUSTED_HOSTS="$*"
                    ensure_server_ips_in_trusted
                    save_configuration
                    apply_hosts_to_conf "conf/application.conf"
                    apply_hosts_to_conf "target/universal/stage/conf/application.conf"
                    log "Trusted hosts set via CLI to: $TRUSTED_HOSTS"
                else
                    trusted_hosts_menu
                fi
                ;;
            "analyze")
                if analyze_and_fix; then
                    log "Analyze & Repair completed successfully."
                else
                    warn "Analyze & Repair reported issues; check $INSTALL_DIR/datainit.log and MySQL."
                    exit 1
                fi
                ;;
            *)
                echo "Usage: $0 [install|start|stop|status|uninstall|cleanup|resource-mode|trusted-hosts [list]|analyze]"
                echo "Run without arguments for interactive menu"
                exit 1
                ;;
        esac
    fi
}
# Run main function
resource_mode_menu() {
    echo -e "${BLUE}Resource Mode & Performance${NC}"
    echo "Machine: RAM ${MEM_TOTAL_MB}MB, CPU cores ${CPU_CORES}, CPU ${CPU_MODEL}"
    echo "Auto low-resource detection: ${LOW_RESOURCE_MODE}"
    echo "Tight mode: ${TIGHT_MODE}"
    echo "Current SBT_OPTS: ${SBT_OPTS:-<none>}"
    echo "Current nice: ${NICE_CMD:-<none>}"
    echo "Current ionice: ${IONICE_CMD:-<none>}"
    echo
    echo "1) Enable Tight mode (more conservative JVM, higher nice)"
    echo "2) Disable Tight mode"
    echo "3) Back to Main Menu"
    read -p "Select an option (1-3): " rm_choice
    case "$rm_choice" in
        1)
            TIGHT_MODE=true
            set_resource_profile
            log "Tight mode is now ENABLED. New profile will apply to subsequently started processes."
            ;;
        2)
            TIGHT_MODE=false
            set_resource_profile
            log "Tight mode is now DISABLED. Using LOW/NORMAL profile accordingly."
            ;;
        3)
            ;;
        *)
            warn "Invalid selection"
            ;;
    esac
}
# Run main function
main "$@"
