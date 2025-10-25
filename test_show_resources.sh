#!/bin/bash

# Source only the necessary functions without triggering the main menu
source airline_manager.sh 2>/dev/null || true

# Call show_system_resources directly
show_system_resources