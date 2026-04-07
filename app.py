"""
edge_server.py — Edge Node RAM Monitor (Raspberry Pi 4B)
=========================================================
Modelo:  Pi liga → registra IP no servidor remoto (POST /register)
         Dashboard HTML puxa métricas do Pi via proxy no servidor,
         OU o Pi expõe diretamente e o servidor apenas mantém o IP.

Dois modos de operação (via ENV EDGE_MODE):
  "node"   → roda no Pi; expõe /metrics, /health, chama /register
  "hub"    → roda no servidor remoto; recebe /register, proxy /proxy/<token>

Por padrão sobe em modo "node".
"""

import os
import re
import socket
import subprocess
import threading
import time
import urllib.request
import json
from datetime import datetime, timezone
from flask import Flask, jsonify, render_template_string, request, Response

app = Flask(__name__)

# ─── Config ──────────────────────────────────────────────────────────────────
EDGE_MODE    = os.environ.get("EDGE_MODE", "node").lower()   # "node" | "hub"
ACCESS_TOKEN = os.environ.get("EDGE_TOKEN", "").strip()
HUB_URL      = os.environ.get("HUB_URL", "").strip()         # usado no Pi
BASE_DIR     = os.path.dirname(os.path.abspath(__file__))
BIN_PATH     = os.path.join(BASE_DIR, "bin", "ram_integrity")

# Hub armazena {token: {"ip": ..., "port": ..., "last_seen": ...}}
_registry: dict = {}
_registry_lock = threading.Lock()

# ─── Helpers ─────────────────────────────────────────────────────────────────

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def token_ok(req) -> bool:
    if not ACCESS_TOKEN:
        return True
    return (req.headers.get("X-EDGE-TOKEN", "").strip() == ACCESS_TOKEN or
            req.args.get("token", "").strip() == ACCESS_TOKEN)


def run_monitor() -> str:
    """Executa o binário Assembly e retorna stdout."""
    result = subprocess.run(
        [BIN_PATH],
        capture_output=True, text=True, timeout=10, check=True
    )
    return result.stdout


def parse_output(raw: str) -> dict:
    """
    Parseia saída do novo binário Assembly:
      MEMTOTAL:<kB>
      MEMAVAIL:<kB>
      PROBE_PAGES:<n>
      PROBE_ERRORS:<n>
      STATUS:OK|FAIL
    Também suporta formato legado (/proc/meminfo raw) como fallback.
    """
    def field(key):
        m = re.search(rf"^{key}:(\d+)", raw, re.MULTILINE)
        return int(m.group(1)) if m else None

    mem_total_kb    = field("MEMTOTAL")
    mem_available_kb = field("MEMAVAIL")

    # fallback para formato legado
    if mem_total_kb is None:
        m = re.search(r"^MemTotal:\s+(\d+)\s+kB", raw, re.MULTILINE)
        mem_total_kb = int(m.group(1)) if m else 0
    if mem_available_kb is None:
        m = re.search(r"^MemAvailable:\s+(\d+)\s+kB", raw, re.MULTILINE)
        mem_available_kb = int(m.group(1)) if m else 0

    probe_pages  = field("PROBE_PAGES")
    probe_errors = field("PROBE_ERRORS")
    status_line  = re.search(r"^STATUS:(OK|FAIL)", raw, re.MULTILINE)
    integrity    = status_line.group(1) if status_line else "UNKNOWN"

    mem_used_kb      = mem_total_kb - mem_available_kb
    mem_used_percent = round((mem_used_kb / mem_total_kb) * 100, 2) if mem_total_kb else 0

    return {
        "mem_total_kb":      mem_total_kb,
        "mem_available_kb":  mem_available_kb,
        "mem_used_kb":       mem_used_kb,
        "mem_used_percent":  mem_used_percent,
        "probe_pages":       probe_pages,
        "probe_errors":      probe_errors,
        "integrity":         integrity,
    }

# ─── Registro automático no Hub ──────────────────────────────────────────────

def _get_local_ip() -> str:
    """Obtém o IP local que roteia para a internet (sem enviar pacotes)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return socket.gethostbyname(socket.gethostname())


def _register_loop():
    """Thread: registra o Pi no Hub a cada 30 s."""
    if not HUB_URL:
        return
    port = int(os.environ.get("PORT", 5000))
    payload = json.dumps({
        "token": ACCESS_TOKEN or "anonymous",
        "ip":    _get_local_ip(),
        "port":  port,
    }).encode()

    while True:
        try:
            req = urllib.request.Request(
                f"{HUB_URL.rstrip('/')}/register",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            urllib.request.urlopen(req, timeout=5)
        except Exception as e:
            print(f"[register] erro: {e}")
        time.sleep(30)

# ─── Rotas NODE ──────────────────────────────────────────────────────────────

@app.route("/health")
def health():
    return jsonify({
        "status":    "ok",
        "mode":      EDGE_MODE,
        "service":   "edge-node",
        "hostname":  socket.gethostname(),
        "local_ip":  _get_local_ip(),
        "timestamp": utc_now(),
    })


@app.route("/metrics")
def metrics():
    if not token_ok(request):
        return jsonify({"error": "unauthorized"}), 401
    try:
        raw    = run_monitor()
        parsed = parse_output(raw)
        return jsonify({
            "status":    "ok",
            "node":      socket.gethostname(),
            "local_ip":  _get_local_ip(),
            "timestamp": utc_now(),
            **parsed,
            "_raw": raw,
        })
    except subprocess.TimeoutExpired:
        return jsonify({"status": "error", "message": "timeout no binário"}), 504
    except subprocess.CalledProcessError as exc:
        return jsonify({"status": "error", "message": "falha no binário", "stderr": exc.stderr}), 500
    except Exception as exc:
        return jsonify({"status": "error", "message": str(exc)}), 500


@app.route("/view")
def view():
    """Retorna o dashboard HTML completo (servido pelo Pi)."""
    if not token_ok(request):
        return "Unauthorized", 401
    # O template está em template_str abaixo
    try:
        raw    = run_monitor()
        parsed = parse_output(raw)
        ctx = {
            "metrics":   parsed,
            "hostname":  socket.gethostname(),
            "local_ip":  _get_local_ip(),
            "timestamp": utc_now(),
            "raw":       raw,
            "error":     None,
        }
    except Exception as exc:
        ctx = {"error": str(exc), "metrics": None}
    return render_template_string(DASHBOARD_TEMPLATE, **ctx)


@app.route("/")
def index():
    if EDGE_MODE == "hub":
        return hub_dashboard()
    return view()

# ─── Rotas HUB ───────────────────────────────────────────────────────────────

@app.route("/register", methods=["POST"])
def register():
    """Pi chama este endpoint ao inicializar e a cada 30 s."""
    data  = request.get_json(force=True, silent=True) or {}
    token = data.get("token", "anonymous")
    ip    = data.get("ip") or request.remote_addr
    port  = int(data.get("port", 5000))
    with _registry_lock:
        _registry[token] = {"ip": ip, "port": port, "last_seen": utc_now()}
    return jsonify({"status": "registered", "ip": ip})


@app.route("/nodes")
def nodes():
    """Lista todos os nós registrados."""
    with _registry_lock:
        return jsonify(list(_registry.values()))


@app.route("/proxy/<token>/metrics")
def proxy_metrics(token):
    """Faz proxy da requisição /metrics para o Pi correto."""
    with _registry_lock:
        node = _registry.get(token)
    if not node:
        return jsonify({"error": "node not found"}), 404
    url = f"http://{node['ip']}:{node['port']}/metrics"
    try:
        resp = urllib.request.urlopen(url, timeout=8)
        body = resp.read()
        return Response(body, content_type="application/json")
    except Exception as e:
        return jsonify({"error": str(e)}), 502


def hub_dashboard():
    return render_template_string(HUB_TEMPLATE, nodes=list(_registry.values()))

# ─── Templates ───────────────────────────────────────────────────────────────

DASHBOARD_TEMPLATE = r"""<!DOCTYPE html><html>
<head><meta charset="UTF-8"><title>Edge RAM Monitor</title>
<style>
  /* Inlined; o arquivo completo está em templates/index.html */
  body{font-family:monospace;background:#080c14;color:#c9d8ee;margin:0;padding:2rem}
  .kv{display:flex;gap:.5rem;margin:.3rem 0}
  .k{color:#4a9eff;min-width:18ch}
  .v{color:#e2f0ff}
  .ok{color:#22d36b}
  .fail{color:#ff4a4a}
  pre{background:#0d1524;border:1px solid #1e2d46;padding:1rem;border-radius:8px;
      overflow-x:auto;font-size:.8rem;color:#7fa8d0}
</style>
</head>
<body>
{% if error %}
  <p class="fail">ERRO: {{ error }}</p>
{% else %}
  <h2>RAM Integrity — {{ hostname }} ({{ local_ip }})</h2>
  <p style="color:#4a9eff;font-size:.85rem">{{ timestamp }}</p>
  <div class="kv"><span class="k">MemTotal</span><span class="v">{{ metrics.mem_total_kb }} kB</span></div>
  <div class="kv"><span class="k">MemAvailable</span><span class="v">{{ metrics.mem_available_kb }} kB</span></div>
  <div class="kv"><span class="k">MemUsed</span><span class="v">{{ metrics.mem_used_kb }} kB ({{ metrics.mem_used_percent }}%)</span></div>
  <div class="kv"><span class="k">Probe Pages</span><span class="v">{{ metrics.probe_pages }}</span></div>
  <div class="kv"><span class="k">Probe Errors</span><span class="v">{{ metrics.probe_errors }}</span></div>
  <div class="kv"><span class="k">Integrity</span>
    <span class="{{ 'ok' if metrics.integrity == 'OK' else 'fail' }}">{{ metrics.integrity }}</span></div>
  <details><summary style="color:#4a9eff;cursor:pointer;margin-top:1rem">Saída bruta do Assembly</summary>
  <pre>{{ raw }}</pre></details>
{% endif %}
</body></html>"""

HUB_TEMPLATE = r"""<!DOCTYPE html><html>
<head><meta charset="UTF-8"><title>Edge Hub</title>
<style>body{font-family:monospace;background:#080c14;color:#c9d8ee;padding:2rem}
a{color:#4a9eff}</style></head>
<body><h2>Nós registrados</h2>
{% for n in nodes %}
<p>{{ n.ip }}:{{ n.port }} — last seen {{ n.last_seen }} —
<a href="/proxy/{{ n.token }}/metrics">metrics</a></p>
{% else %}<p>Nenhum nó registrado ainda.</p>{% endfor %}
</body></html>"""

# ─── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5000))

    if EDGE_MODE == "node" and HUB_URL:
        t = threading.Thread(target=_register_loop, daemon=True)
        t.start()
        print(f"[node] registrando em {HUB_URL} a cada 30 s")

    print(f"[edge] modo={EDGE_MODE}  porta={port}")
    app.run(host="0.0.0.0", port=port, debug=False)