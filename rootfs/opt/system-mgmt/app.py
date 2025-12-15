#!/usr/bin/env python3
"""
System Management Web Application

This Flask application provides system monitoring and management endpoints
for the VirtualBox Alpine demo image.

Features:
    - Shadow-based authentication (same credentials as SSH/terminal)
    - Real-time system stats via Server-Sent Events (SSE)
    - Dashboard with live CPU, memory, disk, and network monitoring
    - Application management and monitoring
    - Reverse proxy for authenticated app access
    - Factory reset and reboot capabilities

Endpoints:
    GET  /                      - Dashboard HTML page (requires login)
    GET  /login                 - Login page
    POST /login                 - Authenticate user
    GET  /logout                - Log out and clear session
    GET  /api/stream            - SSE stream for real-time updates
    GET  /api/version           - Image version information
    GET  /api/system/info       - All system information
    GET  /api/system/disk       - Disk usage
    GET  /api/system/cpu        - CPU load
    GET  /api/system/memory     - Memory usage
    GET  /api/system/uptime     - System uptime
    GET  /api/system/hostname   - Hostname
    GET  /api/system/network    - Network information
    POST /api/factory-reset     - Reset to factory defaults
    POST /api/reboot            - Reboot the system
    GET  /app/<name>/*          - Reverse proxy to applications (requires login)
"""

import os
import socket
import subprocess
import json
import time
import crypt
import hmac
import logging
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from functools import wraps
import io
import zipfile
import glob as glob_module
from flask import Flask, jsonify, render_template, request, Response, session, redirect, url_for, send_file

app = Flask(__name__)

# Session configuration
app.secret_key = os.urandom(24)  # Generate random secret key on startup
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(minutes=30)
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'

# Setup logging for failed login attempts
logging.basicConfig(
    filename='/var/log/system-mgmt-auth.log',
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
auth_logger = logging.getLogger('auth')

# Configuration
VERSION_FILE = '/etc/image-version'
DATA_PARTITION = '/data'
OVERLAY_UPPER = '/data/overlay/upper'
OVERLAY_WORK = '/data/overlay/work'

# Log sources configuration (static sources)
LOG_SOURCES = {
    'dmesg': {
        'name': 'Kernel Messages',
        'path': None,  # Special: uses dmesg command
        'description': 'Kernel ring buffer'
    },
    'auth': {
        'name': 'Authentication Log',
        'path': '/var/log/system-mgmt-auth.log',
        'description': 'WebUI login attempts'
    },
    'sysmgmt': {
        'name': 'System Mgmt Log',
        'path': '/var/log/system-mgmt.log',
        'description': 'System management service log'
    }
}

# App Manager socket
APP_MANAGER_SOCKET = '/run/app/app-manager.sock'
APP_LOG_DIR = '/var/log/app'
APP_MANIFEST_FILE = '/app/manifest.json'

# App proxy configuration
# Cache for app ports: {app_name: port}
_app_port_cache = {}
_app_port_cache_time = 0
APP_PORT_CACHE_TTL = 60  # Cache TTL in seconds

# CPU stats tracking for percentage calculation
_prev_cpu_stats = None
_prev_cpu_time = None


def app_manager_request(method, path, timeout=5):
    """
    Send a request to the app-manager Unix socket API.

    Args:
        method: HTTP method (GET, POST)
        path: API path (e.g., '/apps', '/apps/hello-world/start')
        timeout: Socket timeout in seconds

    Returns:
        dict: Parsed JSON response or error dict
    """
    if not os.path.exists(APP_MANAGER_SOCKET):
        return {'error': 'App manager not running', 'apps': []}

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect(APP_MANAGER_SOCKET)

        # Send HTTP request
        request_line = f"{method} {path} HTTP/1.1\r\n"
        headers = "Host: localhost\r\nConnection: close\r\n\r\n"
        sock.sendall((request_line + headers).encode())

        # Receive response
        response = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk

        sock.close()

        # Parse response
        response_str = response.decode('utf-8', errors='replace')
        if '\r\n\r\n' in response_str:
            _, body = response_str.split('\r\n\r\n', 1)
            return json.loads(body)
        else:
            return {'error': 'Invalid response from app manager'}

    except socket.timeout:
        return {'error': 'App manager timeout', 'apps': []}
    except ConnectionRefusedError:
        return {'error': 'App manager not responding', 'apps': []}
    except json.JSONDecodeError:
        return {'error': 'Invalid JSON from app manager', 'apps': []}
    except Exception as e:
        return {'error': str(e), 'apps': []}


def get_app_ports():
    """
    Get mapping of app names to ports.
    Uses cache with TTL to avoid frequent manifest reads.

    Returns:
        dict: {app_name: port} mapping
    """
    global _app_port_cache, _app_port_cache_time

    current_time = time.time()

    # Return cached data if still valid
    if _app_port_cache and (current_time - _app_port_cache_time) < APP_PORT_CACHE_TTL:
        return _app_port_cache

    # Try to load from manifest file first (faster)
    if os.path.exists(APP_MANIFEST_FILE):
        try:
            with open(APP_MANIFEST_FILE, 'r') as f:
                manifest = json.load(f)
                apps = manifest.get('apps', [])
                _app_port_cache = {app['name']: app['port'] for app in apps}
                _app_port_cache_time = current_time
                return _app_port_cache
        except Exception:
            pass

    # Fallback to app-manager API
    result = app_manager_request('GET', '/apps')
    if 'apps' in result:
        _app_port_cache = {app['name']: app.get('port', 0) for app in result['apps']}
        _app_port_cache_time = current_time
        return _app_port_cache

    return {}


def proxy_request_to_app(app_name, path):
    """
    Proxy an HTTP request to a backend application.

    Args:
        app_name: Name of the application
        path: Path to forward (including query string)

    Returns:
        Flask Response object
    """
    app_ports = get_app_ports()

    if app_name not in app_ports:
        return Response(
            json.dumps({'error': f'Application not found: {app_name}'}),
            status=404,
            mimetype='application/json'
        )

    port = app_ports[app_name]
    if not port:
        return Response(
            json.dumps({'error': f'No port configured for: {app_name}'}),
            status=500,
            mimetype='application/json'
        )

    # Build target URL
    target_url = f'http://127.0.0.1:{port}{path}'

    try:
        # Create request with same method and headers
        req = urllib.request.Request(
            target_url,
            data=request.get_data() if request.method in ['POST', 'PUT', 'PATCH'] else None,
            method=request.method
        )

        # Forward relevant headers
        for header in ['Content-Type', 'Accept', 'Accept-Language', 'Accept-Encoding']:
            if header in request.headers:
                req.add_header(header, request.headers[header])

        # Make request to backend
        with urllib.request.urlopen(req, timeout=30) as resp:
            content = resp.read()
            response_headers = dict(resp.headers)

            # Create Flask response
            flask_resp = Response(content, status=resp.status)

            # Copy headers (except hop-by-hop headers)
            skip_headers = {'transfer-encoding', 'connection', 'keep-alive'}
            for key, value in response_headers.items():
                if key.lower() not in skip_headers:
                    flask_resp.headers[key] = value

            return flask_resp

    except urllib.error.HTTPError as e:
        content = e.read() if e.fp else b''
        return Response(content, status=e.code, mimetype='text/html')
    except urllib.error.URLError as e:
        return Response(
            json.dumps({'error': f'Cannot connect to {app_name}: {str(e.reason)}'}),
            status=502,
            mimetype='application/json'
        )
    except Exception as e:
        return Response(
            json.dumps({'error': f'Proxy error: {str(e)}'}),
            status=500,
            mimetype='application/json'
        )


def verify_shadow_password(username, password):
    """
    Verify password against /etc/shadow file.
    Returns True if password is correct, False otherwise.
    """
    try:
        with open('/etc/shadow', 'r') as f:
            for line in f:
                parts = line.strip().split(':')
                if len(parts) >= 2 and parts[0] == username:
                    stored_hash = parts[1]
                    # Handle locked or disabled accounts
                    if stored_hash in ('!', '*', '!!', ''):
                        return False
                    # Verify password using crypt
                    computed_hash = crypt.crypt(password, stored_hash)
                    return hmac.compare_digest(computed_hash, stored_hash)
    except PermissionError:
        auth_logger.error(f"Permission denied reading /etc/shadow")
        return False
    except Exception as e:
        auth_logger.error(f"Error verifying password: {e}")
        return False
    return False


def login_required(f):
    """Decorator to require authentication for a route."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'username' not in session:
            if request.is_json or request.path.startswith('/api/'):
                return jsonify({'error': 'Authentication required'}), 401
            return redirect(url_for('login'))
        # Check session expiry
        if 'login_time' in session:
            login_time = datetime.fromisoformat(session['login_time'])
            if datetime.now() - login_time > timedelta(minutes=30):
                session.clear()
                if request.is_json or request.path.startswith('/api/'):
                    return jsonify({'error': 'Session expired'}), 401
                return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function


def read_version_info():
    """Read version information from the version file."""
    info = {
        'version': 'unknown',
        'build_mode': 'unknown',
        'build_date': 'unknown',
        'build_host': 'unknown',
        'alpine_version': 'unknown'
    }

    if os.path.exists(VERSION_FILE):
        try:
            with open(VERSION_FILE, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.lower()
                        if key == 'version':
                            info['version'] = value
                        elif key == 'build_mode':
                            info['build_mode'] = value
                        elif key == 'build_date':
                            info['build_date'] = value
                        elif key == 'build_host':
                            info['build_host'] = value
                        elif key == 'alpine_version':
                            info['alpine_version'] = value
        except Exception as e:
            info['error'] = str(e)

    return info


def get_disk_usage():
    """Get disk usage information."""
    disks = {}

    # Get usage for key mount points
    mount_points = ['/', '/data', '/mnt/shared']

    for mount in mount_points:
        if os.path.exists(mount):
            try:
                stat = os.statvfs(mount)
                total = stat.f_blocks * stat.f_frsize
                free = stat.f_bfree * stat.f_frsize
                used = total - free
                percent = (used / total * 100) if total > 0 else 0

                disks[mount] = {
                    'total_bytes': total,
                    'used_bytes': used,
                    'free_bytes': free,
                    'total_human': format_bytes(total),
                    'used_human': format_bytes(used),
                    'free_human': format_bytes(free),
                    'percent_used': round(percent, 1)
                }
            except Exception as e:
                disks[mount] = {'error': str(e)}

    return disks


def get_cpu_load():
    """Get CPU load averages."""
    try:
        with open('/proc/loadavg', 'r') as f:
            parts = f.read().split()
            return {
                'load_1m': float(parts[0]),
                'load_5m': float(parts[1]),
                'load_15m': float(parts[2]),
                'processes': parts[3]
            }
    except Exception as e:
        return {'error': str(e)}


def get_cpu_percent():
    """Get CPU usage percentage (more accurate than load average)."""
    global _prev_cpu_stats, _prev_cpu_time

    try:
        with open('/proc/stat', 'r') as f:
            line = f.readline()
            parts = line.split()
            # cpu user nice system idle iowait irq softirq
            if parts[0] == 'cpu':
                user = int(parts[1])
                nice = int(parts[2])
                system = int(parts[3])
                idle = int(parts[4])
                iowait = int(parts[5]) if len(parts) > 5 else 0
                irq = int(parts[6]) if len(parts) > 6 else 0
                softirq = int(parts[7]) if len(parts) > 7 else 0

                total = user + nice + system + idle + iowait + irq + softirq
                idle_total = idle + iowait

                current_time = time.time()

                if _prev_cpu_stats is not None and _prev_cpu_time is not None:
                    total_diff = total - _prev_cpu_stats['total']
                    idle_diff = idle_total - _prev_cpu_stats['idle']

                    if total_diff > 0:
                        cpu_percent = round((1 - idle_diff / total_diff) * 100, 1)
                    else:
                        cpu_percent = 0.0
                else:
                    cpu_percent = 0.0

                _prev_cpu_stats = {'total': total, 'idle': idle_total}
                _prev_cpu_time = current_time

                return cpu_percent
    except Exception:
        pass

    return 0.0


def get_memory_info():
    """Get memory usage information."""
    try:
        with open('/proc/meminfo', 'r') as f:
            meminfo = {}
            for line in f:
                parts = line.split(':')
                if len(parts) == 2:
                    key = parts[0].strip()
                    value = parts[1].strip().split()[0]
                    meminfo[key] = int(value) * 1024  # Convert to bytes

        total = meminfo.get('MemTotal', 0)
        free = meminfo.get('MemFree', 0)
        buffers = meminfo.get('Buffers', 0)
        cached = meminfo.get('Cached', 0)
        available = meminfo.get('MemAvailable', free + buffers + cached)
        used = total - available

        return {
            'total_bytes': total,
            'used_bytes': used,
            'free_bytes': free,
            'available_bytes': available,
            'total_human': format_bytes(total),
            'used_human': format_bytes(used),
            'free_human': format_bytes(free),
            'available_human': format_bytes(available),
            'percent_used': round((used / total * 100) if total > 0 else 0, 1)
        }
    except Exception as e:
        return {'error': str(e)}


def get_uptime():
    """Get system uptime."""
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.read().split()[0])

        days = int(uptime_seconds // 86400)
        hours = int((uptime_seconds % 86400) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        seconds = int(uptime_seconds % 60)

        return {
            'seconds': uptime_seconds,
            'days': days,
            'hours': hours,
            'minutes': minutes,
            'human': f"{days}d {hours}h {minutes}m {seconds}s"
        }
    except Exception as e:
        return {'error': str(e)}


def get_hostname():
    """Get system hostname."""
    try:
        with open('/etc/hostname', 'r') as f:
            return f.read().strip()
    except Exception:
        import socket
        return socket.gethostname()


def get_network_info():
    """Get network interface information."""
    interfaces = {}

    try:
        # Get list of interfaces
        for iface in os.listdir('/sys/class/net'):
            if iface == 'lo':
                continue

            iface_info = {'name': iface}

            # Get IP address using ip command
            try:
                result = subprocess.run(
                    ['ip', '-4', 'addr', 'show', iface],
                    capture_output=True,
                    text=True,
                    timeout=5
                )
                for line in result.stdout.split('\n'):
                    if 'inet ' in line:
                        parts = line.strip().split()
                        iface_info['ipv4'] = parts[1].split('/')[0]
                        break
            except Exception:
                pass

            # Get MAC address
            try:
                with open(f'/sys/class/net/{iface}/address', 'r') as f:
                    iface_info['mac'] = f.read().strip()
            except Exception:
                pass

            # Get link status
            try:
                with open(f'/sys/class/net/{iface}/operstate', 'r') as f:
                    iface_info['status'] = f.read().strip()
            except Exception:
                pass

            # Get RX/TX bytes
            try:
                with open(f'/sys/class/net/{iface}/statistics/rx_bytes', 'r') as f:
                    iface_info['rx_bytes'] = int(f.read().strip())
                    iface_info['rx_human'] = format_bytes(iface_info['rx_bytes'])
                with open(f'/sys/class/net/{iface}/statistics/tx_bytes', 'r') as f:
                    iface_info['tx_bytes'] = int(f.read().strip())
                    iface_info['tx_human'] = format_bytes(iface_info['tx_bytes'])
            except Exception:
                pass

            interfaces[iface] = iface_info

    except Exception as e:
        return {'error': str(e)}

    return interfaces


def format_bytes(bytes_val):
    """Format bytes into human-readable string."""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024:
            return f"{bytes_val:.1f} {unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f} PB"


def get_log_sources():
    """Get list of available log sources with their status."""
    sources = []

    # Add static log sources
    for key, config in LOG_SOURCES.items():
        source = {
            'id': key,
            'name': config['name'],
            'description': config['description'],
            'available': True
        }
        # Check if file exists (except for dmesg which is always available)
        if config['path'] is not None:
            source['available'] = os.path.exists(config['path'])
        sources.append(source)

    # Dynamically discover app logs in /var/log/app/
    if os.path.isdir(APP_LOG_DIR):
        for log_file in sorted(os.listdir(APP_LOG_DIR)):
            if log_file.endswith('.log'):
                app_name = log_file[:-4]  # Remove .log extension
                # Create a friendly name
                if app_name == 'app-manager':
                    friendly_name = 'App Manager Log'
                    description = 'Application manager service log'
                else:
                    friendly_name = f'{app_name.replace("-", " ").title()} Log'
                    description = f'Application log for {app_name}'

                sources.append({
                    'id': f'app:{app_name}',
                    'name': friendly_name,
                    'description': description,
                    'available': True
                })

    return sources


def read_log_file(source_id, lines=100, search=None):
    """
    Read log file content.

    Args:
        source_id: Log source identifier (or 'app:name' for app logs)
        lines: Number of lines to return (from end of file)
        search: Optional search string to filter lines

    Returns:
        dict with 'lines' (list of log lines) and 'total' (total matching lines)
    """
    log_lines = []
    path = None
    source_name = source_id  # Default source name

    # Handle app logs (app:name format)
    if source_id.startswith('app:'):
        app_name = source_id[4:]  # Remove 'app:' prefix
        path = os.path.join(APP_LOG_DIR, f'{app_name}.log')
        if app_name == 'app-manager':
            source_name = 'App Manager Log'
        else:
            source_name = f'{app_name.replace("-", " ").title()} Log'
    elif source_id in LOG_SOURCES:
        config = LOG_SOURCES[source_id]
        path = config.get('path')
        source_name = config['name']
    else:
        return {'error': f'Unknown log source: {source_id}', 'lines': [], 'total': 0}

    try:
        # Special handling for dmesg
        if source_id == 'dmesg':
            result = subprocess.run(
                ['dmesg', '-T'],  # -T for human-readable timestamps
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                log_lines = result.stdout.strip().split('\n')
            else:
                # Try without -T flag (older systems)
                result = subprocess.run(
                    ['dmesg'],
                    capture_output=True,
                    text=True,
                    timeout=10
                )
                log_lines = result.stdout.strip().split('\n') if result.returncode == 0 else []
        else:
            # Read from file
            if not path or not os.path.exists(path):
                return {'error': f'Log file not found: {path}', 'lines': [], 'total': 0}

            with open(path, 'r', errors='replace') as f:
                log_lines = f.readlines()
            log_lines = [line.rstrip('\n') for line in log_lines]

        # Filter by search term if provided
        if search:
            search_lower = search.lower()
            log_lines = [line for line in log_lines if search_lower in line.lower()]

        total = len(log_lines)

        # Return last N lines
        if lines > 0 and len(log_lines) > lines:
            log_lines = log_lines[-lines:]

        return {
            'lines': log_lines,
            'total': total,
            'returned': len(log_lines),
            'source': source_id,
            'source_name': source_name
        }

    except subprocess.TimeoutExpired:
        return {'error': 'Timeout reading log', 'lines': [], 'total': 0}
    except PermissionError:
        return {'error': 'Permission denied', 'lines': [], 'total': 0}
    except Exception as e:
        return {'error': str(e), 'lines': [], 'total': 0}


def perform_factory_reset():
    """Perform factory reset by clearing overlay and app data directories."""
    errors = []

    # Directories to clear during factory reset
    dirs_to_clear = [
        (OVERLAY_UPPER, "overlay upper"),
        (OVERLAY_WORK, "overlay work"),
        (f"{DATA_PARTITION}/app-data", "app data"),
        (f"{DATA_PARTITION}/app-config", "app config"),
    ]

    for dir_path, dir_name in dirs_to_clear:
        if os.path.exists(dir_path):
            try:
                for item in os.listdir(dir_path):
                    path = os.path.join(dir_path, item)
                    if os.path.isdir(path):
                        subprocess.run(['rm', '-rf', path], check=True)
                    else:
                        os.remove(path)
            except Exception as e:
                errors.append(f"Failed to clear {dir_name}: {e}")

    return errors


def generate_sse_stream():
    """Generator function for Server-Sent Events stream."""
    while True:
        try:
            data = {
                'cpu': get_cpu_load(),
                'cpu_percent': get_cpu_percent(),
                'memory': get_memory_info(),
                'disk': get_disk_usage(),
                'network': get_network_info(),
                'uptime': get_uptime(),
                'timestamp': datetime.utcnow().isoformat() + 'Z'
            }
            yield f"data: {json.dumps(data)}\n\n"
            time.sleep(1)  # Update every second
        except GeneratorExit:
            break
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"
            time.sleep(1)


# Routes

@app.route('/login', methods=['GET', 'POST'])
def login():
    """Handle user login."""
    if request.method == 'POST':
        username = request.form.get('username', '').strip()
        password = request.form.get('password', '')
        client_ip = request.remote_addr

        if not username or not password:
            return render_template('login.html', error='Username and password required')

        if verify_shadow_password(username, password):
            session.permanent = True
            session['username'] = username
            session['login_time'] = datetime.now().isoformat()
            auth_logger.info(f"Successful login for user '{username}' from {client_ip}")
            return redirect(url_for('index'))
        else:
            auth_logger.warning(f"Failed login attempt for user '{username}' from {client_ip}")
            return render_template('login.html', error='Invalid username or password')

    return render_template('login.html')


@app.route('/logout')
def logout():
    """Log out the current user."""
    username = session.get('username', 'unknown')
    session.clear()
    auth_logger.info(f"User '{username}' logged out")
    return redirect(url_for('login'))


# Session validation endpoints for apps (especially WebSocket-enabled apps)
# These allow apps to validate authentication without going through the proxy

@app.route('/api/session/check')
def api_session_check():
    """
    Check if the current session is valid.
    Apps can call this to verify user authentication.
    Returns JSON with valid=true/false and username if valid.
    """
    if 'username' not in session:
        return jsonify({'valid': False})

    # Check session expiry
    if 'login_time' in session:
        login_time = datetime.fromisoformat(session['login_time'])
        if datetime.now() - login_time > timedelta(minutes=30):
            return jsonify({'valid': False, 'reason': 'expired'})

    return jsonify({
        'valid': True,
        'username': session.get('username'),
        'login_time': session.get('login_time')
    })


@app.route('/api/session/token', methods=['POST'])
@login_required
def api_session_token():
    """
    Generate a short-lived token for WebSocket authentication.
    Apps can use this token to authenticate WebSocket connections.

    The token is valid for 60 seconds and tied to the current session.
    """
    import secrets
    import hashlib

    # Generate a token based on session + random data
    token_data = f"{session.get('username')}:{session.get('login_time')}:{secrets.token_hex(16)}"
    token = hashlib.sha256(token_data.encode()).hexdigest()[:32]

    # Store token with expiry (in a simple dict - in production use Redis/memcached)
    if not hasattr(app, '_ws_tokens'):
        app._ws_tokens = {}

    # Clean expired tokens
    current_time = time.time()
    app._ws_tokens = {k: v for k, v in app._ws_tokens.items() if v['expires'] > current_time}

    # Store new token
    app._ws_tokens[token] = {
        'username': session.get('username'),
        'expires': current_time + 60,  # 60 second validity
        'created': current_time
    }

    return jsonify({
        'token': token,
        'expires_in': 60,
        'username': session.get('username')
    })


@app.route('/api/session/validate-token', methods=['POST'])
def api_validate_token():
    """
    Validate a WebSocket authentication token.
    Apps call this to verify tokens received from clients.

    Request body: {"token": "..."}
    Response: {"valid": true/false, "username": "..." if valid}
    """
    data = request.get_json()
    if not data or 'token' not in data:
        return jsonify({'valid': False, 'reason': 'missing token'})

    token = data['token']

    if not hasattr(app, '_ws_tokens'):
        return jsonify({'valid': False, 'reason': 'no tokens'})

    token_info = app._ws_tokens.get(token)
    if not token_info:
        return jsonify({'valid': False, 'reason': 'invalid token'})

    if token_info['expires'] < time.time():
        # Clean up expired token
        del app._ws_tokens[token]
        return jsonify({'valid': False, 'reason': 'expired'})

    # Token is valid - allow reuse until expiry (60 seconds)
    # This allows WebSocket reconnections without requiring new token
    username = token_info['username']

    return jsonify({
        'valid': True,
        'username': username
    })


@app.route('/')
@login_required
def index():
    """Render the dashboard page."""
    return render_template('index.html', username=session.get('username'))


@app.route('/api/stream')
@login_required
def api_stream():
    """Server-Sent Events endpoint for real-time updates."""
    return Response(
        generate_sse_stream(),
        mimetype='text/event-stream',
        headers={
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
            'X-Accel-Buffering': 'no'  # Disable nginx buffering
        }
    )


@app.route('/api/version')
@login_required
def api_version():
    """Return version information."""
    return jsonify(read_version_info())


@app.route('/api/system/info')
@login_required
def api_system_info():
    """Return all system information."""
    return jsonify({
        'version': read_version_info(),
        'hostname': get_hostname(),
        'uptime': get_uptime(),
        'cpu': get_cpu_load(),
        'cpu_percent': get_cpu_percent(),
        'memory': get_memory_info(),
        'disk': get_disk_usage(),
        'network': get_network_info(),
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    })


@app.route('/api/system/disk')
@login_required
def api_disk():
    """Return disk usage information."""
    return jsonify(get_disk_usage())


@app.route('/api/system/cpu')
@login_required
def api_cpu():
    """Return CPU load information."""
    return jsonify(get_cpu_load())


@app.route('/api/system/memory')
@login_required
def api_memory():
    """Return memory usage information."""
    return jsonify(get_memory_info())


@app.route('/api/system/uptime')
@login_required
def api_uptime():
    """Return system uptime."""
    return jsonify(get_uptime())


@app.route('/api/system/hostname')
@login_required
def api_hostname():
    """Return system hostname."""
    return jsonify({'hostname': get_hostname()})


@app.route('/api/system/network')
@login_required
def api_network():
    """Return network information."""
    return jsonify(get_network_info())


@app.route('/api/logs/sources')
@login_required
def api_log_sources():
    """Return available log sources."""
    return jsonify(get_log_sources())


@app.route('/api/logs/<source_id>')
@login_required
def api_log_content(source_id):
    """Return log content for a specific source."""
    # Get query parameters
    lines = request.args.get('lines', 100, type=int)
    search = request.args.get('search', None, type=str)

    # Limit max lines to prevent memory issues
    lines = min(lines, 1000)

    result = read_log_file(source_id, lines=lines, search=search)
    return jsonify(result)


@app.route('/api/logs/<source_id>/clear', methods=['POST'])
@login_required
def api_clear_log(source_id):
    """Clear (truncate) a specific log file."""
    path = None

    # Handle app logs (app:name format)
    if source_id.startswith('app:'):
        app_name = source_id[4:]
        path = os.path.join(APP_LOG_DIR, f'{app_name}.log')
    elif source_id in LOG_SOURCES:
        config = LOG_SOURCES[source_id]
        path = config.get('path')
    else:
        return jsonify({'status': 'error', 'message': f'Unknown log source: {source_id}'}), 400

    # dmesg cannot be cleared via this endpoint
    if source_id == 'dmesg' or path is None:
        return jsonify({'status': 'error', 'message': 'This log source cannot be cleared'}), 400

    try:
        if os.path.exists(path):
            # Truncate the file (keeps file handle valid for running apps)
            open(path, 'w').close()
            return jsonify({'status': 'ok', 'message': f'Log cleared: {source_id}'})
        else:
            return jsonify({'status': 'ok', 'message': 'Log file does not exist'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)}), 500


@app.route('/api/logs/clear-all', methods=['POST'])
@login_required
def api_clear_all_logs():
    """Clear all app log files."""
    cleared = []
    errors = []

    # Clear app logs
    if os.path.isdir(APP_LOG_DIR):
        for log_file in glob_module.glob(os.path.join(APP_LOG_DIR, '*.log')):
            try:
                open(log_file, 'w').close()
                cleared.append(os.path.basename(log_file))
            except Exception as e:
                errors.append(f'{os.path.basename(log_file)}: {e}')

    # Also clear static log sources (except dmesg)
    for key, config in LOG_SOURCES.items():
        if config.get('path') and key != 'dmesg':
            try:
                if os.path.exists(config['path']):
                    open(config['path'], 'w').close()
                    cleared.append(key)
            except Exception as e:
                errors.append(f'{key}: {e}')

    if errors:
        return jsonify({
            'status': 'partial',
            'message': f'Cleared {len(cleared)} logs with {len(errors)} errors',
            'cleared': cleared,
            'errors': errors
        })

    return jsonify({
        'status': 'ok',
        'message': f'Cleared {len(cleared)} log files',
        'cleared': cleared
    })


@app.route('/api/logs/download')
@login_required
def api_download_logs():
    """Download all logs as a zip file."""
    memory_file = io.BytesIO()

    with zipfile.ZipFile(memory_file, 'w', zipfile.ZIP_DEFLATED) as zf:
        # Add app logs
        if os.path.isdir(APP_LOG_DIR):
            for log_file in glob_module.glob(os.path.join(APP_LOG_DIR, '*.log')):
                try:
                    zf.write(log_file, f'app/{os.path.basename(log_file)}')
                except Exception:
                    pass

        # Add static log sources
        for key, config in LOG_SOURCES.items():
            if config.get('path') and os.path.exists(config['path']):
                try:
                    zf.write(config['path'], f'system/{os.path.basename(config["path"])}')
                except Exception:
                    pass

        # Add dmesg output
        try:
            result = subprocess.run(['dmesg'], capture_output=True, text=True, timeout=5)
            if result.returncode == 0:
                zf.writestr('system/dmesg.log', result.stdout)
        except Exception:
            pass

    memory_file.seek(0)
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')

    return send_file(
        memory_file,
        mimetype='application/zip',
        as_attachment=True,
        download_name=f'logs-{timestamp}.zip'
    )


@app.route('/api/factory-reset', methods=['POST'])
@login_required
def api_factory_reset():
    """Perform factory reset and reboot."""
    errors = perform_factory_reset()

    if errors:
        return jsonify({
            'status': 'error',
            'message': 'Factory reset completed with errors',
            'errors': errors
        }), 500

    # Schedule reboot
    try:
        subprocess.Popen(['reboot'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return jsonify({
            'status': 'success',
            'message': 'Factory reset complete. System will reboot now.'
        })
    except Exception as e:
        return jsonify({
            'status': 'error',
            'message': f'Factory reset complete but reboot failed: {e}'
        }), 500


@app.route('/api/reboot', methods=['POST'])
@login_required
def api_reboot():
    """Reboot the system."""
    try:
        subprocess.Popen(['reboot'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return jsonify({
            'status': 'success',
            'message': 'System will reboot now.'
        })
    except Exception as e:
        return jsonify({
            'status': 'error',
            'message': f'Reboot failed: {e}'
        }), 500


@app.route('/api/change-password', methods=['POST'])
@login_required
def api_change_password():
    """Change the password for the logged-in user."""
    username = session.get('username')
    client_ip = request.remote_addr

    # Get form data
    data = request.get_json() if request.is_json else request.form
    current_password = data.get('current_password', '')
    new_password = data.get('new_password', '')
    confirm_password = data.get('confirm_password', '')

    # Validate inputs
    if not current_password or not new_password or not confirm_password:
        return jsonify({
            'status': 'error',
            'message': 'All fields are required'
        }), 400

    if new_password != confirm_password:
        return jsonify({
            'status': 'error',
            'message': 'New passwords do not match'
        }), 400

    if len(new_password) < 4:
        return jsonify({
            'status': 'error',
            'message': 'Password must be at least 4 characters'
        }), 400

    # Verify current password
    if not verify_shadow_password(username, current_password):
        auth_logger.warning(f"Failed password change attempt for '{username}' from {client_ip} - wrong current password")
        return jsonify({
            'status': 'error',
            'message': 'Current password is incorrect'
        }), 401

    # Change password using chpasswd
    try:
        process = subprocess.run(
            ['chpasswd'],
            input=f'{username}:{new_password}\n',
            capture_output=True,
            text=True,
            timeout=10
        )

        if process.returncode != 0:
            auth_logger.error(f"Failed to change password for '{username}': {process.stderr}")
            return jsonify({
                'status': 'error',
                'message': 'Failed to change password'
            }), 500

        auth_logger.info(f"Password changed successfully for '{username}' from {client_ip}")
        return jsonify({
            'status': 'success',
            'message': 'Password changed successfully'
        })

    except subprocess.TimeoutExpired:
        return jsonify({
            'status': 'error',
            'message': 'Password change timed out'
        }), 500
    except Exception as e:
        auth_logger.error(f"Error changing password for '{username}': {e}")
        return jsonify({
            'status': 'error',
            'message': f'Failed to change password: {e}'
        }), 500


# App Manager API Routes

@app.route('/api/apps')
@login_required
def api_apps():
    """Return list of all applications with status."""
    result = app_manager_request('GET', '/apps')
    return jsonify(result)


@app.route('/api/apps/<app_name>')
@login_required
def api_app_status(app_name):
    """Return status of a specific application."""
    result = app_manager_request('GET', f'/apps/{app_name}')
    return jsonify(result)


@app.route('/api/apps/<app_name>/start', methods=['POST'])
@login_required
def api_app_start(app_name):
    """Start an application."""
    result = app_manager_request('POST', f'/apps/{app_name}/start')
    return jsonify(result)


@app.route('/api/apps/<app_name>/stop', methods=['POST'])
@login_required
def api_app_stop(app_name):
    """Stop an application."""
    result = app_manager_request('POST', f'/apps/{app_name}/stop')
    return jsonify(result)


@app.route('/api/apps/<app_name>/restart', methods=['POST'])
@login_required
def api_app_restart(app_name):
    """Restart an application."""
    result = app_manager_request('POST', f'/apps/{app_name}/restart')
    return jsonify(result)


@app.route('/api/apps/<app_name>/logs')
@login_required
def api_app_logs(app_name):
    """Get log content for an application."""
    lines = request.args.get('lines', 100, type=int)
    search = request.args.get('search', None, type=str)

    # Limit max lines
    lines = min(lines, 1000)

    log_path = f'{APP_LOG_DIR}/{app_name}.log'

    if not os.path.exists(log_path):
        return jsonify({
            'error': f'Log file not found: {log_path}',
            'lines': [],
            'total': 0
        })

    try:
        with open(log_path, 'r', errors='replace') as f:
            log_lines = f.readlines()
        log_lines = [line.rstrip('\n') for line in log_lines]

        # Filter by search term if provided
        if search:
            search_lower = search.lower()
            log_lines = [line for line in log_lines if search_lower in line.lower()]

        total = len(log_lines)

        # Return last N lines
        if lines > 0 and len(log_lines) > lines:
            log_lines = log_lines[-lines:]

        return jsonify({
            'lines': log_lines,
            'total': total,
            'returned': len(log_lines),
            'app': app_name
        })

    except PermissionError:
        return jsonify({'error': 'Permission denied', 'lines': [], 'total': 0})
    except Exception as e:
        return jsonify({'error': str(e), 'lines': [], 'total': 0})


# App Proxy Routes - Authenticate and forward requests to backend apps

@app.route('/app/<app_name>/', defaults={'path': ''})
@app.route('/app/<app_name>/<path:path>')
@login_required
def app_proxy(app_name, path):
    """
    Reverse proxy for application access.
    All requests to /app/<name>/* are authenticated and forwarded to the backend app.
    """
    # Reconstruct the path with leading slash
    forward_path = '/' + path if path else '/'

    # Add query string if present
    if request.query_string:
        forward_path += '?' + request.query_string.decode('utf-8')

    return proxy_request_to_app(app_name, forward_path)


@app.route('/app/<app_name>/<path:path>', methods=['POST', 'PUT', 'DELETE', 'PATCH'])
@login_required
def app_proxy_write(app_name, path):
    """
    Reverse proxy for write operations (POST, PUT, DELETE, PATCH).
    """
    forward_path = '/' + path if path else '/'

    if request.query_string:
        forward_path += '?' + request.query_string.decode('utf-8')

    return proxy_request_to_app(app_name, forward_path)


if __name__ == '__main__':
    # Use threaded mode for SSE support
    app.run(host='0.0.0.0', port=8000, debug=False, threaded=True)
