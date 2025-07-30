#!/bin/bash
#
# Project: initpilot
# File: wls-service-setup.sh
# Description: Systemd integration script for service file generation and management
# Author: SoporeNet
# Email: admin@sopore.net
# Created: 2025-07-07
#
# Enhanced WebLogic Systemd Service Setup Script (Based on JSCON config v07)
# Configuration
#
# Get the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Config file is always in the same directory as this script
CONFIG_FILE="${SCRIPT_DIR}/wls-service-config.json"
CONTROL_SCRIPT="${SCRIPT_DIR}/wls-service-control.sh"
SERVICE_PREFIX="wls"
 
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
 
# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}" >&2
    exit 1
fi
 
# Validate wrapper script
if [ ! -f "$CONTROL_SCRIPT" ]; then
    echo -e "${RED}Error: Wrapper script $CONTROL_SCRIPT not found${NC}" >&2
    exit 1
fi
 
# Load JSON configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file $CONFIG_FILE not found${NC}" >&2
    exit 1
fi
 
DOMAIN_HOME=$(jq -r '.wlsdomain.home' "$CONFIG_FILE")
DOMAIN_NAME=$(basename "$DOMAIN_HOME")
SAFE_DOMAIN=$(echo "$DOMAIN_NAME" | tr -cd '[:alnum:]_-')
CURRENT_HOST=$(hostname -f)
OS_USER=$(jq -r '.wlsdomain.Security.os_user' "$CONFIG_FILE")
OS_GROUP=$(jq -r '.wlsdomain.Security.os_group' "$CONFIG_FILE")
PROCESS_START_TIMEOUT=$(jq -r '.wlsdomain.Control.timeouts.process_start' "$CONFIG_FILE")
PROCESS_STOP_TIMEOUT=$(jq -r '.wlsdomain.Control.timeouts.process_stop' "$CONFIG_FILE")
 
# Get components for current host
SERVER_COMPONENTS=$(jq -r ".wlsdomain.servers.\"$CURRENT_HOST\".component_list[]" "$CONFIG_FILE")
START_ORDER=($(jq -r ".wlsdomain.servers.\"$CURRENT_HOST\".component_start_order[]" "$CONFIG_FILE"))
STOP_ORDER=($(jq -r ".wlsdomain.servers.\"$CURRENT_HOST\".component_stop_order[]" "$CONFIG_FILE"))
 
# Helper functions - FIXED COMPONENT PROPERTY LOOKUP
get_component_property() {
    local comp_name=$1
    local prop=$2
    # Try all component types
	jq -e -r \
	  "if .wlsdomain.components.AdminServer[\"$comp_name\"]? then .wlsdomain.components.AdminServer[\"$comp_name\"].$prop elif .wlsdomain.components.ManagedServer[\"$comp_name\"]? then .wlsdomain.components.ManagedServer[\"$comp_name\"].$prop elif .wlsdomain.components.NodeManager[\"$comp_name\"]? then .wlsdomain.components.NodeManager[\"$comp_name\"].$prop else null end" \
	  "$CONFIG_FILE" 2>/dev/null
}
 
get_component_type() {
    local comp_name=$1
    # First try to get explicit type property
    local explicit_type=$(get_component_property "$comp_name" "type")
    if [ -n "$explicit_type" ]; then
        echo "$explicit_type"
        return
    fi
    # Fallback to section name
    if jq -e -r ".wlsdomain.components.AdminServer | has(\"$comp_name\")" "$CONFIG_FILE" | grep -q "true"; then
        echo "AdminServer"
    elif jq -e -r ".wlsdomain.components.ManagedServer | has(\"$comp_name\")" "$CONFIG_FILE" | grep -q "true"; then
        echo "ManagedServer"
    elif jq -e -r ".wlsdomain.components.NodeManager | has(\"$comp_name\")" "$CONFIG_FILE" | grep -q "true"; then
        echo "NodeManager"
    else
        return 1
    fi
}
 
is_component_enabled() {
    local comp_name=$1
    local enabled=$(get_component_property "$comp_name" "enabled")
    [[ "$enabled" == "true" ]]
}
 
# Service file directory
SYSTEMD_DIR="/usr/lib/systemd/system"
 
create_service_dependencies() {
    local comp=$1
    local comp_type=$(get_component_type "$comp")
    local deps=""
 
    if [[ "$comp_type" == "ManagedServer" ]]; then
        # Find position in start order
        local index=-1
        for i in "${!START_ORDER[@]}"; do
            if [[ "${START_ORDER[$i]}" == "$comp" ]]; then
                index=$i
                break
            fi
        done
        # Add dependencies for base services
        for base_comp in "${START_ORDER[@]}"; do
            base_comp_type=$(get_component_type "$base_comp")
            if [[ "$base_comp_type" == "AdminServer" || "$base_comp_type" == "NodeManager" ]]; then
                deps+="After=${SERVICE_PREFIX}-${SAFE_DOMAIN}@${base_comp}.service\n"
                deps+="Requires=${SERVICE_PREFIX}-${SAFE_DOMAIN}@${base_comp}.service\n"
            fi
        done
        # Add dependency on previous component in sequence
        if ((index > 0)); then
            local prev_comp="${START_ORDER[$index-1]}"
            deps+="After=${SERVICE_PREFIX}-${SAFE_DOMAIN}@${prev_comp}.service\n"
        fi
    fi
 
    echo -e "$deps"
}
 
create_service_file() {
    local comp=$1
    local comp_type=$(get_component_type "$comp")
    local service_file="${SYSTEMD_DIR}/${SERVICE_PREFIX}-${SAFE_DOMAIN}@${comp}.service"
    local dependencies=$(create_service_dependencies "$comp")
 
    local service_type="oneshot"
    local exec_stop="$CONTROL_SCRIPT force-stop $comp"
    local remain_exit="RemainAfterExit=yes"
 
    cat > "$service_file" << EOF
[Unit]
Description=WebLogic $comp_type $comp for domain $DOMAIN_NAME
After=network.target
PartOf=${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service
$dependencies
 
[Service]
User=$OS_USER
Group=$OS_GROUP
Type=$service_type
$remain_exit
ExecStart=$CONTROL_SCRIPT start $comp
ExecStop=$exec_stop
TimeoutStartSec=$PROCESS_START_TIMEOUT
TimeoutStopSec=$PROCESS_STOP_TIMEOUT
 
[Install]
WantedBy=multi-user.target
WantedBy=${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service
EOF
 
    echo -e "${GREEN}Installed service: ${service_file}${NC}"
}
 
create_target_file() {
    local target_file="${SYSTEMD_DIR}/${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service"
 
    cat > "$target_file" << EOF
[Unit]
Description=WebLogic Domain $DOMAIN_NAME on $CURRENT_HOST
After=network.target
Requires=multi-user.target
 
[Install]
WantedBy=multi-user.target
EOF
 
    echo -e "${GREEN}Installed target: ${target_file}${NC}"
}
 
setup_services() {
    echo -e "${YELLOW}Setting up systemd services...${NC}"
 
    create_target_file
 
    for comp in $SERVER_COMPONENTS; do
        create_service_file "$comp"
    done
 
    systemctl daemon-reload
 
    for comp in $SERVER_COMPONENTS; do
        local service_name="${SERVICE_PREFIX}-${SAFE_DOMAIN}@${comp}.service"
 
		if is_component_enabled "$comp"; then
			systemctl unmask "$service_name" 2>/dev/null
			systemctl enable "$service_name"
			echo -e "${GREEN}Enabled service: $service_name${NC}"
        else
            systemctl mask "$service_name" >/dev/null 2>&1
            echo -e "${YELLOW}Masked service: $service_name (component disabled)${NC}"
        fi
    done
 
    systemctl enable "${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service"
 
    echo -e "${GREEN}Setup completed. Services are now ready to use.${NC}"
    echo -e "${YELLOW}Note: Start/stop sequences are controlled by systemd dependencies.${NC}"
    echo -e "Use: systemctl start ${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service"
}
 
clean_services() {
    echo -e "${YELLOW}Cleaning up systemd services...${NC}"
 
    # Create arrays for each component type
    local managed_services=()
    local nm_services=()
    local admin_services=()
 
    # Categorize components by type
    for comp in $SERVER_COMPONENTS; do
        local comp_type=$(get_component_type "$comp")
        local service_name="${SERVICE_PREFIX}-${SAFE_DOMAIN}@${comp}.service"
        case $comp_type in
            ManagedServer) managed_services+=("$service_name") ;;
            NodeManager)   nm_services+=("$service_name") ;;
            AdminServer)   admin_services+=("$service_name") ;;
        esac
    done
 
    # Clean Managed Servers first
    for service_name in "${managed_services[@]}"; do
        if [ -f "${SYSTEMD_DIR}/${service_name}" ]; then
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            systemctl reset-failed "$service_name" 2>/dev/null
            rm -f "${SYSTEMD_DIR}/${service_name}"
            echo -e "${GREEN}Removed service: $service_name${NC}"
        fi
    done
    # Clean NodeManager next
    for service_name in "${nm_services[@]}"; do
        if [ -f "${SYSTEMD_DIR}/${service_name}" ]; then
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            systemctl reset-failed "$service_name" 2>/dev/null
            rm -f "${SYSTEMD_DIR}/${service_name}"
            echo -e "${GREEN}Removed service: $service_name${NC}"
        fi
    done
 
    # Clean AdminServer last
    for service_name in "${admin_services[@]}"; do
        if [ -f "${SYSTEMD_DIR}/${service_name}" ]; then
            systemctl stop "$service_name" 2>/dev/null
            systemctl disable "$service_name" 2>/dev/null
            systemctl reset-failed "$service_name" 2>/dev/null
            rm -f "${SYSTEMD_DIR}/${service_name}"
            echo -e "${GREEN}Removed service: $service_name${NC}"
        fi
    done
 
    # Clean up target service
    local target_name="${SERVICE_PREFIX}-${SAFE_DOMAIN}-target.service"
    if [ -f "${SYSTEMD_DIR}/${target_name}" ]; then
        systemctl stop "$target_name" 2>/dev/null
        systemctl disable "$target_name" 2>/dev/null
        rm -f "${SYSTEMD_DIR}/${target_name}"
        echo -e "${GREEN}Removed target: $target_name${NC}"
    fi
 
    systemctl daemon-reload
    echo -e "${GREEN}Cleanup completed.${NC}"
}
 
list_services() {
    echo -e "${YELLOW}Installed systemd services:${NC}"
    for comp in $SERVER_COMPONENTS; do
        local service_name="${SERVICE_PREFIX}-${SAFE_DOMAIN}@${comp}.service"
        if [ -f "${SYSTEMD_DIR}/${service_name}" ]; then
            local status=$(systemctl is-enabled "$service_name" 2>/dev/null || echo "masked")
            echo -e " - $service_name (Status: ${status})"
        fi
    done
}
 
show_menu() {
    echo -e "\n${BLUE}WebLogic Systemd Setup Helper${NC}"
    echo "============================="
    echo "Config: $CONFIG_FILE"
    echo "Domain: $DOMAIN_NAME"
    echo "Host: $CURRENT_HOST"
    echo -e "\nComponents detected on this host:"
    for comp in $SERVER_COMPONENTS; do
        enabled=$(is_component_enabled "$comp" && echo "Enabled" || echo "Disabled")
        comp_type=$(get_component_type "$comp")
        echo " - $comp ($comp_type) ($enabled)"
    done
 
    echo -e "\nStart Order: ${START_ORDER[*]}"
    echo -e "Stop Order: ${STOP_ORDER[*]}"
 
    echo -e "\nMenu:"
    echo "1) Setup systemd services"
    echo "2) Cleanup systemd services"
    echo "3) List installed services"
    echo "4) Exit"
}
 
if [ $# -gt 0 ]; then
    case $1 in
        setup) setup_services ;;
        clean) clean_services ;;
        list) list_services ;;
        *) echo "Usage: $0 {setup|clean|list}"; exit 1 ;;
    esac
    exit 0
fi
 
while true; do
    show_menu
    read -rp "Select option [1-4]: " choice
    case $choice in
        1) setup_services ;;
        2) clean_services ;;
        3) list_services ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac
    echo
done
