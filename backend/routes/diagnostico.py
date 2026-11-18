"""
routes/diagnostico.py — Diagnóstico de conectividad entre nodos.

GET /api/diagnostico
    Prueba la conexión a cada nodo de NODES e informa:
      - Si la conexión TCP al puerto 3306 es alcanzable.
      - Si la autenticación MariaDB tiene éxito.
      - La versión del servidor, el charset y el usuario activo.
      - El estado de la replicación (SHOW SLAVE STATUS) si aplica.
      - Tiempo de respuesta en ms.
    Útil para diagnosticar el error 1045 "Access denied" sin necesidad
    de acceder directamente al servidor.
"""

import socket
import time

import pymysql
import pymysql.cursors
from flask import Blueprint, jsonify

from config import NODES

bp_diagnostico = Blueprint("diagnostico", __name__)


def _ok(data):
    return jsonify({"data": data, "error": None})


def _err(msg, status=500):
    return jsonify({"data": None, "error": msg}), status


# ── Helpers ───────────────────────────────────────────────────────────────────

def _tcp_check(host: str, port: int, timeout: float = 3.0) -> tuple[bool, float, str | None]:
    """
    Verifica conectividad TCP al host:port.
    Retorna (éxito, latencia_ms, mensaje_error).
    """
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            pass
        return True, (time.monotonic() - t0) * 1000, None
    except OSError as exc:
        return False, (time.monotonic() - t0) * 1000, str(exc)


def _auth_check(node: dict) -> dict:
    """
    Intenta abrir una sesión MariaDB y retorna un dict con el resultado.
    Distingue entre error 1045 (autenticación), 2003 (host no alcanzable)
    y otros errores.
    """
    result: dict = {
        "autenticacion_ok": False,
        "version": None,
        "charset": None,
        "usuario_actual": None,
        "replicacion": None,
        "latencia_ms": None,
        "error_codigo": None,
        "error_mensaje": None,
    }
    t0 = time.monotonic()
    try:
        conn = pymysql.connect(
            host=node["host"],
            port=node["port"],
            user=node["user"],
            password=node["password"],
            database=node["db"],
            cursorclass=pymysql.cursors.DictCursor,
            connect_timeout=5,
        )
        result["latencia_ms"] = round((time.monotonic() - t0) * 1000, 2)
        result["autenticacion_ok"] = True

        with conn.cursor() as cur:
            # Versión y charset del servidor
            cur.execute(
                "SELECT VERSION() AS version, "
                "@@character_set_server AS charset, "
                "CURRENT_USER() AS usuario"
            )
            row = cur.fetchone()
            result["version"] = row["version"]
            result["charset"] = row["charset"]
            result["usuario_actual"] = row["usuario"]

            # Estado de replicación (slave)
            try:
                cur.execute("SHOW SLAVE STATUS")
                slave = cur.fetchone()
                if slave:
                    result["replicacion"] = {
                        "slave_io_running": slave.get("Slave_IO_Running"),
                        "slave_sql_running": slave.get("Slave_SQL_Running"),
                        "master_host": slave.get("Master_Host"),
                        "seconds_behind_master": slave.get("Seconds_Behind_Master"),
                        "last_error": slave.get("Last_Error") or None,
                    }
                else:
                    result["replicacion"] = {"activa": False}
            except Exception:
                result["replicacion"] = {"activa": False}

        conn.close()

    except pymysql.err.OperationalError as exc:
        result["latencia_ms"] = round((time.monotonic() - t0) * 1000, 2)
        code, msg = exc.args[0], exc.args[1] if len(exc.args) > 1 else str(exc)
        result["error_codigo"] = code
        result["error_mensaje"] = msg

        # Desglose del código de error para diagnóstico claro
        if code == 1045:
            result["diagnostico"] = (
                f"ERROR 1045 — Acceso denegado para '{node['user']}' "
                f"desde el host que origina la conexión. "
                f"El usuario existe pero no tiene un registro de privilegios "
                f"que coincida con el host de origen. "
                f"SOLUCIÓN: ejecutar en MariaDB del nodo: "
                f"GRANT ALL ON {node['db']}.* TO '{node['user']}'@'%' "
                f"IDENTIFIED BY '<contraseña>'; FLUSH PRIVILEGES;"
            )
        elif code == 2003:
            result["diagnostico"] = (
                f"ERROR 2003 — No se puede conectar al host {node['host']}:{node['port']}. "
                f"Verificar: 1) Tailscale activo en ambas máquinas, "
                f"2) bind-address en my.cnf no es 127.0.0.1, "
                f"3) firewall permite puerto 3306."
            )
        elif code == 1049:
            result["diagnostico"] = (
                f"ERROR 1049 — Base de datos '{node['db']}' no existe en este nodo. "
                f"Crear con: CREATE DATABASE `{node['db']}`;"
            )
        else:
            result["diagnostico"] = f"Error inesperado código {code}: {msg}"

    except Exception as exc:
        result["latencia_ms"] = round((time.monotonic() - t0) * 1000, 2)
        result["error_mensaje"] = str(exc)
        result["diagnostico"] = "Error no clasificado — ver error_mensaje."

    return result


# ── Endpoint principal ────────────────────────────────────────────────────────

@bp_diagnostico.get("/api/diagnostico")
def diagnostico():
    """
    Diagnóstico completo de todos los nodos: TCP + autenticación + replicación.
    """
    informe = []
    for i, node in enumerate(NODES):
        entrada: dict = {
            "nodo_index": i,
            "host": node["host"],
            "port": node["port"],
            "db": node["db"],
            "usuario": node["user"],
        }

        # 1. Verificar conectividad TCP
        tcp_ok, tcp_ms, tcp_err = _tcp_check(node["host"], node["port"])
        entrada["tcp"] = {
            "alcanzable": tcp_ok,
            "latencia_ms": round(tcp_ms, 2),
            "error": tcp_err,
        }

        if not tcp_ok:
            entrada["autenticacion"] = {
                "autenticacion_ok": False,
                "diagnostico": (
                    f"El puerto {node['port']} en {node['host']} no es alcanzable. "
                    "Verificar Tailscale, bind-address y firewall antes de diagnosticar la autenticación."
                ),
            }
        else:
            entrada["autenticacion"] = _auth_check(node)

        # Estado global del nodo
        if tcp_ok and entrada["autenticacion"].get("autenticacion_ok"):
            entrada["estado"] = "OK"
        elif tcp_ok:
            entrada["estado"] = "ERROR_AUTH"
        else:
            entrada["estado"] = "INACCESIBLE"

        informe.append(entrada)

    return _ok(informe)


# ── Endpoint de prueba de consulta cruzada ────────────────────────────────────

@bp_diagnostico.get("/api/diagnostico/consulta-cruzada")
def consulta_cruzada():
    """
    Ejecuta SELECT COUNT(*) FROM Clientes en cada nodo y retorna los resultados.
    Demuestra que el backend puede consultar datos de ambas máquinas.
    """
    resultados = []
    for i, node in enumerate(NODES):
        entrada = {"nodo_index": i, "host": node["host"], "db": node["db"]}
        try:
            conn = pymysql.connect(
                host=node["host"],
                port=node["port"],
                user=node["user"],
                password=node["password"],
                database=node["db"],
                cursorclass=pymysql.cursors.DictCursor,
                connect_timeout=5,
            )
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) AS total FROM Clientes")
                row = cur.fetchone()
                entrada["total_clientes"] = row["total"]
                entrada["error"] = None
            conn.close()
        except pymysql.err.OperationalError as exc:
            entrada["total_clientes"] = None
            entrada["error"] = f"[{exc.args[0]}] {exc.args[1] if len(exc.args) > 1 else exc}"
        except Exception as exc:
            entrada["total_clientes"] = None
            entrada["error"] = str(exc)
        resultados.append(entrada)

    return jsonify({"data": resultados, "error": None})
