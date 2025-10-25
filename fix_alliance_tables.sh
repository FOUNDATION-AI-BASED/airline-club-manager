#!/bin/bash

# Script to check and create missing alliance tables
# This prevents simulation failures due to missing alliance-related tables

echo "Checking for missing alliance tables..."

# MySQL connection parameters
DB_USER="root"
DB_NAME="airline_v2_1"

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

# Function to create alliance_mission tables
create_alliance_mission_tables() {
    echo "Creating missing alliance mission tables..."
    
    sudo mysql -u $DB_USER -e "USE $DB_NAME;
    
    CREATE TABLE IF NOT EXISTS alliance_mission (
      id INTEGER PRIMARY KEY AUTO_INCREMENT,
      start_cycle INTEGER,
      mission_type VARCHAR(256),
      duration INTEGER,
      alliance INTEGER,
      status VARCHAR(256),
      FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_mission_property (
      mission INTEGER,
      property VARCHAR(256),
      value BIGINT,
      PRIMARY KEY (mission, property),
      FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_mission_property_history (
      mission INTEGER,
      property VARCHAR(256),
      cycle INT,
      value BIGINT,
      PRIMARY KEY (mission, property, cycle),
      FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_mission_reward (
      id INTEGER PRIMARY KEY AUTO_INCREMENT,
      airline INTEGER,
      mission INTEGER,
      reward_type VARCHAR(256),
      available TINYINT(1),
      claimed TINYINT(1),
      FOREIGN KEY(mission) REFERENCES alliance_mission(id) ON DELETE CASCADE ON UPDATE CASCADE,
      FOREIGN KEY(airline) REFERENCES airline(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_mission_reward_property (
      reward INTEGER,
      property VARCHAR(256),
      value BIGINT,
      PRIMARY KEY (reward, property),
      FOREIGN KEY(reward) REFERENCES alliance_mission_reward(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_mission_stats (
      alliance INTEGER,
      cycle INTEGER,
      property VARCHAR(256),
      value BIGINT,
      PRIMARY KEY (alliance, cycle, property),
      FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE
    );
    
    CREATE TABLE IF NOT EXISTS alliance_stats (
      alliance INTEGER,
      cycle INTEGER,
      property VARCHAR(256),
      value BIGINT,
      PRIMARY KEY (alliance, cycle, property),
      FOREIGN KEY(alliance) REFERENCES alliance(id) ON DELETE CASCADE ON UPDATE CASCADE
    );"
    
    echo "Alliance mission tables created successfully!"
}

# Check for missing tables
MISSING_TABLES=()

if ! table_exists "alliance_stats"; then
    MISSING_TABLES+=("alliance_stats")
fi

if ! table_exists "alliance_mission"; then
    MISSING_TABLES+=("alliance_mission")
fi

if ! table_exists "alliance_mission_property"; then
    MISSING_TABLES+=("alliance_mission_property")
fi

if ! table_exists "alliance_mission_property_history"; then
    MISSING_TABLES+=("alliance_mission_property_history")
fi

if ! table_exists "alliance_mission_reward"; then
    MISSING_TABLES+=("alliance_mission_reward")
fi

if ! table_exists "alliance_mission_reward_property"; then
    MISSING_TABLES+=("alliance_mission_reward_property")
fi

if ! table_exists "alliance_mission_stats"; then
    MISSING_TABLES+=("alliance_mission_stats")
fi

# Report findings
if [ ${#MISSING_TABLES[@]} -eq 0 ]; then
    echo "✓ All alliance tables exist! No action needed."
else
    echo "✗ Missing tables: ${MISSING_TABLES[*]}"
    create_alliance_mission_tables
    
    # Verify creation
    echo "Verifying table creation..."
    for table in "${MISSING_TABLES[@]}"; do
        if table_exists "$table"; then
            echo "✓ $table created successfully"
        else
            echo "✗ Failed to create $table"
        fi
    done
fi

echo "Alliance table check complete!"