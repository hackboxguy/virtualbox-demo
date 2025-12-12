#!/usr/bin/env python3
"""
System Management Web Application

This Flask application provides system monitoring and management endpoints
for the VirtualBox Alpine demo image.

Features:
    - Real-time system stats via Server-Sent Events (SSE)
    - Dashboard with live CPU, memory, disk, and network monitoring
    - Factory reset and reboot capabilities

Endpoints:
    GET  /                      - Dashboard HTML page
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
"""

import os
import subprocess
import json
import time
from datetime import datetime
from flask import Flask, jsonify, render_template, request, Response

app = Flask(__name__)

# Configuration
VERSION_FILE = '/etc/image-version'
DATA_PARTITION = '/data'
OVERLAY_UPPER = '/data/overlay/upper'
OVERLAY_WORK = '/data/overlay/work'

# CPU stats tracking for percentage calculation
_prev_cpu_stats = None
_prev_cpu_time = None


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


def perform_factory_reset():
    """Perform factory reset by clearing overlay directories."""
    errors = []

    # Clear overlay upper directory
    if os.path.exists(OVERLAY_UPPER):
        try:
            for item in os.listdir(OVERLAY_UPPER):
                path = os.path.join(OVERLAY_UPPER, item)
                if os.path.isdir(path):
                    subprocess.run(['rm', '-rf', path], check=True)
                else:
                    os.remove(path)
        except Exception as e:
            errors.append(f"Failed to clear overlay upper: {e}")

    # Clear overlay work directory
    if os.path.exists(OVERLAY_WORK):
        try:
            for item in os.listdir(OVERLAY_WORK):
                path = os.path.join(OVERLAY_WORK, item)
                if os.path.isdir(path):
                    subprocess.run(['rm', '-rf', path], check=True)
                else:
                    os.remove(path)
        except Exception as e:
            errors.append(f"Failed to clear overlay work: {e}")

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

@app.route('/')
def index():
    """Render the dashboard page."""
    return render_template('index.html')


@app.route('/api/stream')
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
def api_version():
    """Return version information."""
    return jsonify(read_version_info())


@app.route('/api/system/info')
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
def api_disk():
    """Return disk usage information."""
    return jsonify(get_disk_usage())


@app.route('/api/system/cpu')
def api_cpu():
    """Return CPU load information."""
    return jsonify(get_cpu_load())


@app.route('/api/system/memory')
def api_memory():
    """Return memory usage information."""
    return jsonify(get_memory_info())


@app.route('/api/system/uptime')
def api_uptime():
    """Return system uptime."""
    return jsonify(get_uptime())


@app.route('/api/system/hostname')
def api_hostname():
    """Return system hostname."""
    return jsonify({'hostname': get_hostname()})


@app.route('/api/system/network')
def api_network():
    """Return network information."""
    return jsonify(get_network_info())


@app.route('/api/factory-reset', methods=['POST'])
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


if __name__ == '__main__':
    # Use threaded mode for SSE support
    app.run(host='0.0.0.0', port=8000, debug=False, threaded=True)
