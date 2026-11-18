#!/usr/bin/env python3
"""
prueba_conectividad.py — Pruebas de conectividad y consultas cruzadas entre nodos.

Ejecutar desde el directorio raíz del proyecto:
    python scripts/pruebas/prueba_conectividad.py

No requiere que el backend Flask esté corriendo.
Requiere: pip install PyMySQL (ya incluido en backend/requirements.txt)
"""

from __future__ import annotations

import sys
import socket
import time
from pathlib import Path

# Agregar el directorio backend al path para importar config.py
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "backend"))

try:
    import pymysql
    import pymysql.cursors
except ImportError:
    print("ERROR: PyMySQL no está instalado.")
    print("Ejecutar: pip install PyMySQL")
    sys.exit(1)

from config import NODES, BLOCK_SIZE  # noqa: E402  (import después de sys.path)

# ── Colores ANSI para la terminal ─────────────────────────────────────────────
OK    = "\033[92m✔\033[0m"
FAIL  = "\033[91m✘\033[0m"
WARN  = "\033[93m⚠\033[0m"
INFO  = "\033[94mℹ\033[0m"
BOLD  = "\033[1m"
RESET = "\033[0m"

SEPARADOR = "─" * 70


def banner(texto: str) -> None:
    print(f"\n{BOLD}{SEPARADOR}{RESET}")
    print(f"  {BOLD}{texto}{RESET}")
    print(f"{BOLD}{SEPARADOR}{RESET}")


def ok(msg: str) -> None:
    print(f"  {OK}  {msg}")


def fail(msg: str) -> None:
    print(f"  {FAIL}  {msg}")


def info(msg: str) -> None:
    print(f"  {INFO}  {msg}")


def warn(msg: str) -> None:
    print(f"  {WARN}  {msg}")


# ── PRUEBA 1: Conectividad TCP ────────────────────────────────────────────────

def prueba_tcp(host: str, port: int, timeout: float = 3.0) -> bool:
    """Verifica si el puerto TCP está abierto en el host remoto."""
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout):
            ms = (time.monotonic() - t0) * 1000
            ok(f"TCP {host}:{port}  →  alcanzable  ({ms:.1f} ms)")
            return True
    except OSError as exc:
        ms = (time.monotonic() - t0) * 1000
        fail(f"TCP {host}:{port}  →  {exc}  ({ms:.1f} ms)")
        _sugerencia_tcp(host, port, str(exc))
        return False


def _sugerencia_tcp(host: str, port: int, error: str) -> None:
    """Imprime sugerencias contextuales según el tipo de error TCP."""
    if "Connection refused" in error:
        warn(f"MariaDB no escucha en {host}:{port}. Verificar:")
        warn("  • sudo systemctl status mariadb")
        warn("  • bind-address en /etc/mysql/mariadb.conf.d/50-server.cnf")
        warn("    Debe ser 0.0.0.0, no 127.0.0.1")
    elif "timed out" in error or "No route" in error:
        warn("El host no es alcanzable. Verificar:")
        warn("  • tailscale status   (¿está el peer online?)")
        warn("  • ping " + host)
        warn("  • Firewall: sudo ufw allow 3306  o  firewall-cmd --add-port=3306/tcp")
    else:
        warn(f"Error de red inesperado: {error}")


# ── PRUEBA 2: Autenticación MariaDB ───────────────────────────────────────────

def prueba_autenticacion(node: dict) -> pymysql.Connection | None:
    """Intenta conectarse a MariaDB y retorna la conexión si tiene éxito."""
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
        ms = (time.monotonic() - t0) * 1000
        ok(f"Autenticación  →  exitosa como '{node['user']}'  ({ms:.1f} ms)")
        return conn
    except pymysql.err.OperationalError as exc:
        ms = (time.monotonic() - t0) * 1000
        code = exc.args[0]
        msg = exc.args[1] if len(exc.args) > 1 else str(exc)
        fail(f"Autenticación  →  ERROR {code}: {msg}  ({ms:.1f} ms)")
        _sugerencia_auth(node, code)
        return None
    except Exception as exc:
        fail(f"Autenticación  →  {exc}")
        return None


def _sugerencia_auth(node: dict, code: int) -> None:
    if code == 1045:
        warn("ERROR 1045 — Access denied. El usuario/contraseña no tiene")
        warn("un registro de privilegios que coincida con este host de origen.")
        warn("Ejecutar en la BD remota como root:")
        warn(f"  CREATE USER IF NOT EXISTS '{node['user']}'@'%'")
        warn(f"      IDENTIFIED BY '<contraseña>';")
        warn(f"  GRANT ALL ON `{node['db']}`.* TO '{node['user']}'@'%';")
        warn("  FLUSH PRIVILEGES;")
        warn("  → Script completo: scripts/sql/01_usuarios_permisos.sql")
    elif code == 1049:
        warn(f"ERROR 1049 — La base de datos '{node['db']}' no existe.")
        warn(f"  CREATE DATABASE `{node['db']}`;")
    elif code == 2003:
        warn("ERROR 2003 — Host no alcanzable (ver resultado TCP arriba).")


# ── PRUEBA 3: Versión y charset del servidor ──────────────────────────────────

def prueba_servidor(conn: pymysql.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT VERSION() AS v, "
            "@@character_set_server AS cs, "
            "@@collation_server AS co, "
            "CURRENT_USER() AS u"
        )
        row = cur.fetchone()
    info(f"Versión:  {row['v']}")
    info(f"Charset:  {row['cs']}  /  {row['co']}")
    info(f"Usuario:  {row['u']}")

    # Verificar charset UTF-8 (necesario para nombres con ñ y acentos)
    if "utf8mb4" not in row["cs"]:
        warn(f"El charset es '{row['cs']}', se recomienda utf8mb4 para soporte completo de unicode.")


# ── PRUEBA 4: Tablas y recuento de registros ──────────────────────────────────

def prueba_tablas(conn: pymysql.Connection, db: str) -> None:
    with conn.cursor() as cur:
        cur.execute("SHOW TABLES")
        tablas = [list(r.values())[0] for r in cur.fetchall()]

    if tablas:
        ok(f"Tablas encontradas: {', '.join(tablas)}")
    else:
        warn("No hay tablas en esta base de datos.")
        return

    for tabla in tablas:
        try:
            with conn.cursor() as cur:
                cur.execute(f"SELECT COUNT(*) AS n FROM `{tabla}`")
                n = cur.fetchone()["n"]
            info(f"  {tabla}: {n} registro(s)")
        except Exception as exc:
            warn(f"  {tabla}: error al contar — {exc}")


# ── PRUEBA 5: Replicación ─────────────────────────────────────────────────────

def prueba_replicacion(conn: pymysql.Connection) -> None:
    try:
        with conn.cursor() as cur:
            cur.execute("SHOW SLAVE STATUS")
            slave = cur.fetchone()
    except Exception:
        # Sin privilegio SLAVE MONITOR — omitir silenciosamente
        return

    if not slave:
        warn("Este nodo NO está configurado como SLAVE (replicación no activa).")
        warn("Ver scripts/sql/02_replicacion_nodo0_morelia.sql para configurarla.")
        return

    io   = slave.get("Slave_IO_Running")
    sql  = slave.get("Slave_SQL_Running")
    mstr = slave.get("Master_Host")
    lag  = slave.get("Seconds_Behind_Master")
    err  = slave.get("Last_Error")

    if io == "Yes" and sql == "Yes":
        ok(f"Replicación activa  ←  master: {mstr}  |  retraso: {lag}s")
    else:
        fail(f"Replicación degradada  |  IO: {io}  SQL: {sql}  master: {mstr}")
        if err:
            fail(f"Último error: {err}")
        warn("Para reiniciar el slave: STOP SLAVE; START SLAVE;")

    with conn.cursor() as cur:
        cur.execute("SHOW MASTER STATUS")
        master = cur.fetchone()
    if master:
        ok(f"Master activo  →  binlog: {master.get('File')}  pos: {master.get('Position')}")
    else:
        warn("Este nodo NO está actuando como MASTER (binlog desactivado).")


# ── PRUEBA 6: Consulta cruzada (INSERT en nodo local → SELECT en remoto) ──────

def prueba_consulta_cruzada(conns: list[pymysql.Connection | None]) -> None:
    """
    Demuestra que podemos leer datos del nodo remoto.
    Solo lee (SELECT) — no modifica datos.
    """
    banner("PRUEBA 6: Consulta cruzada entre nodos")
    total_global = 0
    for i, conn in enumerate(conns):
        if conn is None:
            fail(f"Nodo {i} no disponible — omitido.")
            continue
        node = NODES[i]
        id_min = i * BLOCK_SIZE + 1
        id_max = (i + 1) * BLOCK_SIZE
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT Id, Nombre, ApellidoPaterno FROM Clientes "
                    "WHERE Id BETWEEN %s AND %s ORDER BY Id LIMIT 3",
                    (id_min, id_max),
                )
                rows = cur.fetchall()
            if rows:
                ok(f"Nodo {i} ({node['host']}): {len(rows)} ejemplo(s) de Clientes:")
                for r in rows:
                    info(f"    ID {r['Id']}  {r['Nombre']} {r['ApellidoPaterno']}")
            else:
                warn(f"Nodo {i} ({node['host']}): sin registros en rango {id_min}–{id_max}.")

            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*) AS n FROM Clientes")
                n = cur.fetchone()["n"]
            total_global += n
            info(f"  Total en nodo {i}: {n} cliente(s)")
        except Exception as exc:
            fail(f"Nodo {i}: error en consulta — {exc}")

    info(f"Total global (todos los nodos): {total_global} cliente(s)")


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    print(f"\n{BOLD}=== Prueba de conectividad y consultas cruzadas MariaDB ==={RESET}")
    print(f"Nodos configurados: {len(NODES)}")
    for i, n in enumerate(NODES):
        print(f"  Nodo {i}: {n['host']}:{n['port']}  BD={n['db']}  user={n['user']}")

    conns: list[pymysql.Connection | None] = []
    errores_criticos = 0

    for i, node in enumerate(NODES):
        banner(f"NODO {i}: {node['host']} — {node['db']}")

        # Prueba 1: TCP
        tcp_ok = prueba_tcp(node["host"], node["port"])
        if not tcp_ok:
            errores_criticos += 1
            conns.append(None)
            continue

        # Prueba 2: Autenticación
        conn = prueba_autenticacion(node)
        if conn is None:
            errores_criticos += 1
            conns.append(None)
            continue

        conns.append(conn)

        # Prueba 3: Servidor
        prueba_servidor(conn)

        # Prueba 4: Tablas
        prueba_tablas(conn, node["db"])

        # Prueba 5: Replicación
        prueba_replicacion(conn)

    # Prueba 6: Consultas cruzadas
    prueba_consulta_cruzada(conns)

    # Cerrar conexiones
    for conn in conns:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    # Resumen final
    banner("RESUMEN")
    nodos_ok = sum(1 for c in conns if c is not None)
    if errores_criticos == 0:
        ok(f"Todos los nodos ({nodos_ok}/{len(NODES)}) están accesibles y autenticados.")
    else:
        fail(f"{errores_criticos} nodo(s) con errores. Ver detalles arriba.")
        fail("Revisar scripts/sql/01_usuarios_permisos.sql para corregir permisos.")

    print()
    sys.exit(0 if errores_criticos == 0 else 1)


if __name__ == "__main__":
    main()
