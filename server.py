#!/usr/bin/env python3
"""
Pi Edge Node — Servidor Flask
Rotas: / (dashboard), /health (JSON), /metrics (JSON)
"""

import os
import time
import subprocess
from flask import Flask, jsonify, send_from_directory

app = Flask(__name__)
START_TIME = time.time()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")


def get_memory():
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                parts = line.split()
                if parts[0] in ("MemTotal:", "MemAvailable:", "MemFree:"):
                    mem[parts[0].rstrip(":")] = int(parts[1]) // 1024
    except Exception:
        mem = {"MemTotal": 0, "MemAvailable": 0, "MemFree": 0}
    return mem


def get_cpu_temp():
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            return round(int(f.read()) / 1000, 1)
    except Exception:
        return None


def get_cpu_load():
    try:
        with open("/proc/loadavg") as f:
            return float(f.read().split()[0])
    except Exception:
        return None


def get_uptime_seconds():
    try:
        with open("/proc/uptime") as f:
            return float(f.read().split()[0])
    except Exception:
        return 0


def get_connected_clients():
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            return len([l for l in f.readlines() if l.strip()])
    except Exception:
        return None


def format_uptime(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_tailscale_ip():
    try:
        r = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True, text=True, timeout=2
        )
        return r.stdout.strip() or None
    except Exception:
        return None


@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "online.html")


@app.route("/offline")
def offline():
    return send_from_directory(STATIC_DIR, "offline.html")


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "node": "rpi4b-edge-01",
        "uptime": format_uptime(get_uptime_seconds()),
        "timestamp": int(time.time())
    })


@app.route("/metrics")
def metrics():
    mem = get_memory()
    uptime_s = get_uptime_seconds()
    server_uptime_s = time.time() - START_TIME
    return jsonify({
        "node": "rpi4b-edge-01",
        "timestamp": int(time.time()),
        "uptime": {
            "system_seconds":   int(uptime_s),
            "system_formatted": format_uptime(uptime_s),
            "server_seconds":   int(server_uptime_s),
            "server_formatted": format_uptime(server_uptime_s)
        },
        "memory": {
            "total_mb":     mem.get("MemTotal", 0),
            "available_mb": mem.get("MemAvailable", 0),
            "free_mb":      mem.get("MemFree", 0),
            "used_mb":      mem.get("MemTotal", 0) - mem.get("MemAvailable", 0),
            "percent_used": round(
                (1 - mem.get("MemAvailable", 1) / max(mem.get("MemTotal", 1), 1)) * 100, 1
            )
        },
        "cpu": {
            "temp_celsius": get_cpu_temp(),
            "load_1min":    get_cpu_load()
        },
        "network": {
            "ap_clients":   get_connected_clients(),
            "tailscale_ip": get_tailscale_ip()
        }
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[Pi Edge Node] Servidor iniciando na porta {port}")
    app.run(host="0.0.0.0", port=port, debug=False)