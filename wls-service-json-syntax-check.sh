#!/bin/bash
# Project: initpilot
# File: wls-service-json-syntax-check.sh
# Description: Basic JSON syntax checking
# Author: SoporeNet
# Email: admin@sopore.net
# Created: 2025-07-07
#
JSON_FILE="$1"
 
 
if [[ -z "$JSON_FILE" ]]; then
  echo "Usage: $0 <json-file>"
  exit 1
fi
 
jq empty wls-service-config.json && echo "✅ JSON syntax OK" || echo "❌ JSON syntax error"
