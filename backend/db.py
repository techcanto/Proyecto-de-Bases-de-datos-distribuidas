"""
db.py — Módulo central de enrutamiento y ejecución de consultas.

Reglas de enrutamiento:
  - INSERT          → solo nodo local (get_local_node)
  - UPDATE/DELETE   → nodo propietario del ID (get_node_for_id)
  - SELECT global   → todos los nodos en paralelo (execute_on_all_nodes_parallel)
  - DDL             → todos los nodos (execute_on_all_nodes)
"""

from __future__ import annotations

import threading
from typing import Any

import pymysql
import pymysql.cursors

from config import BLOCK_SIZE, LOCAL_NODE_INDEX, NODES, get_node_range


# ── Helpers de conexión ────────────────────────────────────────────────────────

def get_connection(node_config: dict) -> pymysql.Connection:
    """Abre y retorna una conexión PyMySQL al nodo dado."""
    return pymysql.connect(
        host=node_config["host"],
        port=node_config["port"],
        user=node_config["user"],
        password=node_config["password"],
        database=node_config["db"],
        cursorclass=pymysql.cursors.DictCursor,
        connect_timeout=5,
    )


# ── Enrutamiento ───────────────────────────────────────────────────────────────

def get_node_for_id(client_id: int) -> dict:
    """Retorna la config del nodo propietario del client_id dado."""
    node_index = (client_id - 1) // BLOCK_SIZE
    if node_index < 0 or node_index >= len(NODES):
        raise ValueError(f"ID {client_id} fuera de rango para los nodos configurados.")
    return NODES[node_index]


def get_node_index_for_id(client_id: int) -> int:
    """Retorna el índice del nodo propietario del client_id dado."""
    return (client_id - 1) // BLOCK_SIZE


def get_local_node() -> dict:
    """Retorna la config del nodo local (para inserciones)."""
    return NODES[LOCAL_NODE_INDEX]


def get_all_nodes() -> list[dict]:
    """Retorna la lista completa de configs de nodos."""
    return NODES


# ── Ejecución en un nodo ───────────────────────────────────────────────────────

def execute_on_node(
    node_config: dict,
    query: str,
    params: tuple | list | None = None,
    *,
    fetch: bool = True,
) -> list[dict] | int:
    """
    Ejecuta una query en el nodo dado.
    - Si fetch=True  → retorna lista de dicts (SELECT).
    - Si fetch=False → retorna lastrowid o rowcount (INSERT/UPDATE/DELETE/DDL).
    """
    conn = get_connection(node_config)
    try:
        with conn.cursor() as cur:
            cur.execute(query, params)
            if fetch:
                return cur.fetchall()
            conn.commit()
            return cur.lastrowid if cur.lastrowid else cur.rowcount
    finally:
        conn.close()


# ── Ejecución en todos los nodos ───────────────────────────────────────────────

def execute_on_all_nodes(
    query: str,
    params: tuple | list | None = None,
    *,
    fetch: bool = True,
) -> list[dict] | list[dict[str, Any]]:
    """
    Ejecuta la misma query en todos los nodos de forma secuencial.
    Si fetch=True, hace merge de los resultados con campo 'node_index'.
    Si fetch=False, retorna lista de {node_index, result, error}.
    """
    results = []
    for i, node in enumerate(NODES):
        try:
            result = execute_on_node(node, query, params, fetch=fetch)
            if fetch:
                for row in result:
                    row["node_index"] = i
                results.extend(result)
            else:
                results.append({"node_index": i, "result": result, "error": None})
        except Exception as exc:
            if fetch:
                pass  # nodo no disponible — omitir del merge
            else:
                results.append({"node_index": i, "result": None, "error": str(exc)})
    return results


def execute_on_all_nodes_parallel(
    query: str,
    params: tuple | list | None = None,
) -> list[dict]:
    """
    Ejecuta SELECT en todos los nodos en paralelo usando threads.
    Agrega 'node_index' a cada fila retornada.
    """
    results: list[dict] = []
    lock = threading.Lock()
    errors: list[str] = []

    def _worker(index: int, node: dict) -> None:
        try:
            rows = execute_on_node(node, query, params, fetch=True)
            for row in rows:
                row["node_index"] = index
            with lock:
                results.extend(rows)
        except Exception as exc:
            with lock:
                errors.append(f"Nodo {index}: {exc}")

    threads = [
        threading.Thread(target=_worker, args=(i, node))
        for i, node in enumerate(NODES)
    ]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    return results
