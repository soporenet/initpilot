#!/bin/bash
#
# Project: initpilot
# File: wls-service-control.sh
# Description: Main control script that orchestrates lifecycle operations for WebLogic components based on the configuration file
# Author: SoporeNet
# Email: admin@sopore.net
# Created: 2025-07-07
#
# Enhanced Weblogic Component Wrapper Script with multi-domain support (based on v7 JSON config)
# set -x

# Get the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config file is always in the same directory as this script
CONFIG_FILE="${SCRIPT_DIR}/wls-service-config.json"

# Load WL_HOME from config (relative to config file location)
WL_HOME="$(jq -r '.wlsdomain.wl_home' "$CONFIG_FILE")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

### ----------------------------
### REUSABLE FUNCTIONS
### ----------------------------
# Centralized JSON property fetcher
get_json_property() {
  local path="$1"
  local default="${2:-}"
  local value

  value=$(jq -e -r "$path" "$CONFIG_FILE" 2> /dev/null)
  if [ $? -ne 0 ] || [ "$value" == "null" ] || [ -z "$value" ]; then
    [ -n "$default" ] && echo "$default" || return 1
  else
    echo "$value"
  fi
}

# Load configuration
DOMAIN_HOME=$(get_json_property ".wlsdomain.home")
LOG_FILE_DIR=$(get_json_property ".wlsdomain.Logging.log_file_dir")
LOG_FILE="$LOG_FILE_DIR/wls-service.log"
LOG_SEP=$(get_json_property ".wlsdomain.Logging.log_rec_item_sep" "|")
OS_USER=$(get_json_property ".wlsdomain.Security.os_user")
OS_GROUP=$(get_json_property ".wlsdomain.Security.os_group")
TRUST_JKS_FILE=$(get_json_property ".wlsdomain.Security.trust_jks_file")
TRUST_JKS_PASSWORD=$(get_json_property ".wlsdomain.Security.trust_jks_password")
MONITOR_USER_CONFIG=$(get_json_property ".wlsdomain.Security.monitor_user_config")
MONITOR_USER_KEY=$(get_json_property ".wlsdomain.Security.monitor_user_key")
NM_USER_CONFIG=$(get_json_property ".wlsdomain.Security.nm_user_config")
NM_USER_KEY=$(get_json_property ".wlsdomain.Security.nm_user_key")
PROCESS_START_TIMEOUT=$(get_json_property ".wlsdomain.Control.timeouts.process_start" "120")
PROCESS_STOP_TIMEOUT=$(get_json_property ".wlsdomain.Control.timeouts.process_stop" "120")
TCPPORT_CONNECT_TIMEOUT=$(get_json_property ".wlsdomain.Control.timeouts.tcpport_connect" "10")
WLST_CONNECT_TIMEOUT=$(($(get_json_property ".wlsdomain.Control.timeouts.wlst_connect" "10") * 1000))
SEQUENCE_DELAY=$(get_json_property ".wlsdomain.Control.wait_times.next_process_startup" "5")
NEXT_HEALTH_ENQUIRY_WAITTIME=$(get_json_property ".wlsdomain.Control.wait_times.next_health_enquiry" "5")

# Helper functions
get_component_property() {
  local comp_key="$1"
  local prop="$2"

  # Find which section contains the component key
  local section
  section=$(
    jq -e -r
    ".wlsdomain.components | 
         (.\"AdminServer\" | has(\"$comp_key\")) as \$a |
         (.\"ManagedServer\" | has(\"$comp_key\")) as \$m |
         (.\"NodeManager\" | has(\"$comp_key\")) as \$n |
         if \$a then \"AdminServer\"
         elif \$m then \"ManagedServer\"
         elif \$n then \"NodeManager\"
         else empty end"
    "$CONFIG_FILE" 2> /dev/null
  )

  [ -z "$section" ] && return 1

  # Get property from the identified section
  local value
  value=$(
    jq -e -r
    ".wlsdomain.components.$section.\"$comp_key\".$prop"
    "$CONFIG_FILE" 2> /dev/null
  )

  if [ $? -eq 0 ] && [ "$value" != "null" ] && [ -n "$value" ]; then
    echo "$value"
  elif [ "$prop" == "type" ]; then
    # For type property, return the section name
    echo "$section"
  else
    return 1
  fi
}

get_component_actual_type() {
  local comp_key="$1"
  # First try to get explicit type property
  local explicit_type=$(get_component_property "$comp_key" "type" 2> /dev/null)
  [ -n "$explicit_type" ] && echo "$explicit_type" | tr -d '[:space:]' && return

  # Fallback to section name
  jq -e -r
  ".wlsdomain.components | 
         (.\"AdminServer\" | has(\"$comp_key\")) as \$a |
         (.\"ManagedServer\" | has(\"$comp_key\")) as \$m |
         (.\"NodeManager\" | has(\"$comp_key\")) as \$n |
         if \$a then \"AdminServer\"
         elif \$m then \"ManagedServer\"
         elif \$n then \"NodeManager\"
         else empty end"
  "$CONFIG_FILE" 2> /dev/null | tr -d '[:space:]'
}

is_component_enabled() {
  [[ "$(get_component_property "$1" "enabled")" == "true" ]]
}

sanitize_log_field() {
  echo "$1" | tr -d "$LOG_SEP" | tr -cd '[:print:]'
}

log() {
  local severity=$(sanitize_log_field "$1")
  local component=$(sanitize_log_field "$2")
  local message=$(sanitize_log_field "$3")
  local fqdn=$(hostname -f)
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local log_line="${timestamp}${LOG_SEP}${severity}${LOG_SEP}${fqdn}${LOG_SEP}${component}${LOG_SEP}${message}"

  echo "$log_line" >> "$LOG_FILE"
  case "$severity" in
    ERROR) echo -e "${RED}$log_line${NC}" >&2 ;;
    WARN) echo -e "${YELLOW}$log_line${NC}" >&2 ;;
    SUCCESS) echo -e "${GREEN}$log_line${NC}" >&2 ;;
    *) echo -e "${BLUE}$log_line${NC}" >&2 ;;
  esac
}

get_pid_file() {
  local comp_name="$1"
  local domain_name=$(basename "$DOMAIN_HOME")
  local safe_domain=$(echo "$domain_name" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
  local safe_comp=$(echo "$comp_name" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
  echo "/run/wls-${safe_domain}-${safe_comp}/wls-${safe_comp}.pid"
}

# PID file operations
_pid_file_operation() {
  local operation="$1"
  local comp_name="$2"
  local pid="${3:-}"
  local pid_file=$(get_pid_file "$comp_name")
  case "$operation" in
    create)
      mkdir -p "$(dirname "$pid_file")"
      chown "$OS_USER:$OS_GROUP" "$(dirname "$pid_file")"
      echo "$pid" > "$pid_file"
      ;;
    delete)
      [ -f "$pid_file" ] && rm -f "$pid_file"
      ;;
    validate)
      [ -f "$pid_file" ] && verify_component_pid "$(cat "$pid_file")" "$comp_name"
      ;;
  esac
}

# Process verification
is_process_running() {
  pgrep -f "$1" > /dev/null
}

verify_component_pid() {
  local pid="$1"
  local comp_name="$2"
  local comp_type=$(get_component_property "$comp_name" "type")
  ps -p "$pid" > /dev/null || return 1
  pwdx $pid 2> /dev/null | grep -q "$DOMAIN_HOME" || return 1
  case "$comp_type" in
    AdminServer) ps -p "$pid" -o cmd= | grep -q "weblogic.Name=$comp_name" ;;
    NodeManager) ps -p "$pid" -o cmd= | grep -q "weblogic.NodeManager" ;;
    ManagedServer) ps -p "$pid" -o cmd= | grep -q "weblogic.Name=$comp_name" ;;
  esac
}

find_component_pid() {
  local comp_name="$1"
  local comp_type=$(get_component_property "$comp_name" "type")
  local pattern
  case "$comp_type" in
    AdminServer) pattern="weblogic.Name=$comp_name" ;;
    NodeManager) pattern="weblogic.NodeManager" ;;
    ManagedServer) pattern="weblogic.Name=$comp_name" ;;
  esac
  for pid in $(pgrep -f "$pattern"); do
    pwdx $pid 2> /dev/null | grep -q "$DOMAIN_HOME" && echo "$pid" && return 0
  done
  return 1
}

# Network checks
check_nc_available() {
  command -v nc &> /dev/null || {
    log "WARN" "SCRIPT" "netcat (nc) not found. Using fallback method for port checks."
    return 1
  }
}

is_port_open() {
  local host="$1"
  local port="$2"
  if check_nc_available; then
    nc -z -w 1 "$host" "$port" > /dev/null 2>&1
  else
    timeout 1 bash -c ">/dev/tcp/$host/$port" &> /dev/null
  fi
}

# Status check framework
_status_adminserver_wlst_only() {
  local comp_name="$1"
  set_wlst_security
  local wlst_script=$(mktemp) || {
    echo "UNHEALTHY"
    return
  }
  _generate_adminserver_wlst "$comp_name" > "$wlst_script"
  local wlst_output=$($WL_HOME/oracle_common/common/bin/wlst.sh -skipWLSModuleScanning "$wlst_script" 2>&1)
  rm -f "$wlst_script"
  # Parse WLST output
  local status=$(echo "$wlst_output" | grep -E 'RUNNING|SHUTDOWN|ADMIN|UNHEALTHY' | tail -1)
  case "$status" in
    "RUNNING") echo "RUNNING" ;;
    "ADMIN") echo "ADMIN" ;;
    *) echo "NOT_REACHABLE" ;;
  esac
}

status_adminserver() {
  local comp_name="$1"
  # Step 1: Check process exists
  if ! find_component_pid "$comp_name" > /dev/null; then
    echo -e "${RED}SHUTDOWN${NC}"
    return
  fi
  # Step 2: Check port connectivity
  local port=$(get_component_property "$comp_name" "port")
  local listen_address=$(get_component_property "$comp_name" "listen_address")
  if ! is_port_open "$listen_address" "$port"; then
    echo -e "${YELLOW}NOT_REACHABLE${NC}"
    return
  fi
  # Step 3: Use WLST to connect and get status
  local wlst_status=$(_status_adminserver_wlst_only "$comp_name")
  case "$wlst_status" in
    "RUNNING") echo -e "${GREEN}RUNNING${NC}" ;;
    "ADMIN") echo -e "${YELLOW}ADMIN${NC}" ;;
    "SHUTDOWN") echo -e "${YELLOW}SHUTDOWN${NC}" ;;
    *) echo -e "${YELLOW}UNHEALTHY${NC}" ;;
  esac
}

status_managedserver() {
  local comp_name="$1"
  # Step 1: Check process exists
  if ! find_component_pid "$comp_name" > /dev/null; then
    echo -e "${RED}SHUTDOWN${NC}"
    return
  fi
  # Step 2: Check port connectivity
  local port=$(get_component_property "$comp_name" "port")
  local listen_address=$(get_component_property "$comp_name" "listen_address")
  if ! is_port_open "$listen_address" "$port"; then
    echo -e "${YELLOW}NOT_REACHABLE${NC}"
    return
  fi
  # Step 3: Use WLST to connect and get status
  set_wlst_security
  local wlst_script=$(mktemp) || {
    echo -e "${YELLOW}UNHEALTHY${NC}"
    return
  }
  _generate_managedserver_wlst "$comp_name" > "$wlst_script"
  local wlst_output=$($WL_HOME/oracle_common/common/bin/wlst.sh -skipWLSModuleScanning "$wlst_script" 2>&1)
  rm -f "$wlst_script"
  # Step 4: Parse WLST output
  local status=$(echo "$wlst_output" | grep -E 'RUNNING|SHUTDOWN|ADMIN|UNHEALTHY' | tail -1)
  case "$status" in
    "RUNNING") echo -e "${GREEN}RUNNING${NC}" ;;
    "ADMIN") echo -e "${YELLOW}ADMIN${NC}" ;;
    "SHUTDOWN") echo -e "${YELLOW}SHUTDOWN${NC}" ;;
    *) echo -e "${YELLOW}UNHEALTHY${NC}" ;;
  esac
}

status_nodemanager() {
  local comp_name="$1"
  # Step 1: Check process exists
  if ! find_component_pid "$comp_name" > /dev/null; then
    echo -e "${RED}SHUTDOWN${NC}"
    return
  fi
  # Step 2: Check port connectivity
  local port=$(get_component_property "$comp_name" "port")
  local listen_address=$(get_component_property "$comp_name" "listen_address")
  if ! is_port_open "$listen_address" "$port"; then
    echo -e "${YELLOW}NOT_REACHABLE${NC}"
    return
  fi
  # Step 3: Use WLST to connect
  set_wlst_security
  local wlst_script=$(mktemp) || {
    echo -e "${YELLOW}UNHEALTHY${NC}"
    return
  }
  cat << EOF > "$wlst_script"
try:
    nmConnect(
        userConfigFile='$NM_USER_CONFIG',
        userKeyFile='$NM_USER_KEY',
        host='$listen_address',
        port=$port,
        nmType='$(get_nm_protocol)',
        domainName='$(get_domain_name)',
        domainDir='$DOMAIN_HOME',
        timeout=$WLST_CONNECT_TIMEOUT
    )
    print('RUNNING')
    exit()
except Exception, e:
    print('UNHEALTHY')
    exit()
EOF
  local wlst_output=$($WL_HOME/oracle_common/common/bin/wlst.sh -skipWLSModuleScanning "$wlst_script" 2>&1)
  rm -f "$wlst_script"
  # Step 4: Mark status
  local status=$(echo "$wlst_output" | grep -E 'RUNNING|UNHEALTHY' | tail -1)
  case "$status" in
    "RUNNING") echo -e "${GREEN}RUNNING${NC}" ;;
    *) echo -e "${YELLOW}UNHEALTHY${NC}" ;;
  esac
}

# WLST script generators
_generate_adminserver_wlst() {
  local comp_name="$1"
  local admin_url
  admin_url=$(get_admin_url)
  cat << EOF
import socket
try:
    connect(userConfigFile="${MONITOR_USER_CONFIG}", 
            userKeyFile="${MONITOR_USER_KEY}", 
            url="${admin_url}", 
            timeout=${WLST_CONNECT_TIMEOUT})
    domainRuntime()
    cd("ServerRuntimes/${comp_name}")
    print(cmo.getState())
    exit()
except Exception, e:
    print("UNHEALTHY")
    exit()
EOF
}

_generate_managedserver_wlst() {
  local ms="$1"
  local ms_url=$(get_ms_url "$ms")
  cat << EOF
import socket
try:
    connect(userConfigFile="${MONITOR_USER_CONFIG}", 
            userKeyFile="${MONITOR_USER_KEY}", 
            url="${ms_url}", 
            timeout=${WLST_CONNECT_TIMEOUT})
    serverRuntime()
    print(cmo.getState())
    exit()
except Exception, e:
    print("UNHEALTHY")
    exit()
EOF
}

# Component control functions with accurate timing
start_adminserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_adminserver "$comp_name")")
  if [ "$raw_status" = "RUNNING" ]; then
    log "SUCCESS" "$comp_name" "Already in status: RUNNING"
    return
  fi
  case "$raw_status" in
    "SHUTDOWN")
      log "INFO" "$comp_name" "Starting AdminServer..."
      _start_component_direct "$comp_name" "AdminServer"
      ;;
    *)
      log "WARN" "$comp_name" "Cannot start from current state: $raw_status"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [ "$raw_status" = "SHUTDOWN" ] && log "INFO" "$comp_name" "AdminServer start operation completed in ${duration}s"
}

start_managedserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_managedserver "$comp_name")")
  if [ "$raw_status" = "RUNNING" ]; then
    log "SUCCESS" "$comp_name" "Already in status: RUNNING"
    return
  fi
  case "$raw_status" in
    "SHUTDOWN")
      _start_component_direct "$comp_name" "ManagedServer"
      ;;
    *)
      log "WARN" "$comp_name" "Cannot start from current state: $raw_status"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [ "$raw_status" = "SHUTDOWN" ] && log "INFO" "$comp_name" "ManagedServer start operation completed in ${duration}s"
}

start_nodemanager() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_nodemanager "$comp_name")")
  if [ "$raw_status" = "RUNNING" ]; then
    log "SUCCESS" "$comp_name" "Already in status: RUNNING"
    return
  fi
  case "$raw_status" in
    "SHUTDOWN")
      log "INFO" "$comp_name" "Starting NodeManager..."
      _start_component_direct "$comp_name" "NodeManager"
      ;;
    "NOT_REACHABLE" | "UNHEALTHY")
      log "WARN" "$comp_name" "Killing unresponsive NodeManager process..."
      pkill -f "weblogic.NodeManager"
      sleep 2
      _start_component_direct "$comp_name" "NodeManager"
      ;;
    *)
      log "WARN" "$comp_name" "Cannot start from current state: $raw_status"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ ^(SHUTDOWN|NOT_REACHABLE|UNHEALTHY)$ ]] \
    && log "INFO" "$comp_name" "NodeManager start operation completed in ${duration}s"
}

stop_adminserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_adminserver "$comp_name")")
  case "$raw_status" in
    "RUNNING" | "ADMIN")
      log "INFO" "$comp_name" "Stopping AdminServer..."
      _stop_component_direct "$comp_name" "AdminServer"
      ;;
    *)
      log "WARN" "$comp_name" "Not running (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ (RUNNING|ADMIN) ]] && log "INFO" "$comp_name" "AdminServer stop operation completed in ${duration}s"
}

stop_managedserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_managedserver "$comp_name")")
  case "$raw_status" in
    "RUNNING" | "ADMIN")
      # Check AdminServer status
      local admin_comp=$(jq -r '.wlsdomain.components.AdminServer | keys[0]' "$CONFIG_FILE")
      local admin_status=$(_status_adminserver_wlst_only "$admin_comp")
      # Get NodeManager for current host
      local nm_comp=$(get_nodemanager_for_host)
      local nm_status=$(strip_color "$(status_nodemanager "$nm_comp")")
      if [ "$admin_status" != "RUNNING" ]; then
        log "WARN" "$comp_name" "AdminServer not RUNNING (status: $admin_status). Attempting ManagedServer stop anyway. Use force-stop if it fails."
      fi
      if [ "$nm_status" != "RUNNING" ]; then
        log "WARN" "$comp_name" "NodeManager is not RUNNING (status: $nm_status). Attempting ManagedServer stop anyway. Use force-stop if it fails."
      fi
      _stop_component_direct "$comp_name" "ManagedServer"
      ;;
    *)
      log "WARN" "$comp_name" "Not running (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ (RUNNING|ADMIN) ]] && log "INFO" "$comp_name" "ManagedServer stop operation completed in ${duration}s"
}

stop_nodemanager() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_nodemanager "$comp_name")")
  case "$raw_status" in
    "RUNNING")
      log "INFO" "$comp_name" "Stopping NodeManager..."
      _stop_component_direct "$comp_name" "NodeManager"
      ;;
    *)
      log "WARN" "$comp_name" "Not running (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [ "$raw_status" == "RUNNING" ] && log "INFO" "$comp_name" "NodeManager stop operation completed in ${duration}s"
}

# Direct start/stop without additional checks
_start_component_direct() {
  local comp_name="$1"
  local comp_type="$2"
  if ! is_component_enabled "$comp_name"; then
    log "WARN" "$comp_name" "Component disabled. Skipping."
    return 1
  fi
  local start_script
  start_script=$(get_component_property "$comp_name" "start_script")
  local start_dir
  start_dir="$DOMAIN_HOME/$(get_component_property "$comp_name" "start_script_path")"
  cd "$start_dir" || return 1
  if [[ "$comp_type" == "AdminServer" ]]; then
    nohup "./${start_script}" > "$LOG_FILE_DIR/${comp_name}.out" 2>&1 &
  else
    nohup "./${start_script}" "$comp_name" > "$LOG_FILE_DIR/${comp_name}.out" 2>&1 &
  fi
  local java_pid
  for ((wait_time = 0; wait_time < 30; wait_time++)); do
    java_pid=$(find_component_pid "$comp_name")
    [ -n "$java_pid" ] && break
    sleep 1
  done
  # Skip PID file operations for NodeManager
  if [[ "$comp_type" != "NodeManager" ]]; then
    _pid_file_operation "create" "$comp_name" "$java_pid"
  fi
  wait_for_status "$comp_name" "$comp_type" "RUNNING" "$PROCESS_START_TIMEOUT" "$NEXT_HEALTH_ENQUIRY_WAITTIME"
}

_stop_component_direct() {
  local comp_name="$1"
  local comp_type="$2"
  local start_time
  start_time=$(date +%s)
  local stop_script
  stop_script=$(get_component_property "$comp_name" "stop_script")
  local stop_dir
  stop_dir="$DOMAIN_HOME/$(get_component_property "$comp_name" "stop_script_path")"
  cd "$stop_dir" || return 1
  if [[ "$comp_type" == "AdminServer" ]]; then
    ./"${stop_script}" > /dev/null 2>&1
  else
    ./"${stop_script}" "$comp_name" > /dev/null 2>&1
  fi
  wait_for_status "$comp_name" "$comp_type" "SHUTDOWN" "$PROCESS_STOP_TIMEOUT" "$NEXT_HEALTH_ENQUIRY_WAITTIME"
  # Skip PID file operations for NodeManager
  if [[ "$comp_type" != "NodeManager" ]]; then
    _pid_file_operation "delete" "$comp_name"
  fi
}

# Force stop functions
force_stop_adminserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_adminserver "$comp_name")")
  case "$raw_status" in
    "RUNNING" | "ADMIN" | "NOT_REACHABLE" | "UNHEALTHY")
      _stop_component_direct "$comp_name" "AdminServer"
      if [ "$(strip_color "$(status_adminserver "$comp_name")")" != "SHUTDOWN" ]; then
        pkill -f "weblogic.Name=$comp_name"
        _pid_file_operation "delete" "$comp_name"
      fi
      ;;
    *)
      log "WARN" "$comp_name" "Already stopped (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ (RUNNING|ADMIN|NOT_REACHABLE|UNHEALTHY) ]] \
    && log "INFO" "$comp_name" "AdminServer force stop operation completed in ${duration}s"
}

force_stop_managedserver() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_managedserver "$comp_name")")
  case "$raw_status" in
    "RUNNING" | "ADMIN" | "NOT_REACHABLE" | "UNHEALTHY")
      _stop_component_direct "$comp_name" "ManagedServer"
      if [ "$(strip_color "$(status_managedserver "$comp_name")")" != "SHUTDOWN" ]; then
        pkill -f "weblogic.Name=$comp_name"
        _pid_file_operation "delete" "$comp_name"
      fi
      ;;
    *)
      log "WARN" "$comp_name" "Already stopped (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ (RUNNING|ADMIN|NOT_REACHABLE|UNHEALTHY) ]] \
    && log "INFO" "$comp_name" "ManagedServer force stop operation completed in ${duration}s"
}

force_stop_nodemanager() {
  local comp_name="$1"
  local operation_start=$(date +%s)
  local raw_status=$(strip_color "$(status_nodemanager "$comp_name")")
  case "$raw_status" in
    "RUNNING" | "NOT_REACHABLE" | "UNHEALTHY")
      _stop_component_direct "$comp_name" "NodeManager"
      if [ "$(strip_color "$(status_nodemanager "$comp_name")")" != "SHUTDOWN" ]; then
        pkill -f "weblogic.NodeManager"
      fi
      ;;
    *)
      log "WARN" "$comp_name" "Already stopped (Status: $raw_status)"
      ;;
  esac
  local operation_end=$(date +%s)
  local duration=$((operation_end - operation_start))
  [[ "$raw_status" =~ (RUNNING|NOT_REACHABLE|UNHEALTHY) ]] \
    && log "INFO" "$comp_name" "NodeManager force stop operation completed in ${duration}s"
}

# Helper functions
get_server_fqdn() {
  hostname -f
}

get_server_components() {
  local fqdn=$(get_server_fqdn)
  get_json_property ".wlsdomain.servers.\"$fqdn\".component_list[]"
}

get_server_start_order() {
  local fqdn=$(get_server_fqdn)
  get_json_property ".wlsdomain.servers.\"$fqdn\".component_start_order[]"
}

get_server_stop_order() {
  local fqdn=$(get_server_fqdn)
  get_json_property ".wlsdomain.servers.\"$fqdn\".component_stop_order[]"
}

get_server_force-stop_order() {
  get_server_stop_order
}

get_domain_name() {
  basename "$DOMAIN_HOME"
}

strip_color() {
  echo "$1" | sed -r "s/\x1B\[([0-9]{1,3}(;[0-9]{1,2})?)?[mGK]//g"
}

get_nm_protocol() {
  local nm_component=$(get_server_fqdn)
  [ "$(get_component_property "$nm_component" "ssl_enabled")" = "true" ] && echo "ssl" || echo "plain"
}

get_admin_url() {
  local admin_component=$(jq -r '.wlsdomain.components.AdminServer | keys[0]' "$CONFIG_FILE")
  local ssl_enabled=$(get_component_property "$admin_component" "ssl_enabled")
  local port=$(get_component_property "$admin_component" "port")
  local listen_address=$(get_component_property "$admin_component" "listen_address")
  [ "$ssl_enabled" = "true" ] && echo "t3s://${listen_address}:$port" || echo "t3://${listen_address}:$port"
}

get_ms_url() {
  local ms="$1"
  local port=$(get_component_property "$ms" "port")
  local ssl_enabled=$(get_component_property "$ms" "ssl_enabled")
  local listen_address=$(get_component_property "$ms" "listen_address")
  [ "$ssl_enabled" = "true" ] && echo "t3s://${listen_address}:$port" || echo "t3://${listen_address}:$port"
}

set_wlst_security() {
  export WLST_PROPERTIES="-Dweblogic.security.SSL.enableJSSE=true \
        -Djavax.net.ssl.trustStore=$TRUST_JKS_FILE \
        -Djavax.net.ssl.trustStorePassword=$TRUST_JKS_PASSWORD \
        -Dweblogic.security.TrustKeyStore=CustomTrust \
        -Dweblogic.security.CustomTrustKeyStoreFileName=$TRUST_JKS_FILE \
        -Dweblogic.security.CustomTrustKeyStorePassPhrase=$TRUST_JKS_PASSWORD"
}

wait_for_status() {
  local comp_name="$1"
  local comp_type="$2"
  local desired_status="$3"
  local timeout="$4"
  local interval="$5"
  local start_time=$(date +%s)
  local elapsed=0
  local spinner=('|' '/' '-' '\\')
  local spinner_idx=0

  log "INFO" "$comp_name" "Waiting to reach status: $desired_status (timeout: ${timeout}s)"

  while [ $elapsed -lt $timeout ]; do
    local current_status=$(status_${comp_type,,} "$comp_name")
    local current_status_plain=$(strip_color "$current_status")
    local desired_status_upper=$(echo "$desired_status" | tr '[:lower:]' '[:upper:]')

    if [ "$current_status_plain" = "$desired_status_upper" ]; then
      printf "\r"
      log "SUCCESS" "$comp_name" "Reached status: $desired_status in ${elapsed}s"
      return 0
    fi

    elapsed=$(($(date +%s) - start_time))
    remaining=$((timeout - elapsed))
    printf "\r[%s] Waiting for %s: %ds remaining " "${spinner[spinner_idx]}" "$desired_status" "$remaining"
    spinner_idx=$(((spinner_idx + 1) % 4))
    sleep $interval
  done

  printf "\r"
  log "ERROR" "$comp_name" "Timeout reached while waiting to become $desired_status (${timeout}s)"
  return 1
}

# Get NodeManager for current host
get_nodemanager_for_host() {
  local host=$(hostname -f)
  jq -r --arg host "$host" \
    '.wlsdomain.components.NodeManager | to_entries[] | select(.value.host_id == $host) | .key' \
    "$CONFIG_FILE"
}

# Component sequence operations
_execute_component_sequence() {
  local action="$1"
  local server_fqdn=$(get_server_fqdn)
  local sequence=($(get_server_${action}_order))
  local server_components=($(get_server_components))
  log "INFO" "SCRIPT" "${action^}ing components on $server_fqdn in order: ${sequence[*]}"
  for comp in "${sequence[@]}"; do
    if [[ " ${server_components[@]} " =~ " $comp " ]] && is_component_enabled "$comp"; then
      local comp_type=$(get_component_actual_type "$comp")
      log "INFO" "$comp" "Processing ${action} for $comp_type"
      case "$action" in
        start)
          start_${comp_type,,} "$comp"
          ;;
        stop)
          stop_${comp_type,,} "$comp"
          ;;
        force-stop)
          force_stop_${comp_type,,} "$comp"
          ;;
      esac
      sleep $SEQUENCE_DELAY
    fi
  done
}

start_all() {
  _execute_component_sequence "start"
}

stop_all() {
  _execute_component_sequence "stop"
}

force_stop_all() {
  _execute_component_sequence "force-stop"
}

status_all() {
  local server_fqdn=$(get_server_fqdn)
  local sequence=($(get_server_start_order))
  local server_components=($(get_server_components))
  local enabled_components=()

  for comp in "${sequence[@]}"; do
    if is_component_enabled "$comp"; then
      enabled_components+=("$comp")
    fi
  done

  log "INFO" "SCRIPT" "Status of all components on $server_fqdn: ${enabled_components[*]}"

  local all_ok=0
  for comp in "${enabled_components[@]}"; do
    local comp_type=$(get_component_actual_type "$comp")
    local status_output=$(status_${comp_type,,} "$comp")
    local plain_status=$(strip_color "$status_output")
    log "INFO" "$comp" "Status: $plain_status"
    [ "$plain_status" != "RUNNING" ] && all_ok=1
  done

  return $all_ok
}

# PID directory management
setup_pid_dirs() {
  [ $(id -u) -ne 0 ] && {
    log "ERROR" "SCRIPT" "Must run as root"
    exit 1
  }
  local domain_name=$(get_domain_name)
  local safe_domain=$(echo "$domain_name" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
  local conf_file="/etc/tmpfiles.d/wls-${safe_domain}-pid.conf"
  [ -f "$conf_file" ] && {
    log "WARN" "SCRIPT" "$conf_file already exists"
    return
  }
  for comp in $(get_server_components); do
    local comp_type=$(get_component_property "$comp" "type")
    [[ "$comp_type" =~ ^(AdminServer|ManagedServer)$ ]] || continue
    local safe_comp=$(echo "$comp" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
    echo "d /run/wls-${safe_domain}-${safe_comp} 0775 $OS_USER $OS_GROUP - -" >> "$conf_file"
  done
  systemd-tmpfiles --create "$conf_file"
  log "INFO" "SCRIPT" "Created PID directory configuration: $conf_file"
}

clean_pid_dirs() {
  [ $(id -u) -ne 0 ] && {
    log "ERROR" "SCRIPT" "Must run as root"
    exit 1
  }
  local domain_name=$(get_domain_name)
  local safe_domain=$(echo "$domain_name" | tr -cd '[:alnum:]_-' | tr '[:upper:]' '[:lower:]')
  local conf_file="/etc/tmpfiles.d/wls-${safe_domain}-pid.conf"
  [ -f "$conf_file" ] && rm -f "$conf_file" && log "INFO" "SCRIPT" "Removed $conf_file" \
    || log "WARN" "SCRIPT" "$conf_file not found"
}

### ----------------------------
### MAIN EXECUTION
### ----------------------------

# Ensure log directory exists
mkdir -p "$LOG_FILE_DIR"
chown "$OS_USER:$OS_GROUP" "$LOG_FILE_DIR"
[ ! -f "$LOG_FILE" ] && touch "$LOG_FILE"
chown "$OS_USER:$OS_GROUP" "$LOG_FILE"

# Alias functions for consistent naming
admin_status() { status_adminserver "$@"; }
managed_status() { status_managedserver "$@"; }
nodemanager_status() { status_nodemanager "$@"; }

case "$1" in
  start | status)
    comp_key="$2"
    [ -z "$comp_key" ] && {
      echo -e "${RED}Error: Component name required${NC}" >&2
      exit 1
    }
    # Special handling for NodeManager
    if [ "$comp_key" == "NodeManager" ]; then
      # Find NodeManager component for this host
      comp_key=$(jq -r --arg host "$(hostname -f)" \
        '.wlsdomain.components.NodeManager | to_entries[] | select(.value.host_id == $host) | .key' \
        "$CONFIG_FILE")
      [ -z "$comp_key" ] && {
        log "ERROR" "NodeManager" "Could not find NodeManager for this host"
        exit 1
      }
      comp_type="NodeManager"
    elif ! comp_type=$(get_component_property "$comp_key" "type"); then
      log "ERROR" "$comp_key" "Could not determine component type ($1)"
      exit 1
    fi
    log "INFO" "$comp_key" "${1^} requested"
    ${1}_${comp_type,,} "$comp_key"
    ;;
  stop | force-stop)
    comp_key="$2"
    [ -z "$comp_key" ] && {
      echo -e "${RED}Error: Component name required${NC}" >&2
      exit 1
    }
    # Special handling for NodeManager
    if [ "$comp_key" == "NodeManager" ]; then
      # Find NodeManager component for this host
      comp_key=$(jq -r --arg host "$(hostname -f)" \
        '.wlsdomain.components.NodeManager | to_entries[] | select(.value.host_id == $host) | .key' \
        "$CONFIG_FILE")
      [ -z "$comp_key" ] && {
        log "ERROR" "NodeManager" "Could not find NodeManager for this host"
        exit 1
      }
      comp_type="NodeManager"
    elif ! comp_type=$(get_component_property "$comp_key" "type"); then
      log "ERROR" "$comp_key" "Could not determine component type ($1)"
      exit 1
    fi
    log "INFO" "$comp_key" "${1^} requested"
    ${1//-/_}_${comp_type,,} "$comp_key"
    ;;
  start-all | stop-all | force-stop-all | status-all)
    log "INFO" "SCRIPT" "${1//-/ } requested"
    ${1//-/_}
    ;;
  setup | clean)
    log "INFO" "SCRIPT" "${1^} requested"
    ${1}_pid_dirs
    ;;
  *)
    echo -e "${BLUE}Usage: $0 {start|stop|force-stop|status|start-all|stop-all|force-stop-all|status-all|setup|clean} <Component>${NC}"
    echo -e "${YELLOW}Components: AdminServer name, NodeManager names, or ManagedServer names${NC}"
    exit 1
    ;;
esac

exit $?
