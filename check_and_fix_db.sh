#!/bin/bash

# Comprehensive database check and fix script
# This script checks for missing tables and creates them before starting services

echo "🔍 Checking airline database integrity..."

# Configuration
DB_USER="root"
DB_NAME="airline_v2_1"
LOG_FILE="/tmp/db_fix.log"

# Redirect output to log
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "Log file: $LOG_FILE"
echo "Date: $(date)"

# Function to test database connection
test_db_connection() {
    echo "Testing database connection..."
    if sudo mysql -u $DB_USER -e "SELECT 1;" >/dev/null 2>&1; then
        echo "✓ Database connection successful"
        return 0
    else
        echo "✗ Database connection failed"
        return 1
    fi
}

# Function to check if table exists
table_exists() {
    local table_name=$1
    local result=$(sudo mysql -u $DB_USER -e "USE $DB_NAME; SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name = '$table_name';" -B -N 2>/dev/null)
    if [ "$result" = "1" ]; then
        return 0
    else
        return 1
    fi
}

# Function to execute SQL with error handling
execute_sql() {
    local sql=$1
    local description=$2
    
    echo "  Creating: $description"
    if sudo mysql -u $DB_USER -e "USE $DB_NAME; $sql" 2>/dev/null; then
        echo "  ✓ Success"
        return 0
    else
        echo "  ✗ Failed"
        return 1
    fi
}

# Track missing tables
MISSING_TABLES=()
FIXED_TABLES=()
FAILED_TABLES=()

# Test database connection first
if ! test_db_connection; then
    echo "❌ Cannot proceed without database connection"
    exit 1
fi

echo "1. Checking alliance tables..."

# Check alliance mission tables
ALLIANCE_MISSION_TABLES=(
    "alliance_stats:CREATE TABLE alliance_stats (alliance INTEGER, cycle INTEGER, property VARCHAR(256), value BIGINT, PRIMARY KEY (alliance, cycle, property), FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission:CREATE TABLE alliance_mission (id INTEGER PRIMARY KEY AUTO_INCREMENT, start_cycle INTEGER, mission_type VARCHAR(256), duration INTEGER, alliance INTEGER, status VARCHAR(256), FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission_property:CREATE TABLE alliance_mission_property (mission INTEGER, property VARCHAR(256), value BIGINT, PRIMARY KEY (mission, property), FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission_property_history:CREATE TABLE alliance_mission_property_history (mission INTEGER, property VARCHAR(256), cycle INT, value BIGINT, PRIMARY KEY (mission, property, cycle), FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission_reward:CREATE TABLE alliance_mission_reward (id INTEGER PRIMARY KEY AUTO_INCREMENT, airline INTEGER, mission INTEGER, reward_type VARCHAR(256), available TINYINT(1), claimed TINYINT(1), FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE, FOREIGN KEY(airline) REFERENCES airline(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission_reward_property:CREATE TABLE alliance_mission_reward_property (reward INTEGER, property VARCHAR(256), value BIGINT, PRIMARY KEY (reward, property), FOREIGN KEY(reward) REFERENCES alliance_mission_reward(id) ON DELETE CASCADE ON UPDATE CASCADE)"
    "alliance_mission_stats:CREATE TABLE alliance_mission_stats (alliance INTEGER, cycle INTEGER, property VARCHAR(256), value BIGINT, PRIMARY KEY (alliance, cycle, property), FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE)"
)

for table_info in "${ALLIANCE_MISSION_TABLES[@]}"; do
    IFS=':' read -r table_name create_sql <<< "$table_info"
    
    if ! table_exists "$table_name"; then
        MISSING_TABLES+=("$table_name")
        echo "  Missing: $table_name"
        
        if execute_sql "$create_sql" "$table_name"; then
            FIXED_TABLES+=("$table_name")
        else
            FAILED_TABLES+=("$table_name")
        fi
    fi
done

echo "2. Checking other critical tables..."

# Add other critical table checks here as needed
# For example, you could check for:
# - passenger_history tables
# - link consumption tables  
# - airplane configuration tables

# Check for additional critical tables that might cause web service issues
CRITICAL_TABLES=(
    "airline:CREATE TABLE airline (id INTEGER PRIMARY KEY, name VARCHAR(256), symbol VARCHAR(256))"
    "airport:CREATE TABLE airport (id INTEGER PRIMARY KEY, iata VARCHAR(256), name VARCHAR(256))"
    "link:CREATE TABLE link (id INTEGER PRIMARY KEY, airline INTEGER, from_airport INTEGER, to_airport INTEGER)"
)

for table_info in "${CRITICAL_TABLES[@]}"; do
    IFS=':' read -r table_name create_sql <<< "$table_info"
    
    if ! table_exists "$table_name"; then
        echo "  ⚠️  Critical table missing: $table_name"
        echo "  This might cause service startup issues"
    fi
done

echo ""
echo "📊 Summary:"
echo "  Total missing tables found: ${#MISSING_TABLES[@]}"
echo "  Tables fixed: ${#FIXED_TABLES[@]}"
echo "  Tables failed: ${#FAILED_TABLES[@]}"

if [ ${#MISSING_TABLES[@]} -gt 0 ]; then
    echo "  Missing tables: ${MISSING_TABLES[*]}"
fi

if [ ${#FIXED_TABLES[@]} -gt 0 ]; then
    echo "  Fixed tables: ${FIXED_TABLES[*]}"
fi

if [ ${#FAILED_TABLES[@]} -gt 0 ]; then
    echo "  Failed tables: ${FAILED_TABLES[*]}"
    echo "❌ Some tables could not be created. Check the log above for details."
    exit 1
fi

if [ ${#MISSING_TABLES[@]} -eq 0 ]; then
    echo "✅ All tables exist! Database is ready."
else
    echo "✅ All missing tables have been created successfully!"
fi

echo ""
echo "🎯 Next steps:"
echo "  - If tables were created, restart the simulation to pick up the changes"
echo "  - Monitor the simulation log for any remaining errors"
echo "  - Consider adding this check to your startup scripts"

echo ""
echo "Check complete at: $(date)"

# Function to restart web service if needed
restart_web_service() {
    echo ""
    echo "🔄 Checking web service status..."
    
    # Test web service
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 >/dev/null 2>&1; then
        echo "✓ Web service is responding"
    else
        echo "⚠️  Web service not responding properly"
        echo "💡 Consider restarting the web service with:"
        echo "   pkill -f 'airline-web'"
        echo "   cd airline-web && bash -c \"exec sbt -mem 3072 -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx3072m 'run' > 'web.log' 2>&1\" &"
    fi
}

# Uncomment the next line to enable web service check
# restart_web_service