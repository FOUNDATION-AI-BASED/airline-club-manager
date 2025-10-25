#!/bin/bash

echo "Checking for required dependencies..."

get_version() {
    local PACKAGE_NAME=$1
    local VERSION_COMMAND=$2
    local VERSION_OUTPUT="N/A"

    if [ -n "$VERSION_COMMAND" ]; then
        # Special handling for java -version which outputs to stderr
        if [[ "$VERSION_COMMAND" == *"java -version"* ]]; then
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | grep version | awk '{print $3}' | sed 's/"//g' | head -n 1)
        elif [[ "$VERSION_COMMAND" == *"sbt --version"* ]]; then
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | grep "sbt runner version" | awk '{print $4}')
        elif [[ "$VERSION_COMMAND" == *"node -v"* ]]; then
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | head -n 1)
        elif [[ "$VERSION_COMMAND" == *"npm -v"* ]]; then
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | head -n 1)
        elif [[ "$VERSION_COMMAND" == *"curl -s http://localhost:9200/"* ]]; then
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | grep "number" | awk -F'"' '{print $4}')
        elif [[ "$VERSION_COMMAND" == *"mysql --version"* ]]; then
            VERSION_OUTPUT=$(mysqld --version 2>&1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        else
            VERSION_OUTPUT=$($VERSION_COMMAND 2>&1 | head -n 1)
        fi
    fi
    echo "$VERSION_OUTPUT"
}

# Function to check and install a package
check_and_install() {
    PACKAGE_NAME=$1
    INSTALL_COMMAND=$2
    VERSION_COMMAND=$3 # Command to get version, e.g., "mysql --version" or "sbt --version"
    INSTALL_TYPE=$4 # "apt" or "custom_sbt" for sbt

    if ( [ "$PACKAGE_NAME" == "mysql" ] && systemctl is-active --quiet mysql ) || ( command -v "$PACKAGE_NAME" &> /dev/null && [ "$PACKAGE_NAME" != "mysql" ] ) || ( [ "$PACKAGE_NAME" == "elasticsearch" ] && systemctl is-active --quiet elasticsearch ); then
        echo "$PACKAGE_NAME is already installed."
        CURRENT_VERSION=$(get_version "$PACKAGE_NAME" "$VERSION_COMMAND")
        echo "Version: $CURRENT_VERSION"
        INSTALLED_PACKAGES+=("$PACKAGE_NAME ($CURRENT_VERSION)")
    else
        echo "$PACKAGE_NAME is not installed. Installing now..."
        if [ "$INSTALL_TYPE" == "apt" ]; then
            sudo apt update
            sudo apt install -y "$INSTALL_COMMAND"
            if [ "$PACKAGE_NAME" == "mysql" ]; then
                sudo systemctl enable mysql
                sudo systemctl start mysql
            fi
        elif [ "$INSTALL_TYPE" == "custom_sbt" ]; then
            echo "Attempting custom installation for SBT..."
            echo "deb https://repo.scala-sbt.org/scalasbt/debian all main" | sudo tee /etc/apt/sources.list.d/sbt.list
            sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 2EE0EA64E40A89B84AD219C8C8E7BA01E42FF3ED
            sudo apt update
            sudo apt install -y sbt
            hash -r
        elif [ "$INSTALL_TYPE" == "custom_node" ]; then
            if command -v node &> /dev/null && command -v npm &> /dev/null; then
                VERSION_NODE=$(get_version "node" "node -v")
                VERSION_NPM=$(get_version "npm" "npm -v")
                echo "Node.js (version $VERSION_NODE) and npm (version $VERSION_NPM) are already installed."
                INSTALLED_PACKAGES+=("Node.js ($VERSION_NODE)")
                INSTALLED_PACKAGES+=("npm ($VERSION_NPM)")
                return 0
            else
                echo "Node.js and npm not found. Installing Node.js and npm..."
                # Install Node.js using nvm (Node Version Manager)
                curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash
                export NVM_DIR="$HOME/.nvm"
                [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
                [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
                nvm install node
                nvm use node
                if command -v node &> /dev/null && command -v npm &> /dev/null; then
                    VERSION_NODE=$(get_version "node" "node -v")
                    VERSION_NPM=$(get_version "npm" "npm -v")
                    echo "Node.js (version $VERSION_NODE) and npm (version $VERSION_NPM) installed successfully."
                    INSTALLED_PACKAGES+=("Node.js ($VERSION_NODE)")
                    INSTALLED_PACKAGES+=("npm ($VERSION_NPM)")
                    return 0
                else
                    echo "Failed to install Node.js and npm."
                    return 1
                fi
            fi
        elif [ "$INSTALL_TYPE" == "custom_elasticsearch" ]; then
            if systemctl is-active --quiet elasticsearch; then
                echo "Elasticsearch is already running."
                CURRENT_VERSION=$(get_version "elasticsearch" "curl -s http://localhost:9200/ | grep \"number\"")
                echo "Version: $CURRENT_VERSION"
                INSTALLED_PACKAGES+=("Elasticsearch ($CURRENT_VERSION)")
                return 0
            else
                echo "Installing Elasticsearch 7.x..."
                # Import the Elasticsearch GPG key
                wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
                # Add the Elasticsearch repository
                echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list
                # Update apt package lists
                sudo apt-get update
                # Install Elasticsearch
                sudo apt-get install -y elasticsearch
                # Enable and start Elasticsearch
                sudo systemctl daemon-reload
                sudo systemctl enable elasticsearch
                sudo systemctl start elasticsearch
                echo "Elasticsearch 7.x installed and started."
            fi
        else
            echo "Unknown installation type for $PACKAGE_NAME."
            FAILED_PACKAGES+=("$PACKAGE_NAME")
            return
        fi

        if [ $? -eq 0 ]; then
            echo "$PACKAGE_NAME installed successfully."
            CURRENT_VERSION=$(get_version "$PACKAGE_NAME" "$VERSION_COMMAND")
            echo "Version: $CURRENT_VERSION"
            INSTALLED_PACKAGES+=("$PACKAGE_NAME ($CURRENT_VERSION)")
        else
            echo "Failed to install $PACKAGE_NAME."
            FAILED_PACKAGES+=("$PACKAGE_NAME")
        fi
    fi
}

INSTALLED_PACKAGES=()
FAILED_PACKAGES=()

# Check for MySQL (using MariaDB as a common replacement on Debian-based systems)
check_and_install "mysql" "mysql-server-8.0" "mysql --version" "apt"

# Check for SBT
check_and_install "sbt" "sbt" "sbt --version" "custom_sbt" # Use custom_sbt for its specific installation steps

# Check for Java Development Kit (JDK) 8+
check_and_install "java" "default-jdk" "java -version" "apt"

# Check for Node.js and npm
check_and_install "node" "nodejs" "node -v" "custom_node"
check_and_install "npm" "npm" "npm -v" "apt"



check_and_install "elasticsearch" "elasticsearch" "curl -s http://localhost:9200/ | grep \"number\"" "custom_elasticsearch"

echo ""
echo "--- Installation Summary ---"
if [ ${#INSTALLED_PACKAGES[@]} -eq 0 ] && [ ${#FAILED_PACKAGES[@]} -eq 0 ]; then
    echo "All required dependencies were already installed."
else
    if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
        echo "Successfully installed or already present:"
        for PACKAGE in "${INSTALLED_PACKAGES[@]}"; do
            echo "- $PACKAGE"
        done
    fi
    if [ ${#FAILED_PACKAGES[@]} -gt 0 ]; then
        echo "Failed to install: ${FAILED_PACKAGES[*]}"
    fi
fi