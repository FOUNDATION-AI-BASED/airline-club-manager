#!/bin/bash

CPU_LIMIT="75"
RAM_LIMIT="2G"
CGROUP_NAME="sbt_resource_limit"

install_tools() {
    echo "Installing necessary tools: cpulimit and cgroup-tools..."
    sudo apt update
    sudo apt install -y cpulimit cgroup-tools
    if [ $? -eq 0 ]; then
        echo "cpulimit and cgroup-tools installed successfully."
    else
        echo "Failed to install cpulimit and cgroup-tools."
    fi
}

uninstall_tools() {
    echo "Uninstalling cpulimit and cgroup-tools..."
    sudo apt remove -y cpulimit cgroup-tools
    sudo apt autoremove -y
    echo "Cleaning up cgroup configurations..."
    # Remove any lingering cgroups created by the script
    sudo cgdelete cpu,memory:/user.slice/$CGROUP_NAME >/dev/null 2>&1
    echo "cpulimit and cgroup-tools uninstalled and configurations cleaned."
}

apply_limits() {
    echo "Applying CPU ($CPU_LIMIT%) and RAM ($RAM_LIMIT) limits for SBT commands..."
    # Create a cgroup for SBT
    sudo cgcreate -g cpu,memory:/user.slice/$CGROUP_NAME
    # Set CPU limit (75% of 100000 microseconds period)
    sudo cgset -r cpu.max=75000 /user.slice/$CGROUP_NAME
    # Set RAM limit (2GB in bytes)
    sudo cgset -r memory.max=2147483648 /user.slice/$CGROUP_NAME
    echo "Limits applied. To run an SBT command with limits, use: cgexec -g cpu,memory:/user.slice/$CGROUP_NAME sbt <your_sbt_command>"
}

stop_limits() {
    echo "Stopping CPU and RAM limits for SBT commands..."
    sudo cgdelete cpu,memory:/user.slice/$CGROUP_NAME
    echo "Limits stopped and cgroup removed."
}

show_menu() {
    echo "
SBT Resource Management Menu"
    echo "--------------------------"
    echo "1. Install necessary tools (cpulimit, cgroup-tools)"
    echo "2. Uninstall tools and clean up"
    echo "3. Apply CPU and RAM limits for SBT commands"
    echo "4. Stop applied limits"
    echo "5. Exit"
    echo "--------------------------"
}

while true;
do
    show_menu
    read -p "Enter your choice [1-5]: " choice
    case $choice in
        1) install_tools ;;
        2) uninstall_tools ;;
        3) apply_limits ;;
        4) stop_limits ;;
        5) echo "Exiting..."; exit 0 ;;
        *) echo "Invalid option. Please enter a number between 1 and 5." ;;
    esac
    echo ""
done