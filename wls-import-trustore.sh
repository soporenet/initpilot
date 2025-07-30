#!/bin/bash
#
# Project: initpilot
# File: wls-import-truststore.sh
# Description: Configure Truststore (for SSL environments, for example if WebLogic Domain Wide Administration port is enabled)
# Author: SoporeNet
# Email: admin@sopore.net
# Created: 2025-07-07
#
set -e
 
TRUSTSTORE="wls-service-truststore.jks"
DOMAIN_HELPER_DIR=$(dirname "$(readlink -f "$0")")
DOMAIN_HOME=$(dirname "$DOMAIN_HELPER_DIR")
TRUSTSTORE_PATH="$DOMAIN_HELPER_DIR/$TRUSTSTORE"
 
# Function to validate password strength
validate_password() {
  local password=$1
  if [ ${#password} -lt 6 ]; then
    echo "Password must be at least 6 characters long"
    return 1
  fi
  return 0
}
 
# Prompt for JKS password with verification
while true; do
  read -s -p "Enter truststore password: " password
  echo
  read -s -p "Confirm truststore password: " password_confirm
  echo
  if [ "$password" != "$password_confirm" ]; then
    echo "Passwords do not match. Please try again."
    continue
  fi
  if ! validate_password "$password"; then
    continue
  fi
  break
done
 
PASSWORD="$password"
 
# Create truststore if it doesn't exist
if [ ! -f "$TRUSTSTORE_PATH" ]; then
  echo "Creating new truststore: $TRUSTSTORE_PATH"
  keytool -genkeypair -alias dummy -dname "CN=dummy, OU=dummy, O=dummy, L=dummy, ST=dummy, C=dummy" \
      -keyalg RSA -keysize 2048 -validity 1 \
      -keystore "$TRUSTSTORE_PATH" -storepass "$PASSWORD" -keypass "$PASSWORD"
  keytool -delete -alias dummy -keystore "$TRUSTSTORE_PATH" -storepass "$PASSWORD"
  echo "Truststore created successfully"
else
  echo "Using existing truststore: $TRUSTSTORE_PATH"
fi
 
# Certificate import loop
while true; do
  echo
  read -p "Enter full path to PEM certificate (or 'exit' to quit): " pem_file
  if [ "$pem_file" = "exit" ]; then
    break
  fi
  if [ ! -f "$pem_file" ]; then
    echo "File not found: $pem_file"
    continue
  fi
  # Generate unique alias
  alias_name="trust$(date +'%Y%m%d%H%M%S')"
  echo "Importing certificate: $pem_file"
  if keytool -import -v -trustcacerts -alias "$alias_name" \
      -file "$pem_file" -keystore "$TRUSTSTORE_PATH" \
      -storepass "$PASSWORD" -noprompt; then
    echo "Successfully imported as: $alias_name"
  else
    echo "Failed to import certificate"
  fi
done
 
echo
echo "======================================================"
echo "Truststore update complete"
echo "Location: $TRUSTSTORE_PATH"
echo "Password: $PASSWORD"
echo "======================================================"
echo "Add this to your json for WLST connections:"
echo "======================================================"
