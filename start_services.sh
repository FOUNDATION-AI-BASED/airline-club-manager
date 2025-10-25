#!/bin/bash

# Comprehensive airline services startup script
# This script checks the database and starts all services

echo "🚀 Starting Airline Services..."
echo "Time: $(date)"

# Configuration
DB_USER="root"
DB_NAME="airline_v2_1"

# Step 1: Check and fix database
echo "📊 Step 1: Checking database integrity..."
if ./check_and_fix_db.sh; then
    echo "✅ Database check completed successfully"
else
    echo "❌ Database check failed"
    exit 1
fi

# Step 2: Check if services are already running
echo ""
echo "🔍 Step 2: Checking existing services..."

# Check for existing processes
WEB_PID=$(pgrep -f "airline-web" || echo "")
DATA_PID=$(pgrep -f "MainSimulation" || echo "")

if [ -n "$WEB_PID" ]; then
    echo "⚠️  Web service already running (PID: $WEB_PID)"
else
    echo "✓ Web service not running - will start"
fi

if [ -n "$DATA_PID" ]; then
    echo "⚠️  Data service already running (PID: $DATA_PID)"
else
    echo "✓ Data service not running - will start"
fi

# Step 3: Start services
echo ""
echo "🚀 Step 3: Starting services..."

# Start data service (simulation) if not running
if [ -z "$DATA_PID" ]; then
    echo "Starting airline-data service..."
    cd airline-data
    bash -c "exec sbt -mem 3072 -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx3072m 'runMain com.patson.MainSimulation' > 'simulation.log' 2>&1" &
    DATA_START_PID=$!
    cd ..
    echo "✓ Data service started (PID: $DATA_START_PID)"
else
    echo "✓ Data service already running"
fi

# Wait a bit for data service to initialize
sleep 5

# Start web service if not running
if [ -z "$WEB_PID" ]; then
    echo "Starting airline-web service..."
    cd airline-web
    bash -c "exec sbt -mem 3072 -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx3072m 'run' > 'web.log' 2>&1" &
    WEB_START_PID=$!
    cd ..
    echo "✓ Web service started (PID: $WEB_START_PID)"
else
    echo "✓ Web service already running"
fi

# Step 4: Wait for services to be ready
echo ""
echo "⏳ Step 4: Waiting for services to initialize..."
sleep 10

# Step 5: Test services
echo ""
echo "🧪 Step 5: Testing services..."

# Test web service
echo "Testing web service..."
for i in {1..10}; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 | grep -q "200\|302"; then
        echo "✅ Web service is responding!"
        WEB_OK=true
        break
    else
        echo "  Attempt $i/10 - waiting..."
        sleep 3
    fi
done

if [ "$WEB_OK" != true ]; then
    echo "⚠️  Web service may not be fully ready yet"
fi

# Test data service
echo "Testing data service..."
if tail -10 airline-data/simulation.log | grep -q "cycle\|simulation\|airport"; then
    echo "✅ Data service is processing"
else
    echo "⚠️  Check data service logs for status"
fi

# Final status
echo ""
echo "🎉 Startup complete!"
echo ""
echo "📋 Service Status:"
./check_status.sh

echo ""
echo "🌐 Web interface should be available at: http://localhost:9000"
echo "📊 Simulation logs: airline-data/simulation.log"
echo "🌐 Web service logs: airline-web/web.log"
echo "🔧 Database logs: /tmp/db_fix.log"
echo ""
echo "Use ./check_status.sh to monitor services"
echo "Use tail -f airline-data/simulation.log to watch simulation progress"