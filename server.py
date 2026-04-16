#!/usr/bin/env python3
"""
Pi Edge Node — Flask Server v4
  wlan1 → internet (USB LV-UW06 / RT5370)
  eth0  → cabo para PC (192.168.50.x)
  wlan0 → AP PiEdge-Net (10.0.0.x)
"""
import os, time, subprocess
from flask import Flask, jsonify, send_from_directory

app        = Flask(__name__)
START_TIME = time.time()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

WAN = os.environ.get("WAN_IFACE", "wlan1")
ETH = os.environ.get("ETH_IFACE", "eth0")
AP  = os.environ.get("AP_IFACE",  "wlan0")


# ── helpers ──────────────────────────────────────────────────

def _read(path, default=None):
    try:
        with open(path) as f: return f.read().strip()
    except Exception: return default

def _run(*cmd, timeout=2):
    try:
        r = subprocess.run(list(cmd), capture_output=True,
                           text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception: return ""

def fmt_uptime(s):
    return f"{int(s//3600):02d}:{int((s%3600)//60):02d}:{int(s%60):02d}"

def memory():
    m = {}
    try:
        for line in open("/proc/meminfo"):
            k, *v = line.split()
            if k in ("MemTotal:","MemAvailable:","MemFree:"):
                m[k.rstrip(":")] = int(v[0]) // 1024
    except Exception: pass
    return m

def cpu_temp():
    v = _read("/sys/class/thermal/thermal_zone0/temp")
    return round(int(v)/1000, 1) if v else None

def cpu_load():
    v = _read("/proc/loadavg")
    return float(v.split()[0]) if v else None

def uptime_s():
    v = _read("/proc/uptime")
    return float(v.split()[0]) if v else 0.0

def iface_ip(i):
    for line in _run("ip","-4","addr","show",i).splitlines():
        line = line.strip()
        if line.startswith("inet "):
            return line.split()[1].split("/")[0]
    return None

def iface_state(i):
    return _read(f"/sys/class/net/{i}/operstate", "unknown")

def iface_rx(i):
    v = _read(f"/sys/class/net/{i}/statistics/rx_bytes")
    return round(int(v)/1024/1024, 2) if v else 0

def iface_tx(i):
    v = _read(f"/sys/class/net/{i}/statistics/tx_bytes")
    return round(int(v)/1024/1024, 2) if v else 0

def wan_ssid():
    return _run("iwgetid", WAN, "--raw") or None

def wan_signal():
    for line in _run("iwconfig", WAN).splitlines():
        if "Signal level=" in line:
            try:
                return line.split("Signal level=")[1].split()[0]
            except Exception: pass
    return None

def ap_clients():
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            return len([l for l in f if l.strip()])
    except Exception: return None

def eth_hosts():
    out = _run("arp", "-i", ETH, "-n")
    return sum(1 for l in out.splitlines()
               if ":" in l and "incomplete" not in l
               and "Address" not in l)

def tailscale_ip():
    return _run("tailscale", "ip", "-4") or None


# ── rotas ────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_from_directory(STATIC_DIR, "online.html")

@app.route("/offline")
def offline():
    return send_from_directory(STATIC_DIR, "offline.html")

@app.route("/health")
def health():
    return jsonify({
        "status":    "ok",
        "node":      "rpi4b-edge-01",
        "uptime":    fmt_uptime(uptime_s()),
        "timestamp": int(time.time())
    })

@app.route("/metrics")
def metrics():
    mem = memory()
    up  = uptime_s()
    srv = time.time() - START_TIME
    total = max(mem.get("MemTotal", 1), 1)
    avail = mem.get("MemAvailable", 0)

    return jsonify({
        "node":      "rpi4b-edge-01",
        "timestamp": int(time.time()),
        "uptime": {
            "system_s":   int(up),   "system":  fmt_uptime(up),
            "server_s":   int(srv),  "server":  fmt_uptime(srv)
        },
        "memory": {
            "total_mb":    mem.get("MemTotal", 0),
            "available_mb":avail,
            "used_mb":     mem.get("MemTotal", 0) - avail,
            "percent_used":round((1 - avail/total)*100, 1)
        },
        "cpu": {
            "temp_celsius": cpu_temp(),
            "load_1min":    cpu_load()
        },
        "network": {
            "wan": {
                "interface": WAN,
                "chip":      "Ralink RT5370",
                "driver":    "rt2800usb",
                "ip":        iface_ip(WAN),
                "state":     iface_state(WAN),
                "ssid":      wan_ssid(),
                "signal":    wan_signal(),
                "rx_mb":     iface_rx(WAN),
                "tx_mb":     iface_tx(WAN)
            },
            "eth": {
                "interface":    ETH,
                "ip":           iface_ip(ETH),
                "state":        iface_state(ETH),
                "active_hosts": eth_hosts(),
                "rx_mb":        iface_rx(ETH),
                "tx_mb":        iface_tx(ETH)
            },
            "ap": {
                "interface": AP,
                "ssid":      "PiEdge-Net",
                "ip":        iface_ip(AP),
                "state":     iface_state(AP),
                "clients":   ap_clients(),
                "rx_mb":     iface_rx(AP),
                "tx_mb":     iface_tx(AP)
            },
            "tailscale_ip": tailscale_ip()
        }
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[Pi Edge Node v4] :{port}")
    print(f"  WAN={WAN} (RT5370)  ETH={ETH}  AP={AP}")
    app.run(host="0.0.0.0", port=port, debug=False)