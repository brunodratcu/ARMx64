#!/usr/bin/env python3
"""
Pi Edge Node — Flask Server v3
Adaptador: LV-UW06 (Ralink RT5370, driver rt2800usb)

Interfaces:
  wlan1 (USB LV-UW06) — cliente Wi-Fi, fonte de internet
  eth0                — saída cabeada para PC (192.168.50.x)
  wlan0               — Access Point interno (10.0.0.x)

Rotas:
  /            → dashboard (online.html)
  /offline     → página offline
  /health      → JSON status rápido
  /metrics     → JSON métricas completas
  /iface/<n>   → JSON de uma interface específica
"""

import os
import time
import subprocess
from flask import Flask, jsonify, send_from_directory

app = Flask(__name__)
START_TIME = time.time()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

# Interfaces — podem ser sobrescritas por variáveis de ambiente
WAN_IFACE = os.environ.get("WAN_IFACE", "wlan1")   # USB LV-UW06
ETH_IFACE = os.environ.get("ETH_IFACE", "eth0")    # cabo para PC
AP_IFACE  = os.environ.get("AP_IFACE",  "wlan0")   # AP interno


# ── Helpers de sistema ───────────────────────────────────────

def read_file(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def run_cmd(cmd, timeout=2):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


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
    val = read_file("/sys/class/thermal/thermal_zone0/temp")
    return round(int(val) / 1000, 1) if val else None


def get_cpu_load():
    val = read_file("/proc/loadavg")
    return float(val.split()[0]) if val else None


def get_uptime_seconds():
    val = read_file("/proc/uptime")
    return float(val.split()[0]) if val else 0.0


def format_uptime(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    return f"{h:02d}:{m:02d}:{s:02d}"


def get_tailscale_ip():
    out = run_cmd(["tailscale", "ip", "-4"])
    return out or None


# ── Helpers de interface ─────────────────────────────────────

def get_iface_ip(iface):
    out = run_cmd(["ip", "-4", "addr", "show", iface])
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("inet "):
            return line.split()[1].split("/")[0]
    return None


def get_iface_state(iface):
    return read_file(f"/sys/class/net/{iface}/operstate", "unknown")


def get_iface_mac(iface):
    return read_file(f"/sys/class/net/{iface}/address", None)


def get_iface_rx_bytes(iface):
    val = read_file(f"/sys/class/net/{iface}/statistics/rx_bytes")
    return int(val) if val else 0


def get_iface_tx_bytes(iface):
    val = read_file(f"/sys/class/net/{iface}/statistics/tx_bytes")
    return int(val) if val else 0


def get_wifi_signal(iface):
    """Sinal em dBm da conexão Wi-Fi (wlan1 como cliente)."""
    out = run_cmd(["iwconfig", iface])
    for line in out.splitlines():
        if "Signal level" in line:
            try:
                part = [p for p in line.split() if "Signal" in p or "level" in p]
                for i, token in enumerate(line.split()):
                    if "level=" in token:
                        return token.split("=")[1].replace("dBm", "").strip()
            except Exception:
                pass
    return None


def get_wifi_ssid(iface):
    """SSID ao qual wlan1 está conectado."""
    out = run_cmd(["iwgetid", iface, "--raw"])
    return out or None


def get_ap_clients():
    """Clientes DHCP ativos no AP (wlan0)."""
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            return len([l for l in f.readlines() if l.strip()])
    except Exception:
        return None


def get_eth_hosts():
    """Hosts ativos na rede eth0 via tabela ARP."""
    out = run_cmd(["arp", "-i", ETH_IFACE, "-n"])
    count = sum(
        1 for l in out.splitlines()
        if ":" in l and "incomplete" not in l and "Address" not in l
    )
    return count


def iface_info(iface, role):
    """Retorna dict completo de métricas para uma interface."""
    base = {
        "interface": iface,
        "role":      role,
        "ip":        get_iface_ip(iface),
        "mac":       get_iface_mac(iface),
        "state":     get_iface_state(iface),
        "rx_mb":     round(get_iface_rx_bytes(iface) / 1024 / 1024, 2),
        "tx_mb":     round(get_iface_tx_bytes(iface) / 1024 / 1024, 2),
    }
    if role == "wan":
        base["ssid"]   = get_wifi_ssid(iface)
        base["signal"] = get_wifi_signal(iface)
        base["driver"] = "rt2800usb"
        base["chip"]   = "Ralink RT5370"
    elif role == "eth":
        base["active_hosts"] = get_eth_hosts()
        base["dhcp_range"]   = "192.168.50.10–50"
    elif role == "ap":
        base["ssid"]       = "PiEdge-Net"
        base["clients"]    = get_ap_clients()
        base["dhcp_range"] = "10.0.0.10–100"
    return base


# ── Rotas ────────────────────────────────────────────────────

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
        "uptime":    format_uptime(get_uptime_seconds()),
        "timestamp": int(time.time())
    })


@app.route("/metrics")
def metrics():
    mem        = get_memory()
    uptime_s   = get_uptime_seconds()
    srv_uptime = time.time() - START_TIME

    return jsonify({
        "node":      "rpi4b-edge-01",
        "timestamp": int(time.time()),
        "uptime": {
            "system_seconds":   int(uptime_s),
            "system_formatted": format_uptime(uptime_s),
            "server_seconds":   int(srv_uptime),
            "server_formatted": format_uptime(srv_uptime)
        },
        "memory": {
            "total_mb":     mem.get("MemTotal", 0),
            "available_mb": mem.get("MemAvailable", 0),
            "free_mb":      mem.get("MemFree", 0),
            "used_mb":      mem.get("MemTotal", 0) - mem.get("MemAvailable", 0),
            "percent_used": round(
                (1 - mem.get("MemAvailable", 1) /
                 max(mem.get("MemTotal", 1), 1)) * 100, 1
            )
        },
        "cpu": {
            "temp_celsius": get_cpu_temp(),
            "load_1min":    get_cpu_load()
        },
        "network": {
            "wan":          iface_info(WAN_IFACE, "wan"),
            "eth":          iface_info(ETH_IFACE, "eth"),
            "ap":           iface_info(AP_IFACE,  "ap"),
            "tailscale_ip": get_tailscale_ip()
        }
    })


@app.route("/iface/<name>")
def iface_detail(name):
    """Métricas de uma interface específica pelo nome."""
    roles = {WAN_IFACE: "wan", ETH_IFACE: "eth", AP_IFACE: "ap"}
    role  = roles.get(name, "unknown")
    return jsonify(iface_info(name, role))


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))
    print(f"[Pi Edge Node v3] Porta {port}")
    print(f"  WAN : {WAN_IFACE} (USB LV-UW06 / RT5370 / rt2800usb)")
    print(f"  ETH : {ETH_IFACE} (cabo → PC, 192.168.50.x)")
    print(f"  AP  : {AP_IFACE}  (PiEdge-Net, 10.0.0.x)")
    app.run(host="0.0.0.0", port=port, debug=False)