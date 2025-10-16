# Airline Club Docker Solution

This Docker solution pre-builds all heavy operations (database creation, sbt compilation) on a powerful machine, then allows lightweight deployment on low-end servers.

## Overview

The solution consists of:
- **Dockerfile**: Ubuntu 22.04 based image with pre-built airline-data and initialized database
- **docker-compose.yml**: Orchestration for easy deployment
- **build-docker-image.sh**: Script to build the image on a powerful machine
- **airline-control.sh**: Lightweight control script for low-end servers
- **Supervisor configuration**: Manages MariaDB, web server, and simulation processes

## Building the Image (On Powerful Machine)

1. **Prerequisites**:
   ```bash
   # Install Docker and Docker Compose
   sudo apt update
   sudo apt install docker.io docker-compose
   sudo systemctl start docker
   sudo usermod -aG docker $USER
   # Log out and back in for group changes
   ```

2. **Build the image**:
   ```bash
   ./build-docker-image.sh
   ```
   
   This will:
   - Install all dependencies (OpenJDK, sbt, MariaDB)
   - Clone and compile airline-data (heavy sbt operations)
   - Initialize the database schema
   - Create a ready-to-run image

3. **Export the image for deployment**:
   ```bash
   docker save airline-club:v2.2 | gzip > airline-club-v2.2.tar.gz
   ```

## Deploying on Low-End Server

1. **Transfer and load the image**:
   ```bash
   # Copy airline-club-v2.2.tar.gz to your server
   gunzip -c airline-club-v2.2.tar.gz | docker load
   ```

2. **Copy control files**:
   ```bash
   # Copy these files to your server:
   # - airline-control.sh
   # - docker-compose.yml (optional)
   ```

3. **Start the services**:
   ```bash
   # Using the control script (recommended)
   ./airline-control.sh start
   
   # OR using docker-compose
   docker-compose up -d
   
   # OR using docker directly
   docker run -d --name airline-club-server -p 9000:9000 airline-club:v2.2
   ```

## Control Script Usage

The `airline-control.sh` script provides easy management:

```bash
# Start Airline Club
./airline-control.sh start

# Check status
./airline-control.sh status

# View logs
./airline-control.sh logs
./airline-control.sh logs 100        # Last 100 lines
./airline-control.sh logs 50 follow  # Follow logs

# Restart services
./airline-control.sh restart

# Stop services
./airline-control.sh stop

# Remove container
./airline-control.sh remove
```

## Accessing the Application

- **Web Interface**: http://localhost:9000
- **Database** (if needed): localhost:3306
  - Database: `airline_v2_1`
  - User: `sa`
  - Password: `admin`

## Architecture

### Container Services
The container runs three main services via Supervisor:

1. **MariaDB**: Database server with pre-initialized schema
2. **Airline Web**: Play Framework web application (port 9000)
3. **Airline Simulation**: Background simulation process

### Resource Configuration
- **Web Server**: 512MB-2GB heap, G1GC
- **Simulation**: 256MB-1.5GB heap, G1GC
- **Logging**: Error-level only during build, structured logs at runtime

### Volumes
- `/app/logs`: Application logs
- `/var/lib/mysql`: Database data (persistent)

## Troubleshooting

### Build Issues
```bash
# Check build logs
docker build -t airline-club:v2.2 . --no-cache

# If sbt compilation fails, increase Docker memory:
# Docker Desktop: Settings > Resources > Memory (8GB+)
```

### Runtime Issues
```bash
# Check container logs
./airline-control.sh logs 200

# Check individual service logs
docker exec airline-club-server supervisorctl status
docker exec airline-club-server tail -f /app/logs/web.log
docker exec airline-club-server tail -f /app/logs/simulation.log

# Restart specific service
docker exec airline-club-server supervisorctl restart airline-web
docker exec airline-club-server supervisorctl restart airline-simulation
```

### Performance Tuning
```bash
# For very low-end servers, reduce memory usage:
docker run -d --name airline-club-server \
  -p 9000:9000 \
  -e "SBT_OPTS=-Xms256m -Xmx1024m -XX:+UseG1GC" \
  airline-club:v2.2
```

### Database Issues
```bash
# Access database directly
docker exec -it airline-club-server mysql -u sa -padmin airline_v2_1

# Reset database (will lose data)
docker exec airline-club-server mysql -u root -e "DROP DATABASE airline_v2_1; CREATE DATABASE airline_v2_1 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
docker restart airline-club-server
```

## Advantages of This Solution

1. **Pre-built Heavy Operations**: Database initialization and sbt compilation done once
2. **Lightweight Deployment**: Low-end servers only run the pre-built services
3. **Single Container**: All services managed together with Supervisor
4. **Persistent Data**: Database and logs survive container restarts
5. **Easy Management**: Simple control script for common operations
6. **Resource Optimized**: Tuned JVM settings for different components
7. **Error-Only Logging**: Minimal log output during build and operation

## File Structure

```
airline-club-manager-test/
├── Dockerfile                 # Main container definition
├── docker-compose.yml         # Orchestration configuration
├── build-docker-image.sh      # Build script for powerful machines
├── airline-control.sh         # Control script for deployment
├── docker/
│   ├── supervisord.conf       # Service management configuration
│   └── start.sh              # Container startup script
├── airline/                   # Source code (copied into image)
└── README-Docker.md          # This documentation
```

## Version Information

- **Base Image**: Ubuntu 22.04
- **Java**: OpenJDK 11
- **Scala/sbt**: Latest stable
- **Database**: MariaDB 10.6+
- **Airline Club**: v2.2 branch
- **Process Manager**: Supervisor

This solution separates the heavy build process from lightweight runtime deployment, making it ideal for scenarios where you have access to powerful build machines but need to deploy on resource-constrained servers.