#!/bin/bash
set -e

# Function to log only errors
log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >&2
}

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

# Initialize MariaDB data directory if needed
if [ ! -d "/var/lib/mysql/mysql" ]; then
    log_info "Initializing MariaDB data directory..."
    mysql_install_db --user=mysql --datadir=/var/lib/mysql > /dev/null 2>&1 || {
        log_error "Failed to initialize MariaDB"
        exit 1
    }
fi

# Start MariaDB temporarily to ensure database exists
log_info "Starting MariaDB temporarily..."
mysqld_safe --user=mysql --datadir=/var/lib/mysql --socket=/var/run/mysqld/mysqld.sock --pid-file=/var/run/mysqld/mysqld.pid &
MARIADB_PID=$!

# Wait for MariaDB to be ready
for i in {1..30}; do
    if mysqladmin ping --socket=/var/run/mysqld/mysqld.sock > /dev/null 2>&1; then
        log_info "MariaDB is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        log_error "MariaDB failed to start within 30 seconds"
        exit 1
    fi
    sleep 1
done

# Ensure database and user exist
mysql --socket=/var/run/mysqld/mysqld.sock -e "CREATE DATABASE IF NOT EXISTS airline_v2_1 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" > /dev/null 2>&1
mysql --socket=/var/run/mysqld/mysqld.sock -e "CREATE USER IF NOT EXISTS 'sa'@'localhost' IDENTIFIED BY 'admin';" > /dev/null 2>&1
mysql --socket=/var/run/mysqld/mysqld.sock -e "GRANT ALL PRIVILEGES ON airline_v2_1.* TO 'sa'@'localhost';" > /dev/null 2>&1
mysql --socket=/var/run/mysqld/mysqld.sock -e "FLUSH PRIVILEGES;" > /dev/null 2>&1

# Stop temporary MariaDB
kill $MARIADB_PID
wait $MARIADB_PID 2>/dev/null || true

# Create log directories
mkdir -p /app/logs /var/log/supervisor

# Set proper permissions
chown -R mysql:mysql /var/lib/mysql
chown -R mysql:mysql /var/run/mysqld
chmod 755 /var/run/mysqld

log_info "Starting Airline Club services via supervisor..."

# Start supervisor to manage all services
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf