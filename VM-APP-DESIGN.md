# VMBOX - Application Framework Design

This document describes the architecture for deploying applications to the VMBOX framework. Use this as a reference when creating new applications that integrate with the VMBOX framework.

## Table of Contents

1. [Partition Layout](#partition-layout)
2. [Directory Structure](#directory-structure)
3. [Application Manifest](#application-manifest)
4. [packages.txt Format](#packagestxt-format)
5. [Build Process](#build-process)
6. [Runtime Behavior](#runtime-behavior)
7. [App Manager Service](#app-manager-service)
8. [Health Monitoring](#health-monitoring)
9. [Logging](#logging)
10. [WebUI Integration](#webui-integration)
11. [UI Design System](#ui-design-system)
12. [Creating a New Application](#creating-a-new-application)
13. [CMake Integration](#cmake-integration)
14. [Common Pitfalls and Troubleshooting](#common-pitfalls-and-troubleshooting)

---

## Partition Layout

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Disk Layout (MBR/BIOS)                                                  │
│  ┌──────────┬──────────────┬─────────────────┬────────────────────────┐  │
│  │ BOOT     │ ROOTFS       │ DATA            │ APP                    │  │
│  │ (FAT32)  │ (SquashFS)   │ (ext4)          │ (SquashFS)             │  │
│  │ 64MB     │ 500MB        │ configurable    │ configurable           │  │
│  │ ro       │ ro           │ rw              │ ro                     │  │
│  │ /dev/sda1│ /dev/sda2    │ /dev/sda3       │ /dev/sda4              │  │
│  └──────────┴──────────────┴─────────────────┴────────────────────────┘  │
│                                                                          │
│  Partition Order Rationale:                                              │
│  - BOOT/ROOTFS: Fixed size, immutable, at known locations                │
│  - DATA: User data, can be sized at build time                           │
│  - APP: At END so it can be extended by growing the disk                 │
└──────────────────────────────────────────────────────────────────────────┘
```

### Partition Details

| Partition | Device | Filesystem | Mount | Mode | Purpose |
|-----------|--------|------------|-------|------|---------|
| BOOT | /dev/sda1 | FAT32 | /boot | ro | Bootloader, kernel, initramfs |
| ROOTFS | /dev/sda2 | SquashFS | (overlay) | ro | Alpine base + system-mgmt |
| DATA | /dev/sda3 | ext4 | /data | rw | User data, configs, overlay |
| APP | /dev/sda4 | SquashFS | /app | ro | Applications from packages.txt |

### Why APP is Last

1. **Extensibility**: Grow disk and extend APP partition without moving others
2. **Stability**: BOOT/ROOTFS/DATA stay at fixed disk offsets
3. **Upgrades**: Replace APP partition image without touching user data
4. **Optional**: Base images can omit APP partition entirely

---

## Directory Structure

### Build-Time Structure (in APP partition)

```
/app/                              # APP partition mount point (read-only)
├── manifest.json                  # Global app registry
├── startup.d/                     # Startup scripts (ordered by filename)
│   ├── 10-database.sh
│   ├── 15-helper.sh
│   └── 20-webapp1.sh
├── shutdown.d/                    # Shutdown scripts (reverse order)
│   ├── 10-webapp1.sh
│   ├── 15-helper.sh
│   └── 20-database.sh
│
├── webapp1/                       # Application directory
│   ├── manifest.json              # App-specific manifest
│   ├── bin/                       # Executables
│   │   └── webapp1-server
│   ├── lib/                       # Libraries
│   ├── share/                     # Static assets (HTML, CSS, JS)
│   │   └── www/
│   └── etc/                       # Default configs (read-only templates)
│       └── config.json.default
│
├── database/
│   ├── manifest.json
│   ├── bin/
│   └── ...
│
└── helper/                        # Background service (no web UI)
    ├── manifest.json
    ├── bin/
    └── ...
```

### Runtime Structure (in DATA partition)

```
/data/                             # DATA partition mount point (read-write)
├── overlay/                       # OverlayFS for rootfs modifications
│   ├── upper/
│   └── work/
│
├── app-data/                      # Application runtime data
│   ├── webapp1/                   # Per-app writable directory
│   │   ├── db/                    # Databases
│   │   ├── uploads/               # User uploads
│   │   └── cache/                 # Cache files
│   ├── database/
│   │   └── data/                  # Database files
│   └── helper/
│       └── state/
│
├── app-config/                    # User configuration overrides
│   ├── webapp1/
│   │   └── config.json            # User-modified config
│   └── database/
│       └── settings.conf
│
├── home/                          # User home directories
│   └── admin/
│
└── var/                           # Variable data (logs, etc.)
    └── log/
        └── app/                   # Per-app log files
            ├── webapp1.log
            ├── database.log
            └── helper.log
```

### Runtime Directory (tmpfs)

```
/run/                              # tmpfs, cleared on reboot
└── app/                           # App manager runtime
    ├── app-manager.pid            # App manager PID
    ├── webapp1.pid                # Per-app PID files
    ├── database.pid
    └── helper.pid
```

---

## Application Manifest

### Global Manifest (`/app/manifest.json`)

Created during build, contains registry of all installed apps:

```json
{
  "version": "1.0.0",
  "build_date": "2025-01-15T10:30:00Z",
  "build_host": "build-server",
  "apps": [
    "database",
    "helper",
    "webapp1"
  ],
  "startup_order": [
    "database",
    "helper",
    "webapp1"
  ]
}
```

### Per-App Manifest (`/app/<appname>/manifest.json`)

Each application must include a manifest describing its requirements:

```json
{
  "name": "webapp1",
  "version": "1.0.0",
  "description": "Example Web Application",
  "type": "webapp",

  "port": 8001,
  "url": "/",

  "health": {
    "type": "http",
    "endpoint": "/health",
    "port": 8001,
    "interval": 10,
    "timeout": 5
  },

  "startup": {
    "command": "/app/webapp1/bin/webapp1-server",
    "args": ["--config", "/data/app-config/webapp1/config.json"],
    "working_dir": "/app/webapp1",
    "priority": 20,
    "depends_on": ["database"]
  },

  "shutdown": {
    "timeout": 30,
    "signal": "SIGTERM"
  },

  "data_dirs": [
    "db",
    "uploads",
    "cache"
  ],

  "config_files": [
    {
      "source": "etc/config.json.default",
      "dest": "config.json"
    }
  ],

  "env": {
    "APP_DATA_DIR": "/data/app-data/webapp1",
    "APP_CONFIG_DIR": "/data/app-config/webapp1",
    "APP_LOG_FILE": "/var/log/app/webapp1.log"
  },

  "logging": {
    "file": "/var/log/app/webapp1.log",
    "syslog_tag": "app.webapp1",
    "max_size_mb": 10,
    "rotate_count": 3
  }
}
```

### Manifest Fields Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique application identifier |
| `version` | Yes | Semantic version string |
| `description` | Yes | Human-readable description |
| `type` | Yes | `webapp` (has UI) or `service` (background) |
| `port` | No | Network port (0 or omit for no network) |
| `url` | No | URL path for web apps (default: `/`) |
| `health` | No | Health check configuration |
| `startup` | Yes | Startup configuration |
| `shutdown` | No | Shutdown configuration (defaults provided) |
| `data_dirs` | No | Directories to create in app-data |
| `config_files` | No | Config files to copy on first run |
| `env` | No | Environment variables for the process |
| `logging` | No | Logging configuration |

### Health Check Types

```json
// HTTP health check (recommended for web apps)
"health": {
  "type": "http",
  "endpoint": "/health",
  "port": 8001,
  "interval": 10,
  "timeout": 5,
  "expected_status": 200
}

// TCP port check (for databases, services)
"health": {
  "type": "tcp",
  "port": 5432,
  "interval": 10,
  "timeout": 5
}

// Process check (simplest, just checks if running)
"health": {
  "type": "process",
  "interval": 10
}

// Custom script
"health": {
  "type": "script",
  "command": "/app/myapp/bin/healthcheck.sh",
  "interval": 10,
  "timeout": 5
}
```

---

## packages.txt Format

The `packages.txt` file defines applications to build and install:

```
# VirtualBox Alpine VM - Application Packages
#
# Format: NAME|GIT_REPO|VERSION|CMAKE_OPTIONS|BUILD_DEPS|PORT|PRIORITY|TYPE|DESCRIPTION
#
# Fields:
#   NAME         - Unique app identifier (alphanumeric, lowercase)
#   GIT_REPO     - Git URL or local path (prefix with file:// for local)
#   VERSION      - Git tag, branch, or commit (use HEAD for latest)
#   CMAKE_OPTIONS- CMake options (comma-separated, no spaces)
#   BUILD_DEPS   - Build-time Alpine packages (comma-separated)
#   PORT         - Network port (0 for none)
#   PRIORITY     - Startup priority (10-90, lower = starts first)
#   TYPE         - webapp or service
#   DESCRIPTION  - Human-readable description
#
# Lines starting with # are comments
# Empty lines are ignored

# Database service (starts first)
database|https://github.com/example/embedded-db|v2.0.0||cmake,gcc|5432|10|service|Embedded Database

# Background helper service
helper|file:///path/to/local/helper|HEAD||make|0|15|service|Background Helper

# Main web application
webapp1|https://github.com/example/webapp1|v1.0.0|-DWITH_SSL=ON|cmake,gcc,openssl-dev|8001|20|webapp|Example Web App

# Another web app depending on database
webapp2|https://github.com/example/webapp2|v1.5.0||cmake,nodejs|8002|25|webapp|Second Web App
```

### Field Details

| Field | Format | Example | Notes |
|-------|--------|---------|-------|
| NAME | `[a-z0-9-]+` | `webapp1` | Used for directories, must be unique |
| GIT_REPO | URL or path | `https://...` or `file://...` | |
| VERSION | string | `v1.0.0`, `main`, `HEAD` | Git ref |
| CMAKE_OPTIONS | comma-sep | `-DOPT1=ON,-DOPT2=OFF` | No spaces |
| BUILD_DEPS | comma-sep | `cmake,gcc,make` | Alpine packages |
| PORT | integer | `8001` | 0 for no port |
| PRIORITY | 10-90 | `20` | Lower = earlier startup |
| TYPE | enum | `webapp` or `service` | |
| DESCRIPTION | string | `My App` | For display in UI |

---

## Build Process

### Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Build Pipeline                                                          │
│                                                                          │
│  packages.txt ──┐                                                        │
│                 │                                                        │
│                 ▼                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  02-build-packages.sh                                            │    │
│  │                                                                  │    │
│  │  For each package:                                               │    │
│  │  1. Parse packages.txt entry                                     │    │
│  │  2. Clone/copy source to build dir                               │    │
│  │  3. Install build dependencies (apk add)                         │    │
│  │  4. Run cmake -DCMAKE_INSTALL_PREFIX=/app/<name>                 │    │
│  │  5. Build: make -j$(nproc)                                       │    │
│  │  6. Install: make install DESTDIR=${APP_STAGING}                 │    │
│  │  7. Generate manifest.json from template + packages.txt          │    │
│  │  8. Generate startup.d/XX-<name>.sh                              │    │
│  │  9. Generate shutdown.d/XX-<name>.sh                             │    │
│  │  10. Cleanup build deps (apk del)                                │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                 │                                                        │
│                 ▼                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  APP Staging Directory                                           │    │
│  │  /tmp/app-staging/                                               │    │
│  │  └── app/                                                        │    │
│  │      ├── manifest.json                                           │    │
│  │      ├── startup.d/                                              │    │
│  │      ├── shutdown.d/                                             │    │
│  │      ├── webapp1/                                                │    │
│  │      └── database/                                               │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                 │                                                        │
│                 ▼                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  03-create-image.sh                                              │    │
│  │                                                                  │    │
│  │  1. Create disk image with 4 partitions                          │    │
│  │  2. mksquashfs app-staging → APP partition                       │    │
│  │  3. Initialize DATA partition structure                          │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                 │                                                        │
│                 ▼                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐    │
│  │  04-convert-to-vbox.sh                                           │    │
│  │                                                                  │    │
│  │  1. Read /app/manifest.json from image                           │    │
│  │  2. Auto-configure port forwarding for all apps                  │    │
│  │  3. Create VirtualBox VM                                         │    │
│  └──────────────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────────┘
```

### Build Command

```bash
# Build with apps
sudo ./build.sh \
    --mode=full \
    --output=/tmp/alpine-build \
    --version=1.0.0 \
    --packages=packages.txt \
    --apppart=500M

# Build base image only (no APP partition)
sudo ./build.sh \
    --mode=base \
    --output=/tmp/alpine-build \
    --version=1.0.0
```

### Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--mode` | required | `base` (no apps) or `full` (with apps) |
| `--packages` | packages.txt | Path to packages.txt file |
| `--apppart` | auto | APP partition size (auto-calculated if omitted) |
| `--ospart` | 500M | ROOTFS partition size |
| `--datapart` | 1024M | DATA partition size |

---

## Runtime Behavior

### Boot Sequence

```
1. BIOS → Syslinux bootloader
2. Load kernel + initramfs
3. initramfs init script:
   a. Mount /dev/sda2 (ROOTFS) as SquashFS (ro)
   b. Mount /dev/sda3 (DATA) as ext4 (rw)
   c. Create OverlayFS: ROOTFS + DATA/overlay → /
   d. Mount /dev/sda4 (APP) as SquashFS at /app (ro)
   e. switch_root to merged filesystem
4. OpenRC init
5. System services start
6. app-manager service starts:
   a. Read /app/manifest.json
   b. Create /data/app-data/<name>/ directories
   c. Copy default configs to /data/app-config/<name>/
   d. Execute /app/startup.d/*.sh in order
   e. Start health monitoring loop
7. System ready
```

### Shutdown Sequence

```
1. System shutdown initiated (reboot/poweroff)
2. OpenRC stops services in reverse order
3. app-manager receives stop signal:
   a. Read shutdown order from manifest
   b. For each app (reverse startup order):
      i.   Log "Stopping <appname>..."
      ii.  Send SIGTERM to process
      iii. Wait up to timeout seconds
      iv.  If still running, send SIGKILL
      v.   Log result
   c. All apps stopped
4. app-manager exits
5. System unmounts filesystems
6. Power off / Reboot
```

### Process Management

Each app runs as a separate process managed by app-manager:

```
app-manager (PID 1234)
├── webapp1 (PID 2345)
├── database (PID 2346)
└── helper (PID 2347)

PID files: /run/app/<appname>.pid
```

---

## App Manager Service

### OpenRC Service Script

Location: `/etc/init.d/app-manager`

```bash
#!/sbin/openrc-run

name="app-manager"
description="Application Manager Service"
command="/opt/app-manager/app-manager"
command_args="--manifest /app/manifest.json"
command_background=true
pidfile="/run/app/app-manager.pid"
output_log="/var/log/app-manager.log"
error_log="/var/log/app-manager.log"

depend() {
    need net localmount
    after firewall
}

start_pre() {
    mkdir -p /run/app
    mkdir -p /var/log/app
    mkdir -p /data/app-data
    mkdir -p /data/app-config
}
```

### App Manager Responsibilities

1. **Startup**: Execute startup scripts in order
2. **Health Monitoring**: Check app health every N seconds
3. **Process Tracking**: Maintain PID files, detect crashes
4. **API**: Expose control socket for WebUI integration
5. **Shutdown**: Graceful shutdown of all apps
6. **Logging**: Aggregate app status to syslog

### Control Socket API

Unix socket at `/run/app/app-manager.sock`:

```
GET /apps                    → List all apps with status
GET /apps/<name>             → Single app details
POST /apps/<name>/start      → Start app
POST /apps/<name>/stop       → Stop app (graceful)
POST /apps/<name>/restart    → Restart app
GET /apps/<name>/health      → Health check result
```

---

## Health Monitoring

### Health Check Flow

```
┌──────────────────────────────────────────────────────────────────┐
│  Health Monitor Loop (every 10 seconds)                          │
│                                                                  │
│  For each app:                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ 1. Check if process is running (PID file + kill -0)         │ │
│  │    └── If not running → status = "stopped"                  │ │
│  │                                                             │ │
│  │ 2. If running, perform health check based on type:          │ │
│  │    ├── http: GET http://localhost:PORT/ENDPOINT             │ │
│  │    ├── tcp: Connect to PORT                                 │ │
│  │    ├── process: Just check if running (done in step 1)      │ │
│  │    └── script: Execute custom health script                 │ │
│  │                                                             │ │
│  │ 3. Update status:                                           │ │
│  │    ├── "running" - Process running, health OK               │ │
│  │    ├── "unhealthy" - Process running, health failed         │ │
│  │    ├── "stopped" - Process not running                      │ │
│  │    └── "starting" - Recently started, waiting for health    │ │
│  │                                                             │ │
│  │ 4. Record metrics:                                          │ │
│  │    ├── Last check time                                      │ │
│  │    ├── Response time (for http/tcp)                         │ │
│  │    ├── Consecutive failures                                 │ │
│  │    └── Uptime                                               │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Status Values

| Status | Description | UI Color |
|--------|-------------|----------|
| `running` | Process running, health OK | Green |
| `unhealthy` | Process running, health check failed | Yellow |
| `stopped` | Process not running | Gray |
| `starting` | Recently started, pending health check | Blue |
| `failed` | Failed to start or crashed | Red |

---

## Logging

### Log File Locations

| Log | Path | Description |
|-----|------|-------------|
| App Manager | `/var/log/app-manager.log` | App manager service log |
| Per-App | `/var/log/app/<appname>.log` | Individual app stdout/stderr |
| System | `/var/log/messages` | Syslog (includes app.* tags) |

### Log Format

App logs use structured format:
```
2025-01-15T10:30:00Z [INFO] webapp1: Server started on port 8001
2025-01-15T10:30:05Z [INFO] webapp1: Health check passed (12ms)
2025-01-15T10:31:00Z [WARN] webapp1: High memory usage: 85%
```

### Syslog Integration

Apps can also log to syslog with tags:
```bash
logger -t "app.webapp1" "Application started"
```

### Log Rotation

Configured in manifest:
```json
"logging": {
  "file": "/var/log/app/webapp1.log",
  "max_size_mb": 10,
  "rotate_count": 3
}
```

### Log Management (WebUI)

The system-mgmt dashboard provides log management features:

| Action | Description | Implementation |
|--------|-------------|----------------|
| **Clear View** | Clear display only | JavaScript: clear the log content div |
| **Clear Log** | Truncate selected log file | `POST /api/logs/<id>/clear` - truncates file (keeps handle valid) |
| **Clear All** | Truncate all log files | `POST /api/logs/clear-all` - truncates all + `dmesg --clear` |
| **Download All** | Download logs as ZIP | `GET /api/logs/download` - timestamped ZIP file |

**Important**: Use file truncation (`open(path, 'w').close()`) not deletion. Running apps hold open file handles - deleting the file causes them to write to a deleted inode.

**Kernel Messages (dmesg)**: Cannot be truncated like regular files. Use `dmesg --clear` command (requires root).

```python
# Clearing a regular log file
open(log_path, 'w').close()  # Truncate - keeps file handle valid

# Clearing kernel ring buffer
subprocess.run(['dmesg', '--clear'], timeout=5)
```

---

## WebUI Integration

### Applications Panel in Dashboard

The system-mgmt WebUI displays an "Applications" panel:

```
┌─────────────────────────────────────────────────────────────────────────┐
│  Applications                                               [Refresh]   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ ● webapp1           v1.0.0    :8001    Running     [Open][↻][■]   │  │
│  │   Health: OK (8ms)            Uptime: 2h 15m       Mem: 45MB      │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ ● database          v2.0.0    :5432    Running          [↻][■]    │  │
│  │   Health: OK                  Uptime: 2h 15m       Mem: 128MB     │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ ○ helper            v1.0.0    --       Stopped     [▶]      [■]   │  │
│  │   Health: N/A                 Last: 5m ago                        │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                         │
│  Legend: ● Running  ○ Stopped  ◐ Starting  ⚠ Unhealthy                 │
│  Actions: [Open] Open UI  [▶] Start  [↻] Restart  [■] Stop             │
└─────────────────────────────────────────────────────────────────────────┘
```

### API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/apps` | GET | List all apps with full status |
| `/api/apps/<name>` | GET | Single app details |
| `/api/apps/<name>/start` | POST | Start an app |
| `/api/apps/<name>/stop` | POST | Stop an app (graceful) |
| `/api/apps/<name>/restart` | POST | Restart an app |
| `/api/apps/<name>/logs` | GET | Get app log (params: lines, search) |

### App Status Response

```json
{
  "apps": [
    {
      "name": "webapp1",
      "version": "1.0.0",
      "description": "Example Web App",
      "type": "webapp",
      "port": 8001,
      "url": "http://localhost:8001/",
      "status": "running",
      "health": {
        "status": "healthy",
        "last_check": "2025-01-15T10:30:00Z",
        "response_time_ms": 8,
        "consecutive_failures": 0
      },
      "uptime_seconds": 8100,
      "uptime_human": "2h 15m",
      "memory_bytes": 47185920,
      "memory_human": "45.0 MB",
      "pid": 2345
    }
  ]
}
```

### Opening App UI

For apps with `type: "webapp"`, the dashboard shows an "Open" button that:
1. Opens `/app/<name>/` in a new browser tab (through reverse proxy)
2. Authentication is enforced - user must be logged into system-mgmt
3. All requests are proxied through system-mgmt to `localhost:<port>/`

### Authenticated App Proxy

All webapp access goes through the system-mgmt reverse proxy:

```
User Browser                    System-Mgmt (port 8000)           App (internal port)
     │                                    │                              │
     │  GET /app/hello-world/             │                              │
     ├───────────────────────────────────>│                              │
     │                                    │  Check session cookie        │
     │                                    │  (redirect to login if       │
     │                                    │   not authenticated)         │
     │                                    │                              │
     │                                    │  GET http://127.0.0.1:8002/  │
     │                                    ├─────────────────────────────>│
     │                                    │                              │
     │                                    │  <html>...</html>            │
     │                                    │<─────────────────────────────┤
     │  <html>...</html>                  │                              │
     │<───────────────────────────────────┤                              │
```

**Benefits**:
- Single entry point (port 8000 only)
- Centralized authentication
- Apps don't need their own auth code
- Simpler firewall/port forwarding rules

**Proxy Endpoints**:
| Route | Description |
|-------|-------------|
| `/app/<name>/` | Proxied to app's root path |
| `/app/<name>/<path>` | Proxied to app's `/<path>` |

### WebSocket Authentication

WebSocket connections cannot go through the HTTP proxy. For apps that need WebSocket (like real-time terminals), use token-based authentication:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  WebSocket Authentication Flow                                           │
│                                                                          │
│  1. Client (via proxy)     →  POST /api/session/token                    │
│                            ←  {"token": "abc123...", "expires_in": 60}   │
│                                                                          │
│  2. Client (direct)        →  ws://host:8003/ws?token=abc123...          │
│     App validates token    →  POST http://localhost:8000/api/session/validate-token  │
│                            ←  {"valid": true, "username": "admin"}       │
│                                                                          │
│  3. WebSocket connected and authenticated                                │
└──────────────────────────────────────────────────────────────────────────┘
```

**Session Endpoints for Apps**:
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/session/check` | GET | Check if current session is valid |
| `/api/session/token` | POST | Get a short-lived token (60s) for WebSocket auth |
| `/api/session/validate-token` | POST | Validate a WebSocket auth token (reusable within validity period) |

**JavaScript Example** (in app frontend):
```javascript
// Before connecting WebSocket, get a token via the authenticated proxy
async function connectWebSocket() {
    // 1. Get auth token (via proxy - session cookie sent automatically)
    const tokenResp = await fetch(getBasePath() + 'api/session/token', { method: 'POST' });
    const { token } = await tokenResp.json();

    // 2. Connect WebSocket directly to app with token
    const wsUrl = `ws://${window.location.hostname}:8003/ws?token=${token}`;
    const ws = new WebSocket(wsUrl);
    // ...
}
```

**Python Example** (in app backend):
```python
def validate_ws_token(token):
    """Validate WebSocket auth token with system-mgmt."""
    try:
        resp = requests.post(
            'http://localhost:8000/api/session/validate-token',
            json={'token': token},
            timeout=5
        )
        data = resp.json()
        return data.get('valid', False), data.get('username')
    except:
        return False, None
```

### WebSocket Message Parsing Gotcha

When mixing JSON control messages with raw data on the same WebSocket (e.g., terminal apps), be careful with JSON parsing:

**Problem**: Single digits like "2" are valid JSON literals. `json.loads("2")` returns `2` (an integer), not a dict. Calling `.get('type')` on an integer throws an error.

**Solution (Python)**:
```python
try:
    msg = json.loads(message)
    # Must be a dict with 'type' field to be a control message
    if not isinstance(msg, dict):
        raise ValueError("Not a control message")
    msg_type = msg.get('type')
    # ... handle control messages
except (json.JSONDecodeError, ValueError):
    # Raw terminal input - send to serial port
    serial_connection.write(message.encode('utf-8'))
```

**Solution (JavaScript)**:
```javascript
ws.onmessage = (event) => {
    try {
        const msg = JSON.parse(event.data);
        // Must be an object with 'type' to be a control message
        if (msg && typeof msg === 'object' && msg.type) {
            handleControlMessage(msg);
        } else {
            // Valid JSON but not control - treat as raw data
            terminal.write(event.data);
        }
    } catch (e) {
        terminal.write(event.data);
    }
};
```

---

## UI Design System

All applications integrated with this framework should follow the system-mgmt UI design for visual consistency. This section documents the design tokens, color palette, typography, and component styles.

### Design Tokens (CSS Variables)

Include these CSS variables at the root of your application:

```css
:root {
    /* Background Colors */
    --bg-primary: #1a1a2e;        /* Main page background */
    --bg-card: #16213e;           /* Card/panel background */
    --bg-secondary: #1f3460;      /* Secondary elements, inputs */
    --bg-tertiary: #0d1421;       /* Code blocks, log viewers */

    /* Accent Colors */
    --accent-primary: #667eea;    /* Primary accent (purple-blue) */
    --accent-secondary: #764ba2;  /* Secondary accent (purple) */
    --gradient-primary: linear-gradient(135deg, #667eea 0%, #764ba2 100%);

    /* Text Colors */
    --text-primary: #eee;         /* Primary text */
    --text-secondary: #888;       /* Secondary/muted text */
    --text-disabled: #555;        /* Disabled/placeholder text */

    /* Border Colors */
    --border-primary: #1f3460;    /* Default borders */
    --border-focus: #667eea;      /* Focused input borders */
    --border-input: #2a4a8a;      /* Input field borders */

    /* Status Colors */
    --status-success: #51cf66;    /* Success, online, healthy */
    --status-warning: #ffa94d;    /* Warning, degraded */
    --status-error: #ff6b6b;      /* Error, offline, unhealthy */
    --status-error-dark: #c92a2a; /* Danger buttons, critical */

    /* Semantic Colors */
    --color-rx: #51cf66;          /* Network receive (green) */
    --color-tx: #ffa94d;          /* Network transmit (orange) */
    --color-highlight: #ffd700;   /* Search highlight (gold) */

    /* Typography */
    --font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
    --font-mono: 'Monaco', 'Menlo', 'Consolas', monospace;
    --line-height: 1.6;

    /* Spacing */
    --spacing-xs: 5px;
    --spacing-sm: 10px;
    --spacing-md: 15px;
    --spacing-lg: 20px;
    --spacing-xl: 30px;

    /* Border Radius */
    --radius-sm: 4px;
    --radius-md: 6px;
    --radius-lg: 8px;
    --radius-xl: 12px;

    /* Transitions */
    --transition-fast: 0.2s ease;
    --transition-normal: 0.3s ease;
    --transition-slow: 0.5s ease;
}
```

### Color Palette Reference

| Token | Hex | Usage |
|-------|-----|-------|
| `--bg-primary` | `#1a1a2e` | Page background |
| `--bg-card` | `#16213e` | Card backgrounds, modals |
| `--bg-secondary` | `#1f3460` | Input backgrounds, secondary panels |
| `--bg-tertiary` | `#0d1421` | Code blocks, log content |
| `--accent-primary` | `#667eea` | Primary buttons, links, highlights |
| `--accent-secondary` | `#764ba2` | Gradient endpoints, hover states |
| `--text-primary` | `#eee` | Main body text |
| `--text-secondary` | `#888` | Labels, descriptions, muted text |
| `--text-disabled` | `#555` | Placeholder text, disabled items |
| `--status-success` | `#51cf66` | Success states, online indicators |
| `--status-warning` | `#ffa94d` | Warning states, TX traffic |
| `--status-error` | `#ff6b6b` | Error states, danger buttons |

### Typography

```css
/* Base styles */
body {
    font-family: var(--font-family);
    color: var(--text-primary);
    line-height: var(--line-height);
    background-color: var(--bg-primary);
}

/* Headings */
h1 { font-size: 1.8em; margin-bottom: 5px; }
h2 {
    font-size: 1em;
    color: var(--accent-primary);
    text-transform: uppercase;
    letter-spacing: 1px;
}

/* Monospace (for data values, logs, code) */
.stat-value, .log-content, code {
    font-family: var(--font-mono);
}
```

### Component Styles

#### Cards

```css
.card {
    background: var(--bg-card);
    border-radius: var(--radius-xl);
    padding: var(--spacing-lg);
    box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
    border: 1px solid var(--border-primary);
}

.card h2 {
    font-size: 1em;
    color: var(--accent-primary);
    margin-bottom: var(--spacing-md);
    padding-bottom: var(--spacing-sm);
    border-bottom: 1px solid var(--border-primary);
    text-transform: uppercase;
    letter-spacing: 1px;
}
```

#### Buttons

```css
/* Base button */
.btn {
    padding: 12px 20px;
    border: none;
    border-radius: var(--radius-lg);
    cursor: pointer;
    font-size: 14px;
    font-weight: 600;
    transition: transform var(--transition-fast), box-shadow var(--transition-fast);
}

.btn:hover {
    transform: translateY(-2px);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
}

/* Primary button (main actions) */
.btn-primary {
    background: var(--gradient-primary);
    color: white;
}

/* Secondary button (cancel, neutral actions) */
.btn-secondary {
    background: var(--bg-secondary);
    color: var(--text-primary);
    border: 1px solid var(--border-input);
}

/* Danger button (destructive actions) */
.btn-danger {
    background: linear-gradient(135deg, var(--status-error) 0%, var(--status-error-dark) 100%);
    color: white;
}

/* Small button variant */
.btn-sm {
    padding: 8px 16px;
    font-size: 0.85em;
}
```

#### Form Inputs

```css
.form-group {
    margin-bottom: var(--spacing-md);
}

.form-group label {
    display: block;
    margin-bottom: var(--spacing-xs);
    color: var(--text-secondary);
    font-size: 0.9em;
}

.form-group input,
.form-group select,
.form-group textarea {
    width: 100%;
    padding: 10px 12px;
    background: var(--bg-secondary);
    border: 1px solid var(--border-input);
    border-radius: var(--radius-md);
    color: var(--text-primary);
    font-size: 1em;
    transition: border-color var(--transition-normal);
}

.form-group input:focus,
.form-group select:focus,
.form-group textarea:focus {
    outline: none;
    border-color: var(--border-focus);
    box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.2);
}

.form-group input::placeholder {
    color: var(--text-disabled);
}
```

#### Progress Bars

```css
.progress-bar {
    height: 8px;
    background: var(--bg-secondary);
    border-radius: var(--radius-sm);
    overflow: hidden;
    margin-top: 8px;
}

.progress-fill {
    height: 100%;
    background: var(--gradient-primary);
    transition: width var(--transition-slow);
    border-radius: var(--radius-sm);
}

/* Warning state (70-90% usage) */
.progress-fill.warning {
    background: linear-gradient(90deg, var(--status-warning), var(--status-error));
}

/* Danger state (>90% usage) */
.progress-fill.danger {
    background: linear-gradient(90deg, var(--status-error), var(--status-error-dark));
}
```

#### Modals

```css
.modal {
    display: none;
    position: fixed;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    background: rgba(0, 0, 0, 0.8);
    align-items: center;
    justify-content: center;
    z-index: 1000;
}

.modal.active {
    display: flex;
}

.modal-content {
    background: var(--bg-card);
    padding: var(--spacing-xl);
    border-radius: var(--radius-xl);
    max-width: 400px;
    text-align: center;
    border: 1px solid var(--border-primary);
}

.modal-content h3 {
    margin-bottom: var(--spacing-md);
    color: var(--accent-primary);
}

.modal-content p {
    margin-bottom: var(--spacing-lg);
    color: var(--text-secondary);
}

.modal-buttons {
    display: flex;
    gap: var(--spacing-sm);
    justify-content: center;
}
```

#### Status Indicators

```css
/* Text colors for status */
.status-ok { color: var(--status-success); }
.status-warning { color: var(--status-warning); }
.status-error { color: var(--status-error); }

/* Pulsing status dot */
.status-dot {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    background: var(--status-error);
    animation: pulse 2s infinite;
}

.status-dot.connected {
    background: var(--status-success);
}

@keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.5; }
}
```

#### Alert Messages

```css
.error-message {
    background: rgba(255, 107, 107, 0.1);
    border: 1px solid var(--status-error);
    color: var(--status-error);
    padding: var(--spacing-sm);
    border-radius: var(--radius-md);
    margin-bottom: var(--spacing-md);
    font-size: 0.9em;
}

.success-message {
    background: rgba(81, 207, 102, 0.1);
    border: 1px solid var(--status-success);
    color: var(--status-success);
    padding: var(--spacing-sm);
    border-radius: var(--radius-md);
    margin-bottom: var(--spacing-md);
    font-size: 0.9em;
}
```

### Header Pattern

```css
header {
    background: var(--gradient-primary);
    color: white;
    padding: var(--spacing-lg);
    border-radius: var(--radius-xl);
    margin-bottom: var(--spacing-lg);
    display: flex;
    justify-content: space-between;
    align-items: center;
}

header h1 {
    font-size: 1.8em;
    margin-bottom: 5px;
}

.header-right {
    display: flex;
    align-items: center;
    gap: var(--spacing-lg);
}
```

### Grid Layout

```css
.container {
    max-width: 1400px;
    margin: 0 auto;
    padding: var(--spacing-lg);
}

.grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: var(--spacing-lg);
}
```

### Responsive Breakpoints

```css
/* Mobile (< 600px) */
@media (max-width: 600px) {
    .container {
        padding: var(--spacing-sm);
    }

    header {
        flex-direction: column;
        gap: var(--spacing-sm);
        text-align: center;
    }

    .btn {
        width: 100%;
    }

    .grid {
        grid-template-columns: 1fr;
    }
}
```

### Creating Consistent App UI

When building a new web application for this framework:

1. **Include the CSS variables** at the top of your stylesheet
2. **Use the dark theme** - all apps should use the same dark color scheme
3. **Follow the component patterns** - use the same button, card, and form styles
4. **Match the header** - apps should have a gradient header with the same style
5. **Use status colors consistently**:
   - Green (`--status-success`) for healthy/success
   - Orange (`--status-warning`) for warnings
   - Red (`--status-error`) for errors/failures

### Example: Minimal App Page Template

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>My App - System Management</title>
    <style>
        /* Include CSS variables from above */
        :root {
            --bg-primary: #1a1a2e;
            --bg-card: #16213e;
            --bg-secondary: #1f3460;
            --accent-primary: #667eea;
            --accent-secondary: #764ba2;
            --gradient-primary: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            --text-primary: #eee;
            --text-secondary: #888;
            --border-primary: #1f3460;
            --radius-xl: 12px;
            --spacing-lg: 20px;
            --font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
        }

        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: var(--font-family);
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
        }

        .container { max-width: 1200px; margin: 0 auto; padding: var(--spacing-lg); }

        header {
            background: var(--gradient-primary);
            color: white;
            padding: var(--spacing-lg);
            border-radius: var(--radius-xl);
            margin-bottom: var(--spacing-lg);
        }

        header h1 { font-size: 1.8em; }

        .card {
            background: var(--bg-card);
            border-radius: var(--radius-xl);
            padding: var(--spacing-lg);
            border: 1px solid var(--border-primary);
        }

        .card h2 {
            color: var(--accent-primary);
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 15px;
            padding-bottom: 10px;
            border-bottom: 1px solid var(--border-primary);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>My Application</h1>
            <p style="opacity: 0.9;">Version 1.0.0</p>
        </header>

        <div class="card">
            <h2>Dashboard</h2>
            <p>Your app content here...</p>
        </div>
    </div>
</body>
</html>
```

### Theme Customization

To change the theme across all apps in a future rebuild:

1. Update the CSS variables in `rootfs/opt/system-mgmt/templates/index.html`
2. Update the same variables in `rootfs/opt/system-mgmt/templates/login.html`
3. Document the new values in this section
4. Rebuild all apps to pick up the new theme

The CSS variable system allows changing colors in one place while maintaining consistency across the entire system.

---

## Creating a New Application

### Step 1: Project Structure

Create your application with this structure:

```
my-webapp/
├── CMakeLists.txt              # Build configuration
├── manifest.template.json      # Manifest template (optional)
├── src/
│   └── main.py                 # Application code
├── share/
│   └── www/                    # Static web assets
│       ├── index.html
│       └── style.css
└── etc/
    └── config.json.default     # Default configuration
```

### Step 2: CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.10)
project(my-webapp VERSION 1.0.0)

# Install executable
install(PROGRAMS src/main.py
        DESTINATION bin
        RENAME my-webapp-server)

# Install static assets
install(DIRECTORY share/www
        DESTINATION share)

# Install default config
install(FILES etc/config.json.default
        DESTINATION etc)

# Generate manifest (or copy template)
configure_file(manifest.template.json
               ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
               @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
        DESTINATION .)
```

### Step 3: Manifest Template

```json
{
  "name": "@PROJECT_NAME@",
  "version": "@PROJECT_VERSION@",
  "description": "My Web Application",
  "type": "webapp",
  "port": 8003,
  "url": "/",

  "health": {
    "type": "http",
    "endpoint": "/health",
    "port": 8003,
    "interval": 10,
    "timeout": 5
  },

  "startup": {
    "command": "/app/@PROJECT_NAME@/bin/my-webapp-server",
    "args": ["--config", "/data/app-config/@PROJECT_NAME@/config.json"],
    "priority": 30
  },

  "data_dirs": ["uploads", "cache"],

  "config_files": [
    {"source": "etc/config.json.default", "dest": "config.json"}
  ],

  "env": {
    "APP_DATA_DIR": "/data/app-data/@PROJECT_NAME@",
    "APP_LOG_FILE": "/var/log/app/@PROJECT_NAME@.log"
  }
}
```

### Step 4: Add to packages.txt

```
my-webapp|https://github.com/user/my-webapp|v1.0.0||cmake,python3|8003|30|webapp|My Web Application
```

### Step 5: Implement Health Endpoint

Your application should provide a health check endpoint:

```python
@app.route('/health')
def health():
    # Check dependencies, database connections, etc.
    return jsonify({'status': 'healthy'}), 200
```

### Step 6: Handle Graceful Shutdown

```python
import signal
import sys

def shutdown_handler(signum, frame):
    print("Shutting down gracefully...")
    # Close database connections
    # Finish pending requests
    # Cleanup resources
    sys.exit(0)

signal.signal(signal.SIGTERM, shutdown_handler)
```

### Step 7: Use Environment Variables

```python
import os

DATA_DIR = os.environ.get('APP_DATA_DIR', '/data/app-data/my-webapp')
LOG_FILE = os.environ.get('APP_LOG_FILE', '/var/log/app/my-webapp.log')
CONFIG_DIR = os.environ.get('APP_CONFIG_DIR', '/data/app-config/my-webapp')
```

### Step 8: Use Proxy-Compatible API Paths (Web Apps)

When your app is accessed through the system-mgmt proxy at `/app/<name>/`, API calls must use relative paths. **Important**: Do NOT use absolute paths like `/api/data` as they will be routed to system-mgmt instead of your app.

**JavaScript - Use a base path helper:**
```javascript
// Get base path for API calls (works with both direct and proxied access)
function getBasePath() {
    const path = window.location.pathname;
    // Ensure trailing slash for relative URL resolution
    return path.endsWith('/') ? path : path + '/';
}

// Use in fetch calls
async function fetchData() {
    const response = await fetch(getBasePath() + 'api/data');
    // When accessed at /app/myapp/, this fetches /app/myapp/api/data
    // When accessed directly at /, this fetches /api/data
    return response.json();
}
```

**Example API calls:**
```javascript
// ✓ CORRECT - relative paths
fetch(getBasePath() + 'api/users')
fetch(getBasePath() + 'health')

// ✗ WRONG - absolute paths (will go to system-mgmt, not your app)
fetch('/api/users')
fetch('/health')
```

---

## CMake Integration

### Standard Install Prefix

All apps install to `/app/<appname>/`:

```bash
cmake -DCMAKE_INSTALL_PREFIX=/app/my-webapp ..
make
make install DESTDIR=/tmp/app-staging
```

Result:
```
/tmp/app-staging/
└── app/
    └── my-webapp/
        ├── bin/
        ├── lib/
        ├── share/
        ├── etc/
        └── manifest.json
```

### Build Dependencies

Build dependencies are installed temporarily and removed after build:

```bash
# Install build deps
apk add --virtual .build-deps cmake gcc make

# Build
cmake .. && make && make install

# Remove build deps
apk del .build-deps
```

### Runtime Dependencies

Runtime dependencies stay in the image. Specify in manifest or packages.txt.

---

## Factory Reset

Factory reset clears ALL data and returns to fresh install:

```python
def perform_factory_reset():
    """Complete factory reset - clears all user and app data."""

    # Stop all applications first
    stop_all_apps()

    # Clear directories
    directories_to_clear = [
        '/data/overlay/upper',      # Rootfs overlay
        '/data/overlay/work',       # Overlay workdir
        '/data/app-data',           # All app runtime data
        '/data/app-config',         # All user configs
        '/data/home',               # User home directories
    ]

    for dir_path in directories_to_clear:
        if os.path.exists(dir_path):
            shutil.rmtree(dir_path)
            os.makedirs(dir_path)

    # Reboot to apply
    subprocess.run(['reboot'])
```

After reboot:
- System returns to factory state
- Default password restored
- All app data cleared
- Apps start fresh with default configs

---

## Port Forwarding (VirtualBox)

### Port Forwarding Strategy

The `04-convert-to-vbox.sh` script configures port forwarding based on app requirements:

```bash
# Core services (always forwarded)
VBoxManage modifyvm "$VM_NAME" --natpf1 "ssh,tcp,,2222,,22"
VBoxManage modifyvm "$VM_NAME" --natpf1 "sysmgmt,tcp,,8000,,8000"

# WebSocket-enabled apps (forwarded for direct WebSocket access)
# HTTP proxies don't support WebSocket upgrade, so direct port access is needed
VBoxManage modifyvm "$VM_NAME" --natpf1 "webterminal,tcp,,8003,,8003"

# Additional app ports read from /app/manifest.json
for app in ${APP_PORTS[@]}; do
    VBoxManage modifyvm "$VM_NAME" --natpf1 "app-${name},tcp,,${port},,${port}"
done
```

### Port Mapping

| Service | Guest Port | Host Port | Access Method |
|---------|------------|-----------|---------------|
| SSH | 22 | 2222 | Direct: `ssh -p 2222 admin@localhost` |
| System Mgmt | 8000 | 8000 | Direct: `http://localhost:8000/` |
| Web Terminal | 8003 | 8003 | HTTP via proxy, WebSocket direct |
| Other Apps | per manifest | same | HTTP via proxy `/app/<name>/`, WebSocket direct |

### Dual Access Pattern for WebSocket Apps

Apps with WebSocket support (like web-terminal) need both:
1. **HTTP via proxy**: `http://localhost:8000/app/web-terminal/` (authenticated, session cookie)
2. **WebSocket direct**: `ws://localhost:8003/ws?token=...` (token-authenticated)

This is because standard HTTP reverse proxies don't support WebSocket upgrade. The token-based auth ensures WebSocket connections are still authenticated.

### Security Benefits

- **Centralized authentication**: HTTP access through proxy requires system-mgmt login
- **Token-based WebSocket auth**: Direct WebSocket connections validated via short-lived tokens
- **Automatic port discovery**: Ports read from app manifest, no manual configuration

---

## Common Pitfalls and Troubleshooting

This section documents common issues encountered when developing applications for the VMBOX framework.

### Windows Line Endings (CRLF)

**Problem**: Python and shell scripts created on Windows have CRLF (`\r\n`) line endings instead of Unix LF (`\n`). This causes the shebang to be interpreted literally with the carriage return character.

**Symptom**:
```
env: 'python3\r': No such file or directory
env: use -[v]S to pass options in shebang lines
```

**Solution**: Convert all script files to Unix line endings before building:

```bash
# Check for CRLF files
file src/*.py scripts/*.sh

# If output shows "with CRLF line terminators", fix with:
sed -i 's/\r$//' src/*.py scripts/*.sh share/www/*.html share/www/js/*.js

# Or use dos2unix if available
dos2unix src/*.py
```

**Prevention**: Configure your editor/IDE to use Unix line endings:
- **VS Code**: Add to `.vscode/settings.json`:
  ```json
  {
    "files.eol": "\n"
  }
  ```
- **Git**: Configure auto-conversion:
  ```bash
  git config core.autocrlf input    # On Linux/Mac
  git config core.autocrlf true     # On Windows
  ```
- **EditorConfig**: Add `.editorconfig` to project root:
  ```ini
  [*]
  end_of_line = lf
  ```

### packages.txt Empty Fields

**Problem**: The packages.txt format uses `|` as field separator. Empty optional fields (like CMAKE_OPTIONS) must still include the separator.

**Symptom**: Build fails or manifest is not generated correctly. App appears in /app/ directory but isn't recognized by app-manager.

**Wrong**:
```
# Missing empty CMAKE_OPTIONS field - only 8 fields instead of 9
my-app|https://github.com/user/repo|HEAD|cmake,python3|8004|27|webapp|My App
```

**Correct**:
```
# Empty CMAKE_OPTIONS field properly marked with ||
my-app|https://github.com/user/repo|HEAD||cmake,python3|8004|27|webapp|My App
```

**Field Reference** (all 9 fields required):
```
NAME|GIT_REPO|VERSION|CMAKE_OPTIONS|BUILD_DEPS|PORT|PRIORITY|TYPE|DESCRIPTION
```

### App Not Starting (No Startup Script Found)

**Problem**: App-manager can't find startup script for an app.

**Symptom**: Clicking "Start" in WebUI does nothing. App-manager logs show:
```
No startup script found for <appname>
```

**Causes**:
1. App not in manifest.json (check packages.txt format)
2. Build failed silently (check build logs)
3. Startup script naming mismatch

**Solution**: Verify the startup script exists:
```bash
ls -la /app/startup.d/*-myapp.sh
```

### Health Check Failing

**Problem**: App shows as "unhealthy" even though it's running.

**Symptom**: App status shows yellow/orange "unhealthy" indicator.

**Common Causes**:
1. **Missing /health endpoint**: App doesn't implement the health endpoint specified in manifest
2. **Wrong port in manifest**: Health check port doesn't match app's actual port
3. **Slow startup**: App takes longer than timeout to become ready

**Solution**: Verify health endpoint works:
```bash
# From inside VM
curl -v http://localhost:8004/health
```

Ensure your Flask app has:
```python
@app.route('/health')
def health():
    return jsonify({'status': 'healthy'}), 200
```

### Permission Denied for Log/PID Files

**Problem**: App startup script can't create log or PID files.

**Symptom**:
```
/app/startup.d/27-myapp.sh: can't create /var/log/app/myapp.log: Permission denied
```

**Cause**: Script running as non-root user, but directories don't exist or have wrong permissions.

**Solution**: The app-manager service should create these directories with proper permissions at startup. If running manually, ensure directories exist:
```bash
mkdir -p /run/app /var/log/app
chmod 755 /run/app /var/log/app
```

### WebSocket Connection Refused

**Problem**: WebSocket connections fail even though HTTP works.

**Symptom**: Terminal/real-time features don't work. Browser console shows WebSocket connection errors.

**Causes**:
1. **Port not forwarded**: VirtualBox NAT doesn't forward the WebSocket port
2. **Wrong port in JS**: Frontend connecting to wrong port
3. **Token expired**: WebSocket auth token has expired (60 second lifetime)

**Solution**:
1. Verify port forwarding: `VBoxManage showvminfo <VM> | grep -i nat`
2. Check token freshness - tokens expire after 60 seconds
3. Ensure direct port access is used for WebSocket (not through proxy)

### App Starts But Crashes Immediately

**Problem**: App process starts then immediately exits.

**Symptom**: App shows as "stopped" shortly after clicking "Start". PID file exists briefly then disappears.

**Debug Steps**:
```bash
# Check app log for errors
cat /var/log/app/myapp.log

# Try running the app manually
python3 /app/myapp/bin/myapp-server

# Check for missing dependencies
python3 -c "import flask; import flask_sock"
```

**Common Causes**:
1. Missing Python dependencies (flask, flask-sock, pyserial, etc.)
2. Configuration file not found or invalid JSON
3. Port already in use by another process
4. Import errors in Python code

---

## Summary

1. **Partition Order**: BOOT → ROOTFS → DATA → APP (APP last for extensibility)
2. **APP Partition**: SquashFS (read-only), contains all application code
3. **DATA Partition**: ext4 (read-write), contains runtime data and configs
4. **Manifest-Driven**: Apps self-describe via manifest.json
5. **Health Monitoring**: 10-second checks, multiple types supported
6. **Graceful Lifecycle**: Ordered startup, SIGTERM → timeout → SIGKILL shutdown
7. **WebUI Integration**: Apps panel with status, controls, log management, and "Open" links
8. **Dual Access Pattern**: HTTP via proxy (`/app/<name>/`), WebSocket via direct port + token auth
9. **Port Forwarding**: Core services + WebSocket-enabled app ports (from manifest)
10. **Factory Reset**: Complete wipe of all user and app data
11. **Log Management**: Clear individual/all logs, download as ZIP, kernel messages via dmesg --clear

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2025-01-15 | Initial design document |
| 1.1.0 | 2025-12-13 | Added UI Design System section with design tokens, color palette, component styles, and app template |
| 1.2.0 | 2025-12-13 | Added authenticated reverse proxy for webapp access; apps accessed via `/app/<name>/` instead of direct ports; updated port forwarding to only expose SSH and System Mgmt; added proxy-compatible API path guidelines |
| 1.3.0 | 2025-12-15 | Updated port forwarding to include WebSocket-enabled apps (direct access needed for WS); added WebSocket message parsing gotcha (JSON single-digit bug); added log management features (Clear Log, Clear All, Download ZIP); updated token validation to allow reuse within validity period |
| 1.4.0 | 2025-12-16 | Added Common Pitfalls and Troubleshooting section documenting: Windows CRLF line endings, packages.txt empty fields, startup script issues, health check failures, permission denied errors, WebSocket issues, and app crash debugging |
