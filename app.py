import os
import re
import socket
import subprocess
from datetime import datetime
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
BIN_PATH = os.path.join(BASE_DIR, "bin", "monitor")

ACCESS_TOKEN = os.environ.get("EDGE_TOKEN", "").strip()


def run_monitor() -> str:
    """
    Executa o binário em assembly e retorna o stdout bruto.
    """
    result = subprocess.run(
        [BIN_PATH],
        capture_output=True,
        text=True,
        timeout=5,
        check=True
    )
    return result.stdout


def parse_meminfo(raw: str) -> dict:
    """
    Extrai MemTotal e MemAvailable do conteúdo de /proc/meminfo.
    """
    total_match = re.search(r"^MemTotal:\s+(\d+)\s+kB", raw, re.MULTILINE)
    avail_match = re.search(r"^MemAvailable:\s+(\d+)\s+kB", raw, re.MULTILINE)

    if not total_match or not avail_match:
        raise ValueError("Não foi possível extrair MemTotal/MemAvailable do meminfo.")

    mem_total_kb = int(total_match.group(1))
    mem_available_kb = int(avail_match.group(1))
    mem_used_kb = mem_total_kb - mem_available_kb
    mem_used_percent = round((mem_used_kb / mem_total_kb) * 100, 2)

    return {
        "mem_total_kb": mem_total_kb,
        "mem_available_kb": mem_available_kb,
        "mem_used_kb": mem_used_kb,
        "mem_used_percent": mem_used_percent
    }


def token_ok(req) -> bool:
    """
    Validação opcional por token.
    Se EDGE_TOKEN estiver vazio, não exige autenticação.
    """
    if not ACCESS_TOKEN:
        return True

    header_token = req.headers.get("X-EDGE-TOKEN", "").strip()
    query_token = req.args.get("token", "").strip()

    return header_token == ACCESS_TOKEN or query_token == ACCESS_TOKEN


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "service": "edge-node",
        "timestamp": datetime.utcnow().isoformat() + "Z"
    })


@app.route("/metrics")
def metrics():
    if not token_ok(request):
        return jsonify({"error": "unauthorized"}), 401

    try:
        raw = run_monitor()
        parsed = parse_meminfo(raw)

        response = {
            "status": "ok",
            "node": socket.gethostname(),
            "metric": "memory",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            **parsed
        }
        return jsonify(response)

    except subprocess.TimeoutExpired:
        return jsonify({
            "status": "error",
            "message": "Timeout ao executar monitor em assembly."
        }), 504

    except subprocess.CalledProcessError as exc:
        return jsonify({
            "status": "error",
            "message": "Falha ao executar o binário monitor.",
            "stderr": exc.stderr
        }), 500

    except Exception as exc:
        return jsonify({
            "status": "error",
            "message": str(exc)
        }), 500


@app.route("/view")
def view():
    if not token_ok(request):
        return "Unauthorized", 401

    try:
        raw = run_monitor()
        parsed = parse_meminfo(raw)

        return render_template(
            "index.html",
            metrics=parsed,
            hostname=socket.gethostname(),
            timestamp=datetime.utcnow().isoformat() + "Z",
            raw=raw
        )
    except Exception as exc:
        return render_template(
            "index.html",
            error=str(exc)
        ), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)