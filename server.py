#!/usr/bin/env python3
"""
Pi Edge Node — Flask Server
  wlan1 → internet (USB LV-UW06 / rtl8xxxu) → Bruno Dratcu
  wlan0 → AP PiEdge-Net (10.0.0.x)
"""
import os, time, subprocess
from flask import Flask, jsonify, send_from_directory

app        = Flask(__name__)
START_TIME = time.time()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")

WAN = os.environ.get("WAN_IFACE", "wlan1")
AP  = os.environ.get("AP_IFACE",  "wlan0")


def clients():
    out = []
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            for line in f:
                parts = line.strip().split()
                if len(parts) >= 4:
                    out.append({
                        "mac": parts[1],
                        "ip": parts[2],
                        "hostname": parts[3]
                    })
    except:
        pass
    return out

def _read(p, d=None):
    try:
        with open(p) as f: return f.read().strip()
    except: return d

def _run(*cmd):
    try:
        r = subprocess.run(list(cmd), capture_output=True, text=True, timeout=2)
        return r.stdout.strip()
    except: return ""

def fmt(s):
    return f"{int(s//3600):02d}:{int((s%3600)//60):02d}:{int(s%60):02d}"

def memory():
    m = {}
    try:
        for line in open("/proc/meminfo"):
            k,*v = line.split()
            if k in ("MemTotal:","MemAvailable:","MemFree:"):
                m[k.rstrip(":")] = int(v[0])//1024
    except: pass
    return m

def iface_ip(i):
    for line in _run("ip","-4","addr","show",i).splitlines():
        if line.strip().startswith("inet "):
            return line.strip().split()[1].split("/")[0]
    return None

def iface_state(i): return _read(f"/sys/class/net/{i}/operstate","unknown")
def iface_rx(i):
    v=_read(f"/sys/class/net/{i}/statistics/rx_bytes")
    return round(int(v)/1024/1024,2) if v else 0
def iface_tx(i):
    v=_read(f"/sys/class/net/{i}/statistics/tx_bytes")
    return round(int(v)/1024/1024,2) if v else 0

def ap_clients():
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            return len([l for l in f if l.strip()])
    except: return None


@app.route("/clients")
def get_clients():
    return jsonify({
        "count": len(clients()),
        "devices": clients()
    })

@app.route("/")
def index(): return send_from_directory(STATIC_DIR,"online.html")

@app.route("/offline")
def offline(): return send_from_directory(STATIC_DIR,"offline.html")

@app.route("/health")
def health():
    return jsonify({"status":"ok","node":"rpi4b-edge-01",
                    "uptime":fmt(time.time()-START_TIME),
                    "timestamp":int(time.time())})

@app.route("/metrics")
def metrics():
    mem=memory()
    up=float(_read("/proc/uptime","0").split()[0])
    srv=time.time()-START_TIME
    total=max(mem.get("MemTotal",1),1)
    avail=mem.get("MemAvailable",0)
    temp=_read("/sys/class/thermal/thermal_zone0/temp")
    load=_read("/proc/loadavg")
    return jsonify({
        "node":"rpi4b-edge-01","timestamp":int(time.time()),
        "uptime":{"system":fmt(up),"server":fmt(srv)},
        "memory":{
            "total_mb":mem.get("MemTotal",0),
            "available_mb":avail,
            "used_mb":mem.get("MemTotal",0)-avail,
            "percent_used":round((1-avail/total)*100,1)
        },
        "cpu":{
            "temp_celsius":round(int(temp)/1000,1) if temp else None,
            "load_1min":float(load.split()[0]) if load else None
        },
        "network":{
            "wan":{
                "interface":WAN,
                "chip":"Realtek rtl8xxxu",
                "ip":iface_ip(WAN),
                "state":iface_state(WAN),
                "ssid":_run("iwgetid",WAN,"--raw") or None,
                "rx_mb":iface_rx(WAN),
                "tx_mb":iface_tx(WAN)
            },
            "ap":{
                "interface":AP,
                "ssid":"PiEdge-Net",
                "ip":iface_ip(AP),
                "state":iface_state(AP),
                "clients":ap_clients(),
                "rx_mb":iface_rx(AP),
                "tx_mb":iface_tx(AP)
            },
            "tailscale_ip":(_run("tailscale","ip","-4") or None)
        }
    })


def internet_ok():
    try:
        subprocess.run(
            ["ping", "-c", "1", "-W", "1", "8.8.8.8"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        return True
    except:
        return False

@app.route("/status")
def status():
    return jsonify({
        "wan_ok": internet_ok(),
        "wan_ip": iface_ip(WAN),
        "ap_ip": iface_ip(AP),
        "ap_clients": len(clients()),
        "uptime": fmt(time.time() - START_TIME)
    })


if __name__=="__main__":
    port=int(os.environ.get("PORT",5000))
    print(f"[Pi Edge Node] :{port}  WAN={WAN} AP={AP}")
    app.run(host="0.0.0.0",port=port,debug=False)