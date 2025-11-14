#!/bin/bash

# Automatic path detection
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
AIRLINE_DATA_PATH=$(find "$SCRIPT_DIR" -type d -name "airline-data" | head -n 1)
AIRLINE_WEB_PATH=$(find "$SCRIPT_DIR" -type d -name "airline-web" | head -n 1)
CGROUP_NAME="airline_sbt_limit"

# Resource limits configuration
MAX_MEMORY_MB=3072  # 3GB max per service (increased from 2GB)
MAX_CPU_RATIO=0.60  # Use 60% of available CPU cores (reduced from 85%)
MAX_MEMORY_RATIO=0.75  # Use up to 75% of available system memory
MAX_PROCESSES=500   # Maximum processes per service (increased from 200)
SSH_KEEPALIVE_INTERVAL=30  # SSH keepalive seconds

# --- Utility functions (defined early for use in initial calculations) ---
# Function to get the local IP address
get_local_ip() {
    hostname -I | awk '{print $1}'
}

# Function to get system CPU cores
get_system_cpu_cores() {
    nproc
}

# Function to get system memory in MB
get_system_memory_mb() {
    free -m | awk '/^Mem:/ {print $2}'
}

# Calculate dynamic CPU cores based on system availability
SYSTEM_CPU_CORES=$(nproc)
SYSTEM_MEMORY_MB=$(get_system_memory_mb)
MAX_CPU_CORES=$(echo "$SYSTEM_CPU_CORES * $MAX_CPU_RATIO" | bc -l 2>/dev/null || echo "2")
MAX_MEMORY_MB=$(echo "$SYSTEM_MEMORY_MB * $MAX_MEMORY_RATIO" | bc -l 2>/dev/null | awk '{print int($1)}')
if [ -z "$MAX_CPU_CORES" ] || [ "$MAX_CPU_CORES" = "0" ]; then
    MAX_CPU_CORES=2  # Fallback to 2 cores if calculation fails
fi
if [ -z "$MAX_MEMORY_MB" ] || [ "$MAX_MEMORY_MB" = "0" ]; then
    MAX_MEMORY_MB=2048  # Fallback to 2GB if calculation fails
fi
if [ -z "$AIRLINE_DATA_PATH" ]; then
    echo "Error: airline-data directory not found."
    exit 1
fi

if [ -z "$AIRLINE_WEB_PATH" ]; then
    echo "Error: airline-web directory not found."
    exit 1
fi

# Function to show current system resources
show_system_resources() {
    local cpu_cores=$(get_system_cpu_cores)
    local memory_mb=$(get_system_memory_mb)
    echo "System Resources:"
    echo "  CPU Cores: $cpu_cores"
    echo "  Memory: ${memory_mb}MB"
    local cpu_percentage=$(echo "$MAX_CPU_RATIO * 100" | bc -l 2>/dev/null || echo "75")
    printf "  Configured Limits: Memory=%sMB, CPU=%s cores (%s%% of system), Max Processes=%s\n" "$MAX_MEMORY_MB" "$MAX_CPU_CORES" "$cpu_percentage" "$MAX_PROCESSES"
}

# Function to calculate CPU quota based on system cores and desired ratio
calculate_cpu_quota() {
    local desired_cores=$1
    local system_cores=$(get_system_cpu_cores)
    
    # Convert floating point to integer calculation (multiply by 1000000 for microseconds)
    local quota=$(echo "$desired_cores * 1000000" | bc 2>/dev/null || echo "1500000")
    
    # Ensure we don't exceed system capabilities
    local max_quota=$(echo "$system_cores * 1000000" | bc 2>/dev/null || echo "4000000")
    
    if [ -n "$quota" ] && [ "${quota%.*}" -gt 0 ] && [ "${quota%.*}" -le "${max_quota%.*}" ]; then
        echo "$quota"
    else
        # Fallback to reasonable default (1.5 cores or 75% of system cores, whichever is smaller)
        local fallback=$(echo "$system_cores * 750000" | bc 2>/dev/null || echo "1500000")
        echo "$fallback"
    fi
}

# Function to setup resource limits using cgroups v2
setup_resource_limits() {
    echo "Setting up resource limits for airline services..."
    
    # Show current system resources
    show_system_resources
    
    # Check if cgroup v2 is available
    if [ ! -d "/sys/fs/cgroup" ]; then
        echo "Warning: cgroups not available, resource limits will not be enforced"
        return 1
    fi
    
    # Create cgroup for airline services
    if [ -d "/sys/fs/cgroup/$CGROUP_NAME" ]; then
        echo "Resource limit group already exists"
    else
        sudo mkdir -p "/sys/fs/cgroup/$CGROUP_NAME"
        echo "Created resource limit group: $CGROUP_NAME"
    fi
    
    # Set memory limit (in bytes) with validation
    local system_memory_mb=$(get_system_memory_mb)
    local effective_memory_limit=$MAX_MEMORY_MB
    
    # Ensure we don't allocate more than 75% of system memory
    local max_reasonable_memory=$((system_memory_mb * 75 / 100))
    if [ $MAX_MEMORY_MB -gt $max_reasonable_memory ]; then
        effective_memory_limit=$max_reasonable_memory
        printf "Warning: Requested memory limit %sMB exceeds 75%% of system memory %sMB\n" "$MAX_MEMORY_MB" "$system_memory_mb"
        echo "Adjusting memory limit to ${effective_memory_limit}MB"
    fi
    
    local memory_bytes=$((effective_memory_limit * 1024 * 1024))
    echo $memory_bytes | sudo tee "/sys/fs/cgroup/$CGROUP_NAME/memory.max" 2>/dev/null || \
    echo $memory_bytes | sudo tee "/sys/fs/cgroup/$CGROUP_NAME/memory.limit_in_bytes" 2>/dev/null || \
    echo "Warning: Could not set memory limit"
    
    # Set CPU limit based on MAX_CPU_CORES configuration and system capabilities
    local cpu_quota=$(calculate_cpu_quota $MAX_CPU_CORES)
    local system_cores=$(get_system_cpu_cores)
    printf "CPU limit calculated: %s microseconds (%s cores requested, %s cores available)\n" "$cpu_quota" "$MAX_CPU_CORES" "$system_cores"
    echo $cpu_quota | sudo tee "/sys/fs/cgroup/$CGROUP_NAME/cpu.max" 2>/dev/null || \
    echo "Warning: Could not set CPU limit"
    
    # Set process limit
    echo $MAX_PROCESSES | sudo tee "/sys/fs/cgroup/$CGROUP_NAME/pids.max" 2>/dev/null || \
    echo "Warning: Could not set process limit"
    
    echo "Resource limits configured: ${MAX_MEMORY_MB}MB RAM, ${MAX_CPU_CORES} CPU cores, ${MAX_PROCESSES} processes max"
}

# Function to configure SSH keepalive and connection protection
configure_ssh_protection() {
    echo "Configuring SSH connection protection..."
    
    # Set SSH keepalive for current session
    export TMOUT=0
    export SSH_KEEPALIVE_INTERVAL=$SSH_KEEPALIVE_INTERVAL
    
    # Configure SSH client keepalive
    if [ -f "$HOME/.ssh/config" ]; then
        # Backup existing config
        cp "$HOME/.ssh/config" "$HOME/.ssh/config.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    # Add SSH keepalive settings
    mkdir -p "$HOME/.ssh"
    cat >> "$HOME/.ssh/config" << 'EOF'

# Airline project SSH connection protection
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
    ConnectTimeout 30
EOF
    
    # Set system-level SSH keepalive if we have sudo access
    if sudo -n true 2>/dev/null; then
        # Configure SSH daemon keepalive
        sudo tee -a /etc/ssh/sshd_config.d/airline-keepalive.conf << 'EOF' 2>/dev/null || true
# Airline project SSH connection protection
ClientAliveInterval 30
ClientAliveCountMax 6
TCPKeepAlive yes
EOF
        
        # Restart SSH daemon if configuration was successful
        if [ $? -eq 0 ]; then
            sudo systemctl restart sshd 2>/dev/null || sudo service ssh restart 2>/dev/null || true
        fi
    fi
    
    # Configure system resource limits for SSH sessions
    if [ -f "/etc/security/limits.conf" ]; then
        sudo tee -a /etc/security/limits.conf << EOF 2>/dev/null || true
# Airline project resource limits
* soft nproc 4096
* hard nproc 8192
* soft nofile 65536
* hard nofile 131072
EOF
    fi
    
    echo "SSH connection protection configured"
}

# Function to monitor system resources
monitor_resources() {
    local service_name=$1
    local pid_file=$2
    
    if [ ! -f "$pid_file" ]; then
        return 0
    fi
    
    local main_pid=$(cat "$pid_file")
    if ! kill -0 "$main_pid" 2>/dev/null; then
        return 0
    fi
    
    # Get all Java processes related to this service
    local java_pids=$(pgrep -P "$main_pid" java 2>/dev/null || echo "")
    local total_memory=0
    local total_cpu=0
    
    for pid in $main_pid $java_pids; do
        if [ -f "/proc/$pid/status" ]; then
            local mem_kb=$(grep VmRSS "/proc/$pid/status" 2>/dev/null | awk '{print $2}' || echo "0")
            total_memory=$((total_memory + mem_kb))
        fi
    done
    
    total_memory_mb=$((total_memory / 1024))
    
    # Check if memory usage exceeds limit
    if [ $total_memory_mb -gt $((MAX_MEMORY_MB + 512)) ]; then  # 512MB buffer
        echo "WARNING: $service_name memory usage (${total_memory_mb}MB) exceeds limit (${MAX_MEMORY_MB}MB)"
        return 1
    fi
    
    return 0
}

# Function to kill all processes in a cgroup
kill_cgroup_processes() {
    local cgroup_name=$1
    
    if [ -d "/sys/fs/cgroup/$cgroup_name" ]; then
        # Get all PIDs in the cgroup
        local pids=$(cat "/sys/fs/cgroup/$cgroup_name/cgroup.procs" 2>/dev/null || echo "")
        
        for pid in $pids; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "Killing process $pid in cgroup $cgroup_name"
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done
        
        # Wait a bit and force kill if necessary
        sleep 2
        for pid in $pids; do
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                echo "Force killing process $pid"
                kill -KILL "$pid" 2>/dev/null || true
            fi
        done
    fi
}

# Function to generate a random secret key
generate_secret_key() {
    head /dev/urandom | tr -dc A-Za-z0-9_ | head -c 64
}

# Function to update application.conf
update_application_conf() {
    echo "Updating airline-web/conf/application.conf..."
    LOCAL_IP=$(get_local_ip)
    SECRET_KEY=$(generate_secret_key)

    # Update secret keys
    sed -i "s/^play.crypto.secret = \".*\"/play.crypto.secret = \"$SECRET_KEY\"/g" "$AIRLINE_WEB_PATH/conf/application.conf"
    sed -i "s/^play.http.secret.key = \".*\"/play.http.secret.key = \"$SECRET_KEY\"/g" "$AIRLINE_WEB_PATH/conf/application.conf"

    # Update IP addresses
    sed -i "s/hostname = \"[0-9.]*\"/hostname = \"$LOCAL_IP\"/g" "$AIRLINE_WEB_PATH/conf/application.conf"
    sed -i "s/hostname = \"[0-9.]*\" #your private IP here/hostname = \"$LOCAL_IP\" #your private IP here/g" "$AIRLINE_WEB_PATH/conf/application.conf"

    # Configure database settings
    echo "Configuring database settings in application.conf..."
    sed -i 's/# db.default.driver=org.h2.Driver/db.default.driver=com.mysql.jdbc.Driver/' "$AIRLINE_WEB_PATH/conf/application.conf"
    # Update to match any existing db.default.url line
    sed -i 's|^db.default.url=.*|db.default.url="jdbc:mysql://127.0.0.1:3306/airline_v2_1?characterEncoding=UTF-8"|' "$AIRLINE_WEB_PATH/conf/application.conf"
    sed -i 's/# db.default.username=sa/db.default.username=sa/' "$AIRLINE_WEB_PATH/conf/application.conf"
    read -p "Enter database password (min 8 characters for MySQL 8.x): " db_password
    # MySQL user and database setup
    echo "Setting up MySQL user and database..."
    sudo mysql -u root -e "CREATE DATABASE IF NOT EXISTS airline_v2_1; CREATE USER IF NOT EXISTS 'sa'@'localhost' IDENTIFIED BY '$db_password'; GRANT ALL PRIVILEGES ON airline_v2_1.* TO 'sa'@'localhost'; FLUSH PRIVILEGES;"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to set up MySQL user or database. Please check MySQL root password or permissions."
        return 1
    fi
    echo "MySQL user 'sa' and database 'airline_v2_1' configured."
    sed -i "s/^db.default.password=.*$/db.default.password=$db_password/g" "$AIRLINE_WEB_PATH/conf/application.conf"
    sed -i 's/play.evolutions.enabled=false/play.evolutions.enabled=true/g' "$AIRLINE_WEB_PATH/conf/application.conf"
    sed -i 's/# play.evolutions.enabled=false/play.evolutions.enabled=true/' "$AIRLINE_WEB_PATH/conf/application.conf"

    # Update airline-data's application.conf
    AIRLINE_DATA_CONF="$AIRLINE_DATA_PATH/src/main/resources/application.conf"

    # Ensure mysqldb.host, mysqldb.user, mysqldb.password are on new lines
    sed -i 's/\([^[:space:]]\)mysqldb.host=/\1\nmysqldb.host=/' "$AIRLINE_DATA_CONF"
    sed -i 's/\([^[:space:]]\)mysqldb.user=/\1\nmysqldb.user=/' "$AIRLINE_DATA_CONF"
    sed -i 's/\([^[:space:]]\)mysqldb.password=/\1\nmysqldb.password=/' "$AIRLINE_DATA_CONF"

    # Set mysqldb.host to 127.0.0.1 (matches airline-web)
    if ! grep -q "mysqldb.host=" "$AIRLINE_DATA_CONF"; then
        echo -e "\nmysqldb.host=\"127.0.0.1\"" >> "$AIRLINE_DATA_CONF"
    else
        sed -i 's|mysqldb.host=.*|mysqldb.host=\"127.0.0.1\"|' "$AIRLINE_DATA_CONF"
    fi

    # Check and update mysqldb.user
    if ! grep -q "mysqldb.user=" "$AIRLINE_DATA_CONF"; then
        echo -e "\nmysqldb.user=\"sa\"" >> "$AIRLINE_DATA_CONF"
    else
        sed -i 's|mysqldb.user=.*|mysqldb.user=\"sa\"|' "$AIRLINE_DATA_CONF"
    fi

    # Check and update mysqldb.password
    if ! grep -q "mysqldb.password=" "$AIRLINE_DATA_CONF"; then
        echo -e "\nmysqldb.password=\"$db_password\"" >> "$AIRLINE_DATA_CONF"
    else
        sed -i 's|mysqldb.password=.*|mysqldb.password=\"'"$db_password"'\"|' "$AIRLINE_DATA_CONF"
    fi

    # Check and update mysqldb.dbParams
    if ! grep -q "mysqldb.dbParams=" "$AIRLINE_DATA_CONF"; then
        echo -e "\nmysqldb.dbParams=\"&allowPublicKeyRetrieval=true\"" >> "$AIRLINE_DATA_CONF"
    else
        sed -i 's|mysqldb.dbParams=.*|mysqldb.dbParams="\&allowPublicKeyRetrieval=true"|' "$AIRLINE_DATA_CONF"
    fi

    # --- Synchronize mysqldb settings in airline-web/conf/application.conf ---
    AIRLINE_WEB_CONF="$AIRLINE_WEB_PATH/conf/application.conf"

    # Ensure mysqldb.host in airline-web conf matches 127.0.0.1:3306
    if ! grep -q "mysqldb.host=" "$AIRLINE_WEB_CONF"; then
        echo -e "\nmysqldb.host=\"127.0.0.1:3306\"" >> "$AIRLINE_WEB_CONF"
    else
        sed -i 's|mysqldb.host=.*|mysqldb.host="127.0.0.1:3306"|' "$AIRLINE_WEB_CONF"
    fi

    # Ensure mysqldb.user in airline-web conf is sa
    if ! grep -q "mysqldb.user=" "$AIRLINE_WEB_CONF"; then
        echo -e "\nmysqldb.user=\"sa\"" >> "$AIRLINE_WEB_CONF"
    else
        sed -i 's|mysqldb.user=.*|mysqldb.user="sa"|' "$AIRLINE_WEB_CONF"
    fi

    # Ensure mysqldb.password in airline-web conf matches user input
    if ! grep -q "mysqldb.password=" "$AIRLINE_WEB_CONF"; then
        echo -e "\nmysqldb.password=\"$db_password\"" >> "$AIRLINE_WEB_CONF"
    else
        sed -i 's|mysqldb.password=.*|mysqldb.password="'$db_password'"|' "$AIRLINE_WEB_CONF"
    fi

    # Ensure mysqldb.dbParams in airline-web conf includes allowPublicKeyRetrieval
    if ! grep -q "mysqldb.dbParams=" "$AIRLINE_WEB_CONF"; then
        echo -e "\nmysqldb.dbParams=\"&allowPublicKeyRetrieval=true\"" >> "$AIRLINE_WEB_CONF"
    else
        sed -i 's|mysqldb.dbParams=.*|mysqldb.dbParams="\&allowPublicKeyRetrieval=true"|' "$AIRLINE_WEB_CONF"
    fi

    # Enable/Disable banner
    read -p "Do you want to enable the banner? (y/n): " banner_choice
    if [[ "$banner_choice" == "y" || "$banner_choice" == "Y" ]]; then
        sed -i "s/bannerEnabled = false/bannerEnabled = true/g" "$AIRLINE_WEB_PATH/conf/application.conf"
        echo "Banner enabled."
    else
        sed -i "s/bannerEnabled = true/bannerEnabled = false/g" "$AIRLINE_WEB_PATH/conf/application.conf"
        echo "Banner disabled."
    fi

    # Configure Google API keys
    read -p "Do you want to set Google API keys? (y/n): " google_api_choice
    if [[ "$google_api_choice" == "y" || "$google_api_choice" == "Y" ]]; then
        read -p "Enter google.mapKey: " google_map_key
        read -p "Enter google.apiKey: " google_api_key
        sed -i "s/^google.mapKey=\".*\"/google.mapKey=\"$google_map_key\"/g" "$AIRLINE_WEB_PATH/conf/application.conf"
        sed -i "s/^google.apiKey=\".*\"/google.apiKey=\"$google_api_key\"/g" "$AIRLINE_WEB_PATH/conf/application.conf"
        echo "Google API keys updated."
    else
        echo "Google API keys not set."
    fi

    echo "application.conf updated."
}

# Function to initialize the database
initialize_database() {
    echo "Initializing database..."
    LOG_FILE="$AIRLINE_DATA_PATH/init_database.log"
    echo "Running MainInit in airline-data. Output will be logged to $LOG_FILE"
    if (cd "$AIRLINE_DATA_PATH" && sbt -mem 2048 "runMain com.patson.init.MainInit" > "$LOG_FILE" 2>&1); then
        echo "Database initialization complete. Check $LOG_FILE for details."
        read -p "Press Enter to return to the menu..."
    else
        echo "Database initialization failed. Check $LOG_FILE for errors."
        read -p "Press Enter to return to the menu..."
    fi
}

# Function to start services with resource limits
start_services() {
    echo "Starting airline-data simulation and airline-web server with resource limits..."
    
    # Ensure Elasticsearch is running
    if systemctl is-active --quiet elasticsearch; then
        echo "Elasticsearch is already running."
    else
        echo "Elasticsearch is not running. Attempting to start..."
        sudo systemctl start elasticsearch
        sleep 5
        if systemctl is-active --quiet elasticsearch; then
            echo "Elasticsearch started successfully."
        else
            echo "Failed to start Elasticsearch. Please check logs."
        fi
    fi

    # Setup resource limits first
    setup_resource_limits
    configure_ssh_protection
    
    # Create separate cgroups for each service
    local data_cgroup="${CGROUP_NAME}_data"
    local web_cgroup="${CGROUP_NAME}_web"
    
    # ----- airline-data simulation -----
    if [ -f "$AIRLINE_DATA_PATH/simulation.pid" ] && kill -0 "$(cat \"$AIRLINE_DATA_PATH/simulation.pid\")" 2>/dev/null; then
        echo "Airline-data simulation already running with PID $(cat \"$AIRLINE_DATA_PATH/simulation.pid\")"
    else
        echo "Launching airline-data MainSimulation with resource limits (logs: airline-data/simulation.log) ..."
        
        # Create cgroup for data service with proper permissions
        sudo cgcreate -a kali:kali -t kali:kali -g memory,cpu,pids:$data_cgroup 2>/dev/null || true
        sudo chown -R kali:kali /sys/fs/cgroup/$data_cgroup 2>/dev/null || true
        
        # Set resource limits for data service
        local memory_bytes=$((MAX_MEMORY_MB * 1024 * 1024))
        echo $memory_bytes | sudo tee "/sys/fs/cgroup/$data_cgroup/memory.max" 2>/dev/null || true
        local cpu_quota=$(echo "$MAX_CPU_CORES * 100000" | bc -l 2>/dev/null || echo "300000")
        echo $cpu_quota | sudo tee "/sys/fs/cgroup/$data_cgroup/cpu.max" 2>/dev/null || true
        echo $MAX_PROCESSES | sudo tee "/sys/fs/cgroup/$data_cgroup/pids.max" 2>/dev/null || true
        
        # Start with resource limits and monitoring
        (
          cd "$AIRLINE_DATA_PATH" && \
          # Force fallback to JVM memory limits only, skipping cgexec due to cgroup v2 incompatibility
          bash -c "exec sbt -mem ${MAX_MEMORY_MB} -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx${MAX_MEMORY_MB}m 'runMain com.patson.MainSimulation' > '$AIRLINE_DATA_PATH/simulation.log' 2>&1" &
          echo $! > "$AIRLINE_DATA_PATH/simulation.pid"
        )
        
        main_pid=$(cat "$AIRLINE_DATA_PATH/simulation.pid")
        
        echo "Airline-data simulation started with PID $main_pid (limited to ${MAX_MEMORY_MB}MB RAM, ${MAX_CPU_CORES} CPU cores)"
        
        # Start resource monitoring in background
        (
            while kill -0 "$main_pid" 2>/dev/null; do
                if ! monitor_resources "airline-data" "$AIRLINE_DATA_PATH/simulation.pid"; then
                    echo "Resource limit exceeded for airline-data, restarting service..."
                    # Kill and restart will be handled by main monitoring loop
                    break
                fi
                sleep 60
            done
        ) &
    fi

    # ----- airline-web server -----
    if [ -f "$AIRLINE_WEB_PATH/web.pid" ] && kill -0 "$(cat \"$AIRLINE_WEB_PATH/web.pid\")" 2>/dev/null; then
        echo "Airline-web server already running with PID $(cat \"$AIRLINE_WEB_PATH/web.pid\")"
    else
        echo "Launching airline-web server with resource limits (logs: airline-web/web.log) ..."
        
        # Skip cgroup creation for web service due to v2 incompatibility
        
        # Start with JVM memory limits only, binding to all IPv4 interfaces
        (
          cd "$AIRLINE_WEB_PATH" && \
          bash -c "exec sbt -mem ${MAX_MEMORY_MB} -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx${MAX_MEMORY_MB}m 'run -Dhttp.address=0.0.0.0' > '$AIRLINE_WEB_PATH/web.log' 2>&1" &
          echo $! > "$AIRLINE_WEB_PATH/web.pid"
        )
        
        main_pid=$(cat "$AIRLINE_WEB_PATH/web.pid")
        
        echo "Airline-web server started with PID $main_pid (limited to ${MAX_MEMORY_MB}MB RAM, ${MAX_CPU_CORES} CPU cores)"
        
        # Start resource monitoring in background
        (
            while kill -0 "$main_pid" 2>/dev/null; do
                if ! monitor_resources "airline-web" "$AIRLINE_WEB_PATH/web.pid"; then
                    echo "Resource limit exceeded for airline-web, restarting service..."
                    # Kill and restart will be handled by main monitoring loop
                    break
                fi
                sleep 60
            done
        ) &
    fi

    echo "Services started with resource limits. You can access the web application at http://$(get_local_ip):9000"
    echo "Resource monitoring is active. Services will be restarted if they exceed memory/CPU limits."
}

# Function to stop services
stop_services() {
    echo "Stopping airline-data simulation and airline-web server..."

    # Kill all processes in cgroups first
    kill_cgroup_processes "${CGROUP_NAME}_data"
    kill_cgroup_processes "${CGROUP_NAME}_web"
    kill_cgroup_processes "$CGROUP_NAME"

    for pidfile in "$AIRLINE_DATA_PATH/simulation.pid" "$AIRLINE_WEB_PATH/web.pid"; do
        if [ -f "$pidfile" ]; then
            pid=$(cat "$pidfile")
            if kill -0 "$pid" 2>/dev/null; then
                echo "Stopping process $pid (from $(basename "$pidfile"))"
                # Kill all child processes
                sudo pkill -P "$pid" 2>/dev/null || true
                sudo kill -TERM "$pid" 2>/dev/null
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    echo "Force killing process $pid and children"
                    sudo pkill -KILL -P "$pid" 2>/dev/null || true
                    sudo kill -KILL "$pid" 2>/dev/null
                fi
            fi
            rm -f "$pidfile"
        fi
    done

    # Additional cleanup: Kill any processes still listening on port 9000
    echo "Checking for and killing processes on port 9000..."
    if command -v fuser >/dev/null 2>&1; then
        sudo fuser -k 9000/tcp 2>/dev/null || true
    elif command -v lsof >/dev/null 2>&1; then
        sudo lsof -ti:9000 | xargs sudo kill -9 2>/dev/null || true
    fi

    # Clean up monitoring processes
    sudo pkill -f "monitor_resources.*airline" 2>/dev/null || true

    # Verify port 9000 is free
    if netstat -tuln | grep -q ":9000 "; then
        echo "Warning: Port 9000 still in use after stop attempt"
    else
        echo "Port 9000 successfully freed"
    fi

    echo "Services stopped and resource limits cleaned up."
}

# Function to monitor and auto-restart services if needed
monitor_services() {
    echo "Monitoring airline services for resource usage and health..."
    
    local restart_count=0
    local max_restarts=3
    
    while true; do
        local needs_restart=false
        
        # Check airline-data service
        if [ -f "$AIRLINE_DATA_PATH/simulation.pid" ]; then
            local data_pid=$(cat "$AIRLINE_DATA_PATH/simulation.pid")
            if ! kill -0 "$data_pid" 2>/dev/null; then
                echo "Airline-data simulation is not running, will restart..."
                needs_restart=true
            elif ! monitor_resources "airline-data" "$AIRLINE_DATA_PATH/simulation.pid"; then
                echo "Airline-data simulation exceeded resource limits, will restart..."
                needs_restart=true
            fi
        else
            echo "Airline-data simulation PID file missing, will restart..."
            needs_restart=true
        fi
        
        # Check airline-web service
        if [ -f "$AIRLINE_WEB_PATH/web.pid" ]; then
            local web_pid=$(cat "$AIRLINE_WEB_PATH/web.pid")
            if ! kill -0 "$web_pid" 2>/dev/null; then
                echo "Airline-web server is not running, will restart..."
                needs_restart=true
            elif ! monitor_resources "airline-web" "$AIRLINE_WEB_PATH/web.pid"; then
                echo "Airline-web server exceeded resource limits, will restart..."
                needs_restart=true
            fi
        else
            echo "Airline-web server PID file missing, will restart..."
            needs_restart=true
        fi
        
        if [ "$needs_restart" = true ]; then
            restart_count=$((restart_count + 1))
            if [ $restart_count -le $max_restarts ]; then
                echo "Restarting services (attempt $restart_count/$max_restarts)..."
                stop_services
                sleep 5
                start_services
            else
                echo "Maximum restart attempts ($max_restarts) reached. Manual intervention required."
                break
            fi
        else
            restart_count=0  # Reset counter if services are healthy
        fi
        
        sleep 120  # Check every 2 minutes
    done
}

# Function to upgrade MySQL (placeholder for now)
upgrade_mysql() {
    echo "MySQL upgrade is a complex process and requires manual intervention."
    echo "Please refer to the MySQL official documentation for upgrading from 5.x to 8.x."
    echo "You might need to backup your data, uninstall 5.x, install 8.x, and then restore/migrate data."
    echo "Note: MySQL 8.x has stricter password policies. Ensure your MySQL user 'sa' has a strong password that meets the requirements, or adjust the password policy if necessary."
}

show_menu() {
    echo "
Airline Project Management Menu"
    echo "-----------------------------"
    echo "1. Update application.conf"
    echo "2. Initialize Database"
    echo "3. Start Services (with resource limits & SSH protection)"
    echo "4. Stop Services"
    echo "5. Status of Services (with resource usage)"
    echo "6. Configure SSH Protection"
    echo "7. Setup Resource Limits"
    echo "8. Monitor Services (auto-restart mode)"
    echo "9. Upgrade MySQL (Manual process)"
    echo "10. Exit"
    echo "-----------------------------"
}

# Handle command-line arguments
if [ $# -gt 0 ]; then
    case "$1" in
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        status)
            status_services
            ;;
        restart)
            stop_services
            sleep 5
            start_services
            ;;
        monitor)
            monitor_services
            ;;
        *)
            echo "Usage: $0 {start|stop|status|restart|monitor}"
            echo "For interactive mode, run without arguments."
            exit 1
            ;;
    esac
    exit 0
fi

while true; do
    show_menu
    read -p "Enter your choice [1-10]: " choice
    case $choice in
        1) update_application_conf ;;
        2) initialize_database ;;
        3) start_services ;;
        4) stop_services ;;
        5) status_services ;;
        6) configure_ssh_protection ;;
        7) setup_resource_limits ;;
        8) monitor_services ;;
        9) upgrade_mysql ;;
        10) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please enter a number between 1 and 10." ;;
    esac
    echo ""
done