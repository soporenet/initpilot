<!--

Project: initpilot

File: MANUAL.md

Description: Guide

Author: SoporeNet

Email: admin@sopore.net

Created: 2025-07-07

-->
 
# WebLogic Systemd Integration (initpilot) Manual

## Table of Contents

1. [Overview](#overview)

2. [System Requirements](#system-requirements)

3. [Configuration Files](#configuration-files)

   - [wls-service-config.json](#wls-service-configjson)

   - [wls-service-control.sh](#wls-service-controlsh)

   - [wls-service-setup.sh](#wls-service-setupsh)

4. [Installation & Setup](#installation--setup)

5. [Operation & Management](#operation--management)

   - [Component Control](#component-control)

   - [Domain-wide Operations](#domain-wide-operations)

   - [Systemd Service Management](#systemd-service-management)

6. [Troubleshooting](#troubleshooting)

7. [SELinux Configuration](#selinux-config)

8. [Uninstallation](#uninstallation)
 
## Overview <a name="overview"></a>

This solution provides enterprise-grade management for WebLogic components (AdminServer, NodeManager, Managed Servers) through systemd. Key features include:

- **Multi-domain support**: Manage multiple domains simultaneously

- **Dependency-aware sequencing**: Controlled start/stop sequences

- **Comprehensive monitoring**: WLST-based health checks

- **Centralized logging**: Structured log format with severity levels

- **SSL support**: Integrated truststore management

- **PID management**: Systemd-compatible PID tracking

## System Requirements <a name="system-requirements"></a>

### Assumptions

- WebLogic is installed using OS user `oracle` and group `oinstall`. If you used a different user/group, adjust the steps accordingly.

- A WebLogic domain is already configured, and you can start/stop AdminServer, NodeManagers, and Managed Servers using your own **non-interactive** scripts (default or custom).  

  This solution **does not create or manage these scripts** — it relies on them to control component lifecycles.

- SELinux is disabled or in Permissive mode. If SELinux is in Enforcing mode, see [SELinux Configuration](#selinux-config) section and make sure the setup/concept is tested thoroughly.

- This guide uses the following sample values — update them to match your environment:

  - DOMAIN_HOME=`/u01/oracle/products/wls1412/user_projects/domains/TestDomain2`

  - WL_HOME=`/u01/oracle/products/wls1412`

  - OS User Home=`/home/oracle`

  - Admin Server: `AS` (as defined in `config.xml`)

  - Managed Servers: `MS1`, `MS2`, `MS3`, etc. (as defined in `config.xml`)

  - NodeManagers: `NM1`, `NM2`, etc. — **logical names used only within this solution**, not present in `config.xml`

### Software Requirements

- `jq` (JSON processor)

- `nc` (netcat) for port checks

- `systemd` (v239+)

### OS Configuration

```bash

# Install required packages (RHEL/Oracle Linux)

sudo dnf install -y jq nmap-ncat

```

## Configuration Files <a name="configuration-files"></a>

### wls-service-config.json <a name="wls-service-configjson"></a>

This JSON file defines the full configuration for WebLogic systemd integration. It includes domain information, component definitions, server mappings, timeout settings, and security parameters.

---

#### Domain Section

| Field               | Type   | Description                  | Example                                                                 |

|---------------------|--------|------------------------------|-------------------------------------------------------------------------|

| `wlsdomain.name`    | String | Logical domain name          | `"TestDomain2"`                                                         |

| `wlsdomain.home`    | String | Absolute path to domain home | `"/u01/oracle/products/wls1412/user_projects/domains/TestDomain2"`      |

| `wlsdomain.wl_home` | String | Absolute path to WL home     | `"/u01/oracle/products/wls1412"`                                        |

---

#### Components Configuration

This solution manages lifecycle of three types of WebLogic domain components -  AdminServer, NodeManager and ManagedServer.

AdminServer and ManagedServer components are defined under their names as per real WebLogic domain (e.g., `AS`,`MS1`) while as NodeManagers are defined under pseudo names (e.g., `NM1`, `NM2`).

Configuration for `AdminServer` (key: `AS`) looks like this:

```json

"components": {

  "AS": {

    "type": "AdminServer",

    "port": 18001,

    "ssl_enabled": false,

    "listen_address": "lnxwls1.sopore.net",

    "start_script": "startWebLogic.sh",

    "start_script_path": ".",

    "stop_script": "stopWebLogic.sh",

    "stop_script_path": "bin",

    "enabled": true

  }

}

```

**Generic Field Descriptions**:

- `type`: `AdminServer`, `NodeManager`, or `ManagedServer`

- `port`: Listening port for status check

- `ssl_enabled`: Use SSL (`true` or `false`)

- `listen_address`: Hostname/IP

- `start_script`: Script to start the server

- `stop_script`: Script to stop the server

- `*_script_path`: Relative path from domain home

- `enabled`: Whether the component is active (`true`/`false`)

---

#### Server-Specific Configuration

Describes which host runs which components, and defines their startup/shutdown order.

```json

"servers": {

  "lnxwls1.sopore.net": {

    "components": ["NM1", "AS", "MS1"],

    "nodemanager": {

      "listen_address": "lnxwls1.sopore.net",

      "port": 15556

    },

    "start_order": ["NM1", "AS", "MS1"],

    "stop_order": ["MS1", "AS", "NM1"]

  }

}

```

---

#### Timeout Configuration

Manages operation timings and health check delays.

```json

"Control": {

  "timeouts": {

    "process_start": 120,

    "process_stop": 120,

    "tcpport_connect": 10,

    "wlst_connect": 10

  },

  "wait_times": {

    "next_process_startup": 5,

    "next_health_enquiry": 5

  }

}

```

**Recommended Values**:

- `process_start`: 120–300 seconds

- `process_stop`: 60–180 seconds

- `tcpport_connect`: 5–15 seconds

- `wlst_connect`: 10–30 seconds

---

#### Security Configuration

Points to secure credential files and truststore.

```json

"Security": {

  "trust_jks_file": "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/wls-service-truststore.jks",

  "trust_jks_password": "changeit",

  "monitor_user_config": "/home/oracle/wls-monitor.config",

  "monitor_user_key": "/home/oracle/wls-monitor.key",

  "nm_user_config": "/home/oracle/wls-nmadmin.config",

  "nm_user_key": "/home/oracle/wls-nmadmin.key",

  "os_user": "oracle",

  "os_group": "oinstall"

}

```

---

#### Logging Configuration

Defines the log directory and log record formatting.

```json

"Logging": {

  "log_file_dir": "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/logs",

  "log_rec_item_sep": "|"

}

```

### wls-service-control.sh <a name="wls-service-controlsh"></a>

Main control script that orchestrates lifecycle operations for WebLogic components based on the configuration file.

#### Component Operations

Use short component keys (e.g., `AS`, `NM1`, `MS1`) to control specific components:

```bash

# Start component

./wls-service-control.sh start <ComponentKey>

# Stop component

./wls-service-control.sh stop <ComponentKey>

# Force stop (ungraceful)

./wls-service-control.sh force-stop <ComponentKey>

# Check status

./wls-service-control.sh status <ComponentKey>

```
 
 
#### Domain Operations

Execute operations for all components defined on the local server:

```bash

# Start all components on current host in configured order

./wls-service-control.sh start-all

# Stop all components on current host in reverse order

./wls-service-control.sh stop-all

# Force stop all components (ignores graceful logic)

./wls-service-control.sh force-stop-all

# Check all components' status

./wls-service-control.sh status-all

```

#### Maintenance Operations

```bash

# Create runtime/PID directories (run as root)

./wls-service-control.sh setup

# Remove runtime/PID directories (run as root)

./wls-service-control.sh clean

```

---

 
### wls-service-setup.sh <a name="wls-service-setupsh"></a>

Systemd integration script for service file generation and management.

```bash

# Install systemd service units

./wls-service-setup.sh setup

# Remove systemd service units

./wls-service-setup.sh clean

# List all installed wls-*.service files

./wls-service-setup.sh list

```

**Generated Service Naming Convention:**

- `wls-<Domain>@<ComponentKey>.service`

- `wls-<Domain>-target.service`

---

## Installation & Setup <a name="installation--setup"></a>

1. **Create product directory**:

```bash

export DOMAIN_HOME=<SET_TO_YOUR_WLS_DOMAIN_HOME>

mkdir $DOMAIN_HOME/initpilot

chown oracle:oinstall $DOMAIN_HOME/initpilot

```

2. **Copy Files to Product Directory**:

Product files are available at this link:

`https://github.com/soporenet/initpilot`
 
Once downloaded and transfered to AdminServer node, copy as:

```bash

cp wls-service-*.sh wls-service-config.json $DOMAIN_HOME/initpilot/

chmod 750 $DOMAIN_HOME/initpilot/*.sh

chown oracle:oinstall $DOMAIN_HOME/initpilot/*

```

3. **Configure Truststore (for SSL environments, for example if WebLogic Domain Wide Administration port is enabled)**:

```bash

$DOMAIN_HOME/initpilot/wls-import-truststore.sh

```

4. **Security Configuration**:
 
- Create a user, say `monitor`, in WebLogic Default Authenticator. Add this user to `Monitors` group.

- Create credential files of the monitor user:

```python

su - oracle

/u01/oracle/products/wls1412/oracle_common/common/bin/wlst.sh

connect('monitor','<REPLACE_BY_ACTUAL_PASSOWRD>','t3://lnxwls1.sopore.net:18001')

storeUserConfig('/home/oracle/wls-monitor.config', '/home/oracle/wls-monitor.key')

exit()

```

- Create NodeManager user credential files:

```python

su - oracle

/u01/oracle/products/wls1412/oracle_common/common/bin/wlst.sh

connect('monitor','<REPLACE_BY_ACTUAL_PASSOWRD>','t3://lnxwls1.sopore.net:18001')

nmConnect('nmadmin', '<REPLACE_BY_ACTUAL_PASSOWRD>', 'lnxwls1.sopore.net', '15556', 'TestDomain2', '/u01/oracle/products/wls1412/user_projects/domains/TestDomain2','plain','60')

storeUserConfig(userConfigFile='/home/oracle/wls-nmadmin.config', userKeyFile='/home/oracle/wls-nmadmin.key', nm='true')

exit()

```

- Update permissions on credential files:

```bash

chmod 600 /home/oracle/*.config  /home/oracle/*.key

```
 
5. **Edit the Configuration File to match your environment**:

```bash

vi $DOMAIN_HOME/initpilot/wls-service-config.json

```

6. **Distribute Configuration, Scripts, and Credentials to Other Nodes**

If your WebLogic domain spans multiple nodes, replicate the `initpilot` directory to all other WebLogic hosts:
 
 
    ##### What to Copy from AdminServer node:
 
 
    &nbsp; Full contents of `$DOMAIN_HOME/initpilot` (`*.sh`,`wls-service-config.json`, `*.jks`)
 
    &nbsp; Credential files generated under `/home/oracle` (`*.config`, `*.key`)
 
 
    ##### Transfer Example
 
    ```bash

    rsync -avz $DOMAIN_HOME/initpilot/ oracle@<target-host>:$DOMAIN_HOME/initpilot/

    ```
 
    ##### Post-transfer on Each Node
 
    ```bash

    chown oracle:oinstall -R $DOMAIN_HOME/initpilot/

    chmod 750 $DOMAIN_HOME/initpilot/*.sh

    chmod 600 /home/oracle/*.config/home/oracle/*.key

    ```

7. **Initialize Services**:

On each Node:

```bash

# As root user (for system directories)

$DOMAIN_HOME/initpilot/wls-service-control.sh setup

# As root user (for systemd setup)

$DOMAIN_HOME/initpilot/wls-service-setup.sh setup

```

---

## Operation & Management <a name="operation--management"></a>

### Component Control <a name="component-control"></a>

**Note:** Component control script `wls-service-control.sh` should be strictly always run as `oracle` user
 
**Start AdminServer (AS):**

```bash

./wls-service-control.sh start AS

# Output:

# 2025-07-01 12:00:00|INFO|AS|Start requested

# 2025-07-01 12:00:05|SUCCESS|AS|Reached status: RUNNING in 5s

```

**Stop a Managed Server:**

```bash

./wls-service-control.sh stop MS1

```

**Check NodeManager Status:**

```bash

./wls-service-control.sh status NM1

# Output:

# 2025-07-01 12:05:00|INFO|NM1|Status: RUNNING

```

---

### Domain-wide Operations <a name="domain-wide-operations"></a>

**Note:** Component control script `wls-service-control.sh` should be strictly always run as `oracle` user
 
**Start All Components:**

```bash

./wls-service-control.sh start-all

# Order:

# 1. NM1 (NodeManager)

# 2. AS (AdminServer)

# 3. MS1, MS2 (in configured order)

```

**Status Check for All Components:**

```bash

./wls-service-control.sh status-all

# Sample output:

# 2025-07-01 12:10:00|INFO|SCRIPT|Status of all components on lnxwls1.sopore.net:

# 2025-07-01 12:10:00|INFO|NM1|Status: RUNNING

# 2025-07-01 12:10:01|INFO|AS|Status: RUNNING

# 2025-07-01 12:10:02|INFO|MS1|Status: RUNNING

```

---

### Systemd Service Management <a name="systemd-service-management"></a>
 
**Note:** Depending on your organization's security policies, systemctl commands can be executed either directly as `root` or by the `oracle` user if it has appropriate sudo privileges. Regardless of who runs the command, the WebLogic processes will run under the `oracle:oinstall` account, as defined by the `User=` and `Group=` directives in the systemd service unit files.
 
```bash

# Start AdminServer via systemd

systemctl start wls-TestDomain2@AS

# Enable ManagedServer auto-start at boot

systemctl enable wls-TestDomain2@MS1

# Check NodeManager status via systemd

systemctl status wls-TestDomain2@NM1

# Output:

# ● wls-TestDomain2@NM1.service - WebLogic NodeManager NM1 for domain TestDomain2

#    Loaded: loaded (/usr/lib/systemd/system/wls-TestDomain2@NM1.service; enabled)

#    Active: active (running) since Sat 2025-07-05 08:00:01 IST; 5min ago

```

---

## Troubleshooting <a name="troubleshooting"></a>

### Common Issues

1. **Port Conflicts**  

   Use the following commands to check if the required ports are already in use:

   ```bash

   netstat -tulnp | grep <PORT>

   firewall-cmd --list-ports

   ```

2. **SSL Configuration Errors**  

   - Confirm the truststore path set in `wls-service-config.json` under `Security.trust_jks_file`.

   - Ensure correct permissions on JKS and key files.

   - Validate credentials stored in monitor and NodeManager config/key files.

3. **Component Startup Failures**  

   Review both WLST logs and systemd logs to diagnose failures:

   ```bash

   tail -n 100 $DOMAIN_HOME/initpilot/logs/wls-service.log

   journalctl -u wls-<Domain>@<ComponentKey>

   ```

---

### Log Analysis

Log entries follow a structured pipe-delimited format:

```

TIMESTAMP|SEVERITY|COMPONENT|MESSAGE

```

**Example Error Log**:

```log

2025-07-01 12:00:03|ERROR|AS|CRITICAL: Trust JKS file '/invalid/path/trust.jks' does not exist

```

---

### Diagnostic Commands

```bash

# Check if a WebLogic component is running

ps -ef | grep -i "weblogic.Name=AS"

# Test TCP connectivity to Admin/Managed Server ports

nc -zv localhost 18001

# Validate your JSON configuration syntax

jq . $DOMAIN_HOME/initpilot/wls-service-config.json

```

---
 
## SELinux Configuration <a name="selinux-config"></a>
 
If SELinux is enabled and set to enforcing, it may block execution or logging actions - especially when invoked via systemd. These issues can vary by environment and SELinux policy.
 
`Note`: In production or sensitive test environments, it is recommended to audit SELinux denials (/var/log/audit/audit.log) and generate a custom allow policy. That process is out of scope for this guide.
 
The following steps provide a quick workaround to apply necessary SELinux contexts:
 
1. **If you don’t have semanage, install it:**
 
```bash

dnf install policycoreutils-python-utils

```
 
2. **Add SELinux Context for Control script:**
 
```bash

semanage fcontext -a -t bin_t "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/wls-service-control.sh"

restorecon -v "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/wls-service-control.sh"

```
 
 
3. **Add SELinux Context for JSON configuration file:**
 
```bash

semanage fcontext -a -t etc_t "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/wls-service-config.json"

restorecon -v "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/wls-service-config.json"

```
 
4. **Add SELinux Context for Log directory:**
 
```bash

semanage fcontext -a -t var_log_t "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/logs(/.*)?"

restorecon -Rv "/u01/oracle/products/wls1412/user_projects/domains/TestDomain2/initpilot/logs"

```
 
If issues persist, custom SELinux policy tuning will be required - consult audit logs (ausearch -m avc) for further investigation.
 
---
 
## Uninstallation <a name="uninstallation"></a>

To fully remove the integration:

1. **Stop all WebLogic components**:

   ```bash

   ./wls-service-control.sh force-stop-all

   ```

2. **Remove systemd unit files** (as root):

   ```bash

   ./wls-service-setup.sh clean

   ```

3. **Clean runtime and PID directories (as root)**:

   ```bash

   ./wls-service-control.sh clean

   ```

4. **Delete all configuration and control files**:

   ```bash

   cd $DOMAIN_HOME

   rm -rf ./initpilot

   ```

---
 
 
