#!/bin/bash

# Simple status script for airline services
echo "=== Airline Services Status ==="
echo

echo "Checking for running Java/SBT processes..."
ps aux | grep -E "(sbt|java)" | grep -v grep | grep -v elasticsearch | while read line; do
    if echo "$line" | grep -q "MainSimulation"; then
        echo "✓ airline-data (MainSimulation): $line"
    elif echo "$line" | grep -q "run$"; then
        echo "✓ airline-web (Play Framework): $line"
    fi
done

echo
echo "=== Service Logs ==="
echo "airline-data (last 5 lines):"
tail -5 airline-data/simulation.log 2>/dev/null || echo "No simulation.log found"

echo
echo "airline-web (last 5 lines):"
tail -5 airline-web/web.log 2>/dev/null || echo "No web.log found"

echo
echo "=== Network Status ==="
if netstat -tlnp 2>/dev/null | grep -q ":9000"; then
    echo "✓ Port 9000 is listening (airline-web)"
else
    echo "✗ Port 9000 is not listening"
fi

echo
echo "=== Summary ==="
if ps aux | grep -E "(sbt|java)" | grep -v grep | grep -v elasticsearch | grep -q "MainSimulation"; then
    echo "✓ airline-data service is running"
else
    echo "✗ airline-data service is not running"
fi

if ps aux | grep -E "(sbt|java)" | grep -v grep | grep -v elasticsearch | grep -q "run$"; then
    echo "✓ airline-web service is running"
else
    echo "✗ airline-web service is not running"
fi