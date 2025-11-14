#!/bin/bash

# Test script to start services without cgroup limits
source airline_manager.sh

# Temporarily disable cgroup limits by setting them very high
export MAX_MEMORY_MB=3072
export MAX_PROCESSES=1000
export MAX_CPU_CORES=3.4

echo "Testing services with relaxed limits..."

# Start airline-data with JVM limits only
cd "$AIRLINE_DATA_PATH" && \
bash -c "exec sbt -mem ${MAX_MEMORY_MB} -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx${MAX_MEMORY_MB}m 'runMain com.patson.MainSimulation' > 'simulation.log' 2>&1" &
echo $! > "simulation.pid"

echo "Airline-data started with PID $(cat simulation.pid)"

sleep 2

# Start airline-web with JVM limits only
cd "$AIRLINE_WEB_PATH" && \
bash -c "exec sbt -mem ${MAX_MEMORY_MB} -J-XX:+UseG1GC -J-XX:MaxGCPauseMillis=200 -J-XX:+ExitOnOutOfMemoryError -J-Xmx${MAX_MEMORY_MB}m 'run' > 'web.log' 2>&1" &
echo $! > "web.pid"

echo "Airline-web started with PID $(cat web.pid)"

sleep 5

# Check if they're running
if ps aux | grep -E "(sbt|java)" | grep -v grep | grep -v elasticsearch; then
    echo "Services appear to be running!"
else
    echo "Services failed to start. Check logs:"
    echo "airline-data/simulation.log:"
    tail -5 airline-data/simulation.log
    echo "airline-web/web.log:"
    tail -5 airline-web/web.log
fi