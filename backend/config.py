"""
config.py — Configuración de nodos y detección de nodo local.

Las credenciales se cargan desde variables de entorno o desde un archivo .env
en el directorio raíz del proyecto. Nunca deben hardcodearse aquí.

Para configurar: copiar .env.example → .env y rellenar los valores.
"""

import os
import socket
from pathlib import Path

# ── Cargar .env si existe (sin dependencias extra — carga manual) ──────────────
_env_path = Path(__file__).resolve().parents[1] / ".env"
if _env_path.exists():
    for _line in _env_path.read_text(encoding="utf-8").splitlines():
        _line = _line.strip()
        if _line and not _line.startswith("#") and "=" in _line:
            _k, _, _v = _line.partition("=")
            _k = _k.strip()
            _v = _v.strip().split("#")[0].strip()  # ignorar comentarios inline
            if _k and _k not in os.environ:          # no sobreescribir vars del sistema
                os.environ[_k] = _v


def _env(key: str, default: str = "") -> str:
    return os.environ.get(key, default).strip()


def _int_env(key: str, default: int) -> int:
    try:
        return int(_env(key, str(default)))
    except ValueError:
        return default


# ── Tamaño de bloque por nodo ──────────────────────────────────────────────────
BLOCK_SIZE: int = _int_env("BLOCK_SIZE", 1500)

# ── Lista de nodos ─────────────────────────────────────────────────────────────
# Se construye desde variables de entorno NODE0_*, NODE1_*, etc.
# Para agregar un nodo nuevo: añadir NODE2_* en .env y ejecutar en esa BD:
#   ALTER TABLE Clientes AUTO_INCREMENT = 2 * BLOCK_SIZE + 1;

def _build_nodes() -> list[dict]:
    """Construye la lista de nodos desde variables de entorno."""
    nodes = []
    index = 0
    while True:
        prefix = f"NODE{index}_"
        host = _env(f"{prefix}HOST")
        if not host:
            break
        nodes.append({
            "host":     host,
            "port":     _int_env(f"{prefix}PORT", 3306),
            "db":       _env(f"{prefix}DB"),
            "user":     _env(f"{prefix}USER"),
            "password": _env(f"{prefix}PASSWORD"),
        })
        index += 1
    return nodes


NODES: list[dict] = _build_nodes()

if not NODES:
    raise RuntimeError(
        "No se encontraron nodos configurados. "
        "Copia .env.example → .env y configura NODE0_HOST, NODE0_DB, etc."
    )


# ── Helpers de rango ───────────────────────────────────────────────────────────

def get_node_range(index: int) -> tuple[int, int]:
    """Calcula (id_min, id_max) para el nodo en la posición index."""
    id_min = index * BLOCK_SIZE + 1
    id_max = (index + 1) * BLOCK_SIZE
    return id_min, id_max


# ── Detección del nodo local ───────────────────────────────────────────────────

def _get_local_ips() -> set[str]:
    """
    Obtiene todas las IPs asignadas a esta máquina, priorizando
    la IP Tailscale (rango 100.64.0.0/10) si está disponible.
    """
    ips: set[str] = {"127.0.0.1", "localhost"}

    # Método 1: getaddrinfo del hostname (detecta IPs Tailscale en la mayoría de sistemas)
    try:
        hostname = socket.gethostname()
        for result in socket.getaddrinfo(hostname, None):
            ips.add(result[4][0])
    except Exception:
        pass

    # Método 2: intentar con el nombre de la interfaz tailscale directamente
    try:
        import subprocess
        out = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True, text=True, timeout=3
        )
        if out.returncode == 0:
            ts_ip = out.stdout.strip()
            if ts_ip:
                ips.add(ts_ip)
    except Exception:
        pass

    # Método 3: recorrer interfaces de red buscando IPs Tailscale (100.x.x.x)
    try:
        import subprocess
        out = subprocess.run(
            ["ip", "addr", "show"],
            capture_output=True, text=True, timeout=3
        )
        import re
        for match in re.finditer(r'inet\s+(100\.\d+\.\d+\.\d+)', out.stdout):
            ips.add(match.group(1))
    except Exception:
        pass

    return ips


def detect_local_node() -> int:
    """
    Detecta el índice del nodo local comparando las IPs de red locales
    con los hosts definidos en NODES.

    Orden de prioridad para la detección:
      1. Variable de entorno LOCAL_NODE_INDEX (sobreescribe todo)
      2. Comparación por IP Tailscale (tailscale ip -4)
      3. Comparación por IPs del hostname del sistema
      4. Fallback al nodo 0

    Retorna el índice del nodo local.
    """
    # Sobreescritura manual (útil en CI o máquinas de desarrollo)
    override = _env("LOCAL_NODE_INDEX")
    if override:
        try:
            idx = int(override)
            if 0 <= idx < len(NODES):
                return idx
        except ValueError:
            pass

    local_ips = _get_local_ips()

    for i, node in enumerate(NODES):
        if node["host"] in local_ips:
            return i

    # Fallback al nodo 0
    return 0


# Índice del nodo local — calculado una vez al importar el módulo
LOCAL_NODE_INDEX: int = detect_local_node()
