# Airline Club Auto Installer v1.1

IMPORTANT: On older or low-core-count hardware, use Low Resource mode or Tight mode to prevent SSH disconnects and improve stability. You can enable this from the installer menu (10) Resource Mode, or via CLI: `./airline-club-manager.sh resource-mode`. Low mode is automatic on constrained machines; Tight mode is optional for extra headroom.

An automated installation script for [Airline Club](https://github.com/patsonluk/airline) - an open-source airline management game. This installer simplifies the complex setup process and provides easy management of the application.

## Resource Modes (Performance Profiles)

- LOW Resource mode (auto-detected when RAM ≤ 4GB or CPU cores ≤ 2):
  - JVM limits: `-Xms256m -Xmx1024m -XX:MaxMetaspaceSize=256m -XX:+UseSerialGC -XX:CICompilerCount=2`
  - Process priority: `nice -n 10` and `ionice -c2 -n 7` applied to heavy background tasks (build, database init, simulation, web server)
  - Goal: reduce memory pressure and CPU/IO contention to avoid terminal/SSH drops and increase server stability

- TIGHT mode (manual toggle, menu option 10):
  - JVM limits: `-Xms256m -Xmx768m -XX:MaxMetaspaceSize=192m -XX:+UseSerialGC -XX:CICompilerCount=2`
  - Process priority: `nice -n 15` and `ionice -c2 -n 7`
  - Goal: extra cushion for very constrained systems; applies only to newly started heavy processes

How to enable:
- Interactive: open installer, choose “10) Resource Mode”, then “1) Enable Tight mode” or “2) Disable Tight mode”.
- CLI: `./airline-club-manager.sh resource-mode` and enter `1` to enable Tight mode.

Notes:
- Low mode is enabled automatically on constrained machines at startup.
- Tight mode does not change already-running services; it applies to subsequent starts.
- If you see Java errors like `CICompilerCount (1) must be at least 2` in logs, ensure the profile uses `CICompilerCount=2` (already fixed in this installer).
  - Logs to check: `/home/kali/airline-club/simulation.log` and `/home/kali/airline-club/webserver.log`

## 🚀 Features

- **One-click installation** with interactive configuration
- **Modular installation** with step selection menu to skip or start from specific phases
- **Custom step selection** to choose exactly which installation steps to execute
- **Progress saving** with resume/restart options for interrupted installations
- **Menu-driven interface** for easy management
- **Multi-OS support** (Ubuntu currently, more coming soon)
- **Automatic dependency management** (Java, MySQL, SBT, Elasticsearch)
- **MySQL 8 compatibility** with automatic authentication fixes
- **Service management** (start, stop, status monitoring)
- **Google Maps API integration**
- **Optional Elasticsearch** for flight search functionality
- **Banner functionality** support with Google Photos API
- **Clean uninstallation** with optional data removal
- **Non-root execution** (sudo only for package installation)

## 📋 Prerequisites

- Linux server (Ubuntu Server currently supported)
- Non-root user with sudo privileges
- Internet connection for downloading dependencies
- At least 2GB RAM and 10GB free disk space

## 🛠 Installation

1. **Download the installer:**
   ```bash
   wget https://raw.githubusercontent.com/your-repo/airline-club-installer/main/airline-club-manager.sh
   chmod +x airline-club-manager.sh
   ```

2. **Run the installer:**
   ```bash
   ./airline-club-manager.sh
   ```

3. **Follow the interactive prompts:**
   - Enter Google Maps API key (optional)
   - Choose server port (default: 9000)
   - Enable Elasticsearch for flight search (optional)
   - Enable banner functionality (optional)

## 🎮 Usage

### Interactive Menu
Run the script without arguments to access the interactive menu:
```bash
./airline-club-manager.sh
```

#### Step Selection Menu

When choosing installation, you'll be presented with flexible options:

1. **Full Installation** - Complete setup (all steps)
2. **Start from Dependencies** - Begin from dependency installation
3. **Start from MySQL Configuration** - Skip dependencies, start from MySQL setup
4. **Start from Elasticsearch** - Skip to Elasticsearch installation
5. **Start from Repository Setup** - Skip to Git repository cloning
6. **Start from Application Configuration** - Skip to app configuration
7. **Start from Build Process** - Skip to SBT build and publish
8. **Start from Database Initialization** - Skip to database initialization only
9. **Custom Step Selection** - Choose specific steps to execute

#### Real-Time System Status Detection

Each step in the menu shows its **actual completion status** by checking the real system state:
- ✓ = Completed (verified by checking installed components and running services)
- ✗ = Not completed (components not found or not properly configured)

The system performs these real-time checks:
1. **Dependencies** - Verifies Java, SBT, and MySQL are installed
2. **MySQL Configuration** - Checks if MySQL service is running and airline_club database exists
3. **Elasticsearch** - Verifies Elasticsearch is installed and running (or marked as skipped)
4. **Repository Setup** - Confirms airline-club directory structure exists
5. **Application Configuration** - Validates configuration files and database settings
6. **Build Process** - Checks for compiled artifacts and published libraries
7. **Database Initialization** - Verifies database contains initialized data (airport table)

This ensures the status indicators reflect the actual state of your system, not just installation progress files.

#### Custom Step Selection

The custom option allows you to select exactly which steps to run:
- Enter space-separated numbers (e.g., `1 3 5` for dependencies, elasticsearch, and configure)
- Enter `all` for complete installation
- Each step includes a description of what it does

This is particularly useful when:
- You already have some components installed (MySQL, Java, etc.)
- You want to reconfigure only specific parts
- You're troubleshooting a particular installation phase
- You've already run `sbt 'runMain com.patson.init.MainInit'` manually

### Installation Progress
The installer now supports **progress saving** to handle interrupted installations:
- If installation is interrupted (terminal timeout, connection loss, etc.)
- On restart, you'll be prompted to:
  - **Resume** from the last completed step
  - **Restart** installation completely
  - **Cancel** installation
- Configuration is automatically saved and restored

### Command Line Options
```bash
./airline-club-manager.sh [command]
```

Available commands:
- `install` - Full installation with interactive configuration
- `start` - Start Airline Club services
- `stop` - Stop all services
- `status` - Check service status
- `uninstall` - Remove Airline Club (with optional data cleanup)
- `cleanup` - Clean up installation files and caches
- `resource-mode` - Open Resource Mode submenu to toggle Tight mode
- `analyze` - Run Analyze & Repair (checks DB connectivity, schema, minimal data; auto-fixes MySQL 8 auth and initializes DB if needed)

### Service Management

**Start Services:**
```bash
./airline-club-manager.sh start
```

**Stop Services:**
```bash
./airline-club-manager.sh stop
```

**Check Status:**
```bash
./airline-club-manager.sh status
```

## 🌐 Access

After installation, Airline Club will be accessible at:
- **Local:** `http://localhost:9000` (or your chosen port)
- **Network:** `http://your-server-ip:9000`

The installer configures the application to bind to `0.0.0.0` for network access.

## ⚙️ Configuration

### Default Settings
- **Installation Directory:** `~/airline-club`
- **Database:** MySQL with `airline_v2` database
- **Database User:** `sa` with password `admin`
- **Server Port:** `9000`
- **Bind Address:** `0.0.0.0` (all interfaces)
- **MySQL Version:** Supports both MySQL 5.7 and 8.0 with automatic compatibility fixes

### Google Maps API
To use Google Maps functionality:
1. Get an API key from Google Cloud Console
2. Enable Maps JavaScript API
3. Set usage limits to avoid unexpected charges
4. Enter the key during installation or manually edit `airline-web/conf/application.conf`

### Banner Functionality
For banner functionality (advanced users):
1. Set up Google Photos API in Google Cloud Console
2. Download OAuth credentials JSON
3. Place in `airline-web/conf/google-oauth-credentials.json`
4. Follow OAuth flow during first run
5. Copy generated tokens to production server

## 🗂 File Structure

After installation:
```
~/airline-club/
├── airline-data/          # Backend simulation
├── airline-web/           # Frontend web application
├── simulation.log         # Background simulation logs
├── webserver.log         # Web server logs
├── simulation.pid        # Simulation process ID
└── webserver.pid         # Web server process ID
```

## 🐛 Troubleshooting

### Common Issues

**Java/SBT Errors (older hardware):**
- If you see `CICompilerCount (1) must be at least 2`, the JVM JIT thread count is too low.
  - Use Resource Mode to ensure profiles set `CICompilerCount=2`.
  - Check logs: `/home/kali/airline-club/simulation.log` and `/home/kali/airline-club/webserver.log`.
- “Could not create the Java Virtual Machine” indicates incompatible flags or low memory; try Tight mode.

**MySQL Connection Issues:**
- Check if MySQL service is running: `sudo systemctl status mysql`
- Verify database credentials in `airline-data/src/main/scala/com/patson/data/Constants.scala`
- Ensure UTF-8 configuration is applied
- **MySQL 8.0 Users:** The installer automatically configures `mysql_native_password` authentication
- **Database Name:** Ensure you're using `airline_v2` (not `airline_v2_1`)

**Port Already in Use:**
- Change the port during installation
- Check for conflicting services: `sudo netstat -tlnp | grep :9000`

**Java/SBT Issues:**
- Verify Java installation: `java -version`
- Check SBT installation: `sbt --version`
- Clear SBT cache: `rm -rf ~/.sbt ~/.ivy2`

**Service Won’t Start:**
- Check logs in `simulation.log` and `webserver.log`
- Ensure all dependencies are installed
- Verify database is initialized
- Use the installer “12) Analyze & Repair” menu or `./airline-club-manager.sh analyze` to automatically:
  - Check MySQL connectivity (with MySQL 8 auth auto-fix)
  - Verify critical tables (user, airplane_model, airport, airline, cycle)
  - Ensure minimal baseline data exists (>=1 airplane_model, >=100 airports)
  - Run blocking DB initialization (MainInit) if issues are found

### Log Files
- **Simulation:** `/home/kali/airline-club/simulation.log`
- **Web Server:** `/home/kali/airline-club/webserver.log`
- **MySQL:** `/var/log/mysql/error.log`

## 🗺 Roadmap

### Phase 1: Core Functionality ✅
- [x] Ubuntu Server support
- [x] Interactive installation
- [x] Service management
- [x] Google Maps API integration
- [x] Elasticsearch support
- [x] Banner functionality
- [x] Clean uninstallation
- [x] **Progress saving with resume/restart options**
- [x] **MySQL 8 compatibility fixes**
- [x] **Correct MainInit class targeting**

### Phase 2: Extended Features 🚧
- [ ] Option to add Money overwrite, change and remove
- [ ] Option to Add Delegates overwrite and remove
- [ ] Script Menu Point Status (shows status of all services: installed/running/error/not installed)
- [ ] Adding Support to remove users
- [ ] User management interface (add/edit/delete users)

### Phase 3: Advanced Features 📋
- [ ] Installation process with progress bar and percentage display
- [ ] Background installation with terminal status updates


### Phase 4: User Experience 🎯

- [ ] **Debian 10/11** support
- [ ] **CentOS/RHEL 7/8** support
- [ ] **AlmaLinux 8/9** support
- [ ] **Rocky Linux 8/9** support
- [ ] **openSUSE Leap** support
- [ ] **Fedora** support

### Phase 5: Enterprise Features 🏢
- [ ] **Docker containerization** support
- [ ] **Systemd service** integration
- [ ] **SSL/TLS** configuration
- [ ] **Reverse proxy** setup (Nginx/Apache)
- [ ] **Backup/restore** functionality
- [ ] **Update management** system

## 🤝 Contributing

Contributions are welcome! Here's how you can help:

1. **OS Support:** Add support for new Linux distributions
2. **Features:** Implement items from the roadmap
3. **Bug Fixes:** Report and fix issues
4. **Documentation:** Improve installation guides
5. **Testing:** Test on different environments

### Development Setup
1. Fork the repository
2. Create a feature branch
3. Test your changes on a clean system
4. Submit a pull request

## 📄 License

This installer script is provided as-is under the MIT License. The Airline Club game itself is subject to its own license terms.

## 🆘 Support

- **Issues:** Report bugs and feature requests on GitHub
- **Documentation:** Check the troubleshooting section
- **Community:** Join the Airline Club community forums
- **Original Project:** [Airline Club GitHub](https://github.com/patsonluk/airline)

## 📚 Additional Resources

- [Airline Club Live Demo](https://www.airline-club.com/)
- [Airline Club V2](https://v2.airline-club.com/)
- [Google Maps API Documentation](https://developers.google.com/maps/documentation)
- [Elasticsearch Installation Guide](https://www.elastic.co/guide/en/elasticsearch/reference/current/install-elasticsearch.html)
- [MySQL UTF-8 Configuration](https://stackoverflow.com/questions/10957238/incorrect-string-value-when-trying-to-insert-utf-8-into-mysql-via-jdbc)

## 📝 Changelog

### v1.0.0 (2025-10-13)
**Major Release - Production Ready**

#### 🎉 New Features
- **Step Selection Menu**: Choose which installation steps to execute with flexible options:
  - Full installation (all steps)
  - Start from any specific step (dependencies, MySQL, Elasticsearch, repository, configure, build, database)
  - Custom step selection (choose exactly which steps to run)
- **Real-Time System Status Detection**: Step completion status now reflects actual system state by checking installed components, running services, and configuration files rather than relying solely on progress files
- **Progress Saving System**: Installation can now be resumed if interrupted
  - Automatic detection of previous installation attempts
  - Option to resume from last completed step or restart completely
  - Configuration persistence across installation sessions
- **MySQL 8 Compatibility**: Full support for MySQL 8.0
  - Automatic `mysql_native_password` authentication configuration
  - UTF-8mb4 character set setup
  - Legacy JDBC driver compatibility fixes

#### 🔧 Bug Fixes
- **Fixed MainInit Class Path**: Corrected fully-qualified class name from `com.patson.MainInit` to `com.patson.init.MainInit`
- **Database Name Alignment**: Changed database name from `airline_v2_1` to `airline_v2` to match application expectations
- **MySQL Authentication**: Resolved `CachingSha2PasswordPlugin` authentication errors with MySQL 8

#### 🚀 Improvements
- Enhanced error handling and logging throughout installation process
- Better user feedback during long-running operations
- Improved script reliability and robustness
- Updated documentation with troubleshooting guides

#### 🛠 Technical Changes
- Modular installation step system for better maintainability
- Configuration file management for resume functionality
- Progress tracking with step-by-step execution
- Added step selection menus with validation and error handling
- Implemented custom step selection with user-friendly interface
- Enhanced MySQL configuration with version detection

---

**Note:** This is an unofficial installer for the Airline Club project. For official support and updates, please refer to the [original repository](https://github.com/patsonluk/airline).

# Trusted Hosts (Play Host Filter)

Play Framework protects against DNS rebinding and Host header attacks by only accepting requests from allowed hosts. If you see errors like:

- "400 Bad Request: Host not allowed: 192.168.50.77:9000"

you must add your server's IP or domain to the trusted hosts list.

Our installer provides a new menu option to manage this:

- Main Menu → 11) Trusted Hosts (Allow IPs/Domains)
  - Add host (IP or domain)
  - Remove host
  - Reset to defaults (localhost, 127.0.0.1, .*)
  - Apply now and restart web server

The script persists your choices and applies them to both:
- Source conf: ~/airline-club/airline-web/conf/application.conf
- Staged conf: ~/airline-club/airline-web/target/universal/stage/conf/application.conf

Notes:
- The installer auto-detects the machine’s IPs and adds them to the trusted list when starting services.
- You can also run the command directly: `./airline-club-manager.sh trusted-hosts`
- Use `.*` to allow all hosts, but it’s recommended to restrict to your domain/IPs in production.

Troubleshooting:
- After changes, restart services: `./airline-club-manager.sh stop && ./airline-club-manager.sh start`
- Verify with: `curl -I http://<your-ip>:9000/` and ensure status 200/302 instead of 400.

## Docker deployment (container-as-server)

This project includes a cross-platform Docker wrapper that ensures all installation and runtime happen inside a container, with interactive menu support.

Usage: ./docker-wrapper.sh <command> [options]
Commands:
  build                 Build Docker image
  start                 Start container (detached) with host project mounted
  stop                  Stop and remove container
  shell                 Open interactive shell in running container
  menu                  Run installer menu inside container
  install               Run full installation flow inside container
  analyze               Run analyze & repair inside container
  logs [file]           Tail logs from host project (default: all known logs)
  run <args...>         Pass-through to airline-club-manager.sh inside container

Env vars:
  PROJECT_DIR_HOST      Host path to airline-club (default: /home/kali/airline-club)
  IMAGE_NAME            Docker image name (default: airline-club-java8)
  CONTAINER_NAME        Container name (default: airline-club-runtime)

Quickstart:
- Build the image:
  - cd /home/kali/airline-club-2
  - ./docker-wrapper.sh build
- Start the container (server runs inside the container):
  - Linux: ./docker-wrapper.sh start
    - Uses host networking to reach MySQL on localhost:3306 and bind app ports directly
  - macOS: ./docker-wrapper.sh start
    - Docker Desktop does not support host networking; common ports 9000 and 7777 are published by default
    - To publish more ports (e.g., 3306, 8080), set EXTRA_PORTS before start:
      - export EXTRA_PORTS="-p 3306:3306 -p 8080:8080"
      - ./docker-wrapper.sh start
- Interactive installer menu (inside the container):
  - ./docker-wrapper.sh menu
- Analyze & repair (inside the container):
  - ./docker-wrapper.sh analyze
- Tail logs (from host-mounted files):
  - ./docker-wrapper.sh logs
  - ./docker-wrapper.sh logs datainit.log

Notes:
- If your project directory differs from /home/kali/airline-club, set:
  - export PROJECT_DIR_HOST=/path/to/airline-club
- For macOS, ensure you publish any ports you need to access via localhost with EXTRA_PORTS.
- All commands execute inside the running container; nothing is executed on the host outside Docker.

---

**Note:** This is an unofficial installer for the Airline Club project. For official support and updates, please refer to the [original repository](https://github.com/patsonluk/airline).

# Trusted Hosts (Play Host Filter)

Play Framework protects against DNS rebinding and Host header attacks by only accepting requests from allowed hosts. If you see errors like:

- "400 Bad Request: Host not allowed: 192.168.50.77:9000"

you must add your server's IP or domain to the trusted hosts list.

Our installer provides a new menu option to manage this:

- Main Menu → 11) Trusted Hosts (Allow IPs/Domains)
  - Add host (IP or domain)
  - Remove host
  - Reset to defaults (localhost, 127.0.0.1, .*)
  - Apply now and restart web server

The script persists your choices and applies them to both:
- Source conf: ~/airline-club/airline-web/conf/application.conf
- Staged conf: ~/airline-club/airline-web/target/universal/stage/conf/application.conf

Notes:
- The installer auto-detects the machine’s IPs and adds them to the trusted list when starting services.
- You can also run the command directly: `./airline-club-manager.sh trusted-hosts`
- Use `.*` to allow all hosts, but it’s recommended to restrict to your domain/IPs in production.

Troubleshooting:
- After changes, restart services: `./airline-club-manager.sh stop && ./airline-club-manager.sh start`
- Verify with: `curl -I http://<your-ip>:9000/` and ensure status 200/302 instead of 400.
