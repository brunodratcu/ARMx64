#!/usr/bin/env python3
import os, time, subprocess
from flask import Flask, jsonify, send_from_directory

app        = Flask(__name__)
START_TIME = time.time()
STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
WAN = os.environ.get("WAN_IFACE", "wlan1")
ETH = os.environ.get("ETH_IFACE", "eth0")
AP  = os.environ.get("AP_IFACE",  "wlan0")

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
    v=_read(f"/sys/class/net/{i}/statistics/rx_bytes"); return round(int(v)/1024/1024,2) if v else 0
def iface_tx(i):
    v=_read(f"/sys/class/net/{i}/statistics/tx_bytes"); return round(int(v)/1024/1024,2) if v else 0

def ap_clients():
    try:
        with open("/var/lib/misc/dnsmasq.leases") as f:
            return len([l for l in f if l.strip()])
    except: return None

def eth_hosts():
    out = _run("arp","-i",ETH,"-n")
    return sum(1 for l in out.splitlines()
               if ":" in l and "incomplete" not in l and "Address" not in l)

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
    mem=memory(); up=float(_read("/proc/uptime","0").split()[0])
    srv=time.time()-START_TIME
    total=max(mem.get("MemTotal",1),1); avail=mem.get("MemAvailable",0)
    return jsonify({
        "node":"rpi4b-edge-01","timestamp":int(time.time()),
        "uptime":{"system":fmt(up),"server":fmt(srv)},
        "memory":{"total_mb":mem.get("MemTotal",0),"available_mb":avail,
                  "used_mb":mem.get("MemTotal",0)-avail,
                  "percent_used":round((1-avail/total)*100,1)},
        "cpu":{"temp_celsius":(_read("/sys/class/thermal/thermal_zone0/temp") and
                               round(int(_read("/sys/class/thermal/thermal_zone0/temp"))/1000,1)),
               "load_1min":(lambda v: float(v.split()[0]) if v else None)(_read("/proc/loadavg"))},
        "network":{
            "wan":{"interface":WAN,"chip":"Ralink RT5370","driver":"rt2800usb",
                   "ip":iface_ip(WAN),"state":iface_state(WAN),
                   "ssid":_run("iwgetid",WAN,"--raw") or None,
                   "rx_mb":iface_rx(WAN),"tx_mb":iface_tx(WAN)},
            "eth":{"interface":ETH,"ip":iface_ip(ETH),"state":iface_state(ETH),
                   "active_hosts":eth_hosts(),"rx_mb":iface_rx(ETH),"tx_mb":iface_tx(ETH)},
            "ap":{"interface":AP,"ssid":"PiEdge-Net","ip":iface_ip(AP),
                  "state":iface_state(AP),"clients":ap_clients(),
                  "rx_mb":iface_rx(AP),"tx_mb":iface_tx(AP)},
            "tailscale_ip":(_run("tailscale","ip","-4") or None)
        }
    })

if __name__=="__main__":
    port=int(os.environ.get("PORT",5000))
    print(f"[Pi Edge Node] :{port}  WAN={WAN} ETH={ETH} AP={AP}")
    app.run(host="0.0.0.0",port=port,debug=False)