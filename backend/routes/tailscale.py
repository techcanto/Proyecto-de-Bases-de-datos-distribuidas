"""
routes/tailscale.py — Estado de conectividad Tailscale.

GET /api/tailscale  → devuelve el estado de Tailscale: self, peers y si cada peer
                      de NODES está en línea.
"""

import json
import shutil
import subprocess

from flask import Blueprint, jsonify

from config import NODES

bp_tailscale = Blueprint("tailscale", __name__)


def _ok(data):
    return jsonify({"data": data, "error": None})


def _err(msg, status=500):
    return jsonify({"data": None, "error": msg}), status


@bp_tailscale.get("/api/tailscale")
def tailscale_status():
    """
    Retorna el estado de Tailscale:
      - available: bool — si tailscale está instalado
      - running:   bool — si el backend está activo (BackendState == "Running")
      - self_ip:   str  — primera IP Tailscale de esta máquina
      - peers:     list — peers conocidos con nombre, IPs y online
      - nodes:     list — estado de cada nodo en NODES
    """
    if not shutil.which("tailscale"):
        return _ok({
            "available": False,
            "running": False,
            "self_ip": None,
            "peers": [],
            "nodes": [
                {"index": i, "host": n["host"], "online": False, "hostname": None}
                for i, n in enumerate(NODES)
            ],
        })

    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        ts = json.loads(result.stdout)
    except Exception as exc:
        return _err(f"Error al consultar tailscale: {exc}")

    running = ts.get("BackendState") == "Running"
    self_ips = ts.get("Self", {}).get("TailscaleIPs", [])
    self_ip = self_ips[0] if self_ips else None

    peers_raw = ts.get("Peer", {})
    peers = [
        {
            "hostname": p.get("HostName"),
            "ips": p.get("TailscaleIPs", []),
            "online": p.get("Online", False),
            "active": p.get("Active", False),
        }
        for p in peers_raw.values()
    ]

    # Construir mapa ip → peer para cruzar con NODES
    ip_to_peer: dict[str, dict] = {}
    for p in peers:
        for ip in p["ips"]:
            ip_to_peer[ip] = p

    # También incluir self
    for ip in self_ips:
        ip_to_peer[ip] = {"hostname": ts.get("Self", {}).get("HostName"), "online": True, "active": True, "ips": self_ips}

    nodes_status = []
    for i, node in enumerate(NODES):
        peer = ip_to_peer.get(node["host"])
        nodes_status.append({
            "index": i,
            "host": node["host"],
            "hostname": peer["hostname"] if peer else None,
            "online": peer["online"] if peer else False,
        })

    return _ok({
        "available": True,
        "running": running,
        "self_ip": self_ip,
        "peers": peers,
        "nodes": nodes_status,
    })
