#!/bin/bash

# Complete airline services cleanup and restart script
# This script stops all services, cleans up, checks database, and restarts everything

echo "🔄 Complete Airline Services Restart"
echo "Time: $(date)"

# Step 1: Stop all services
echo ""
echo "🛑 Step 1: Stopping all services..."

echo "Stopping web service..."
pkill -f "airline-web" 2>/dev/null || true
sleep 2
pkill -9 -f "airline-web" 2>/dev/null || true

echo "Stopping data service..."
pkill -f "MainSimulation" 2>/dev/null || true
sleep 2
pkill -9 -f "MainSimulation" 2>/dev/null || true

echo "Cleaning up any remaining Java processes..."
pkill -f "sbt-launch" 2>/dev/null || true
sleep 1

# Step 2: Wait for ports to be released
echo ""
echo "⏳ Step 2: Waiting for ports to be released..."
sleep 3

# Step 3: Check database and create missing tables
echo ""
echo "📊 Step 3: Checking database integrity..."
./check_and_fix_db.sh

# Step 4: Start services in proper order
echo ""
echo "🚀 Step 4: Starting services..."

# Start data service first
echo "Starting airline-data service..."
cd airline-data
bash -c "exec sbt -mem 3072 -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx3072m 'runMain com.patson.MainSimulation' > 'simulation.log' 2>&1" &
DATA_PID=$!
cd ..
echo "✓ Data service started (PID: $DATA_PID)"

# Wait for data service to initialize
echo "Waiting for data service to initialize..."
sleep 15

# Start web service
echo "Starting airline-web service..."
cd airline-web
bash -c "exec sbt -mem 3072 -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx3072m 'run' > 'web.log' 2>&1" &
WEB_PID=$!
cd ..
echo "✓ Web service started (PID: $WEB_PID)"

# Step 5: Wait and test services
echo ""
echo "⏳ Step 5: Waiting for services to be ready..."
sleep 20

echo ""
echo "🧪 Step 6: Testing services..."

# Test web service
echo "Testing web service..."
WEB_OK=false
for i in {1..15}; do
    echo "  Test attempt $i/15..."
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:9000 2>/dev/null | grep -q "200\|302"; then
        echo "✅ Web service is responding!"
        WEB_OK=true
        break
    else
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
echo "🎉 Restart complete!"
echo ""
echo "📋 Final Status:"
./check_status.sh

echo ""
echo "🌐 Web interface: http://localhost:9000"
echo "📊 Simulation logs: airline-data/simulation.log"
echo "🌐 Web service logs: airline-web/web.log"
echo "🔧 Database logs: /tmp/db_fix.log"
echo ""
echo "💡 Quick commands:"
echo "  Monitor simulation: tail -f airline-data/simulation.log"
echo "  Monitor web service: tail -f airline-web/web.log"
echo "  Check status: ./check_status.sh"
echo "  Full restart: ./restart_services.sh"