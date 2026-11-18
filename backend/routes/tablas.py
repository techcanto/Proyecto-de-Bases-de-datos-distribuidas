"""
routes/tablas.py — Gestión de tablas distribuidas + CRUD dinámico.

Permite crear y eliminar tablas en TODOS los nodos simultáneamente.
El DDL se construye en el backend a partir de JSON — nunca se acepta SQL crudo.

CRUD dinámico:
  - GET  /api/tablas/<nombre>/registros       → listar todos los registros (todos los nodos)
  - GET  /api/tablas/<nombre>/registros/<id>  → obtener un registro por PK (nodo local primero)
  - POST /api/tablas/<nombre>/registros       → insertar un registro (nodo local)
  - PUT  /api/tablas/<nombre>/registros/<id>  → actualizar un registro (todos los nodos)
  - DEL  /api/tablas/<nombre>/registros/<id>  → eliminar un registro (todos los nodos)
"""

import re

from flask import Blueprint, jsonify, request

from db import (
    execute_on_all_nodes,
    execute_on_all_nodes_parallel,
    execute_on_node,
    get_all_nodes,
    get_local_node,
)

bp_tablas = Blueprint("tablas", __name__)

# Tipos de columna permitidos (whitelist)
TIPOS_PERMITIDOS = {"VARCHAR", "BIGINT", "INT", "DECIMAL", "DATE", "BOOLEAN", "TEXT", "CHAR"}
_NAME_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]{0,63}$")

# Tablas del sistema que no deben gestionarse desde este módulo
TABLAS_SISTEMA = {"Clientes", "Direcciones", "clientes", "direcciones"}


def _ok(data):
    return jsonify({"data": data, "error": None})


def _err(msg, status=400):
    return jsonify({"data": None, "error": msg}), status


def _valid_name(nombre: str) -> bool:
    return bool(_NAME_RE.match(nombre))


def _build_ddl(nombre: str, columnas: list[dict]) -> str:
    """Construye un CREATE TABLE seguro desde la definición JSON."""
    definiciones = []
    cols_pk = []

    for col in columnas:
        col_nombre = col.get("nombre", "").strip()
        col_tipo   = col.get("tipo",   "").strip().upper()
        longitud   = col.get("longitud")
        not_null   = col.get("not_null", False)
        is_pk      = col.get("primary_key", False)

        if not _valid_name(col_nombre):
            raise ValueError(f"Nombre de columna inválido: '{col_nombre}'")
        if col_tipo not in TIPOS_PERMITIDOS:
            raise ValueError(f"Tipo de columna no permitido: '{col_tipo}'")

        if col_tipo == "VARCHAR":
            try:
                lng = int(longitud) if longitud else 255
            except (ValueError, TypeError):
                lng = 255
            tipo_str = f"VARCHAR({lng})"
        elif col_tipo == "CHAR":
            try:
                lng = int(longitud) if longitud else 10
            except (ValueError, TypeError):
                lng = 10
            tipo_str = f"CHAR({lng})"
        elif col_tipo == "DECIMAL":
            try:
                p, s = str(longitud).split(",") if longitud and "," in str(longitud) else ("10", "2")
                tipo_str = f"DECIMAL({int(p)},{int(s)})"
            except Exception:
                tipo_str = "DECIMAL(10,2)"
        else:
            tipo_str = col_tipo

        nn_str = " NOT NULL" if not_null else ""
        definiciones.append(f"  `{col_nombre}` {tipo_str}{nn_str}")

        if is_pk:
            cols_pk.append(f"`{col_nombre}`")

    if cols_pk:
        definiciones.append(f"  PRIMARY KEY ({', '.join(cols_pk)})")

    cols_sql = ",\n".join(definiciones)
    return f"CREATE TABLE IF NOT EXISTS `{nombre}` (\n{cols_sql}\n)"


def _obtener_columnas_tabla(nombre: str) -> list[str]:
    """
    Obtiene la lista de nombres de columnas de una tabla en el nodo local.
    Retorna lista vacía si la tabla no existe o hay error.
    """
    nodo = get_local_node()
    try:
        filas = execute_on_node(
            nodo,
            "SELECT COLUMN_NAME FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s "
            "ORDER BY ORDINAL_POSITION",
            (nombre,),
        )
        return [f["COLUMN_NAME"] for f in filas]
    except Exception:
        return []


def _obtener_pk_tabla(nombre: str) -> str | None:
    """
    Obtiene el nombre de la columna PRIMARY KEY de una tabla.
    Retorna None si no tiene PK definida.
    """
    nodo = get_local_node()
    try:
        filas = execute_on_node(
            nodo,
            "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s "
            "AND CONSTRAINT_NAME = 'PRIMARY' LIMIT 1",
            (nombre,),
        )
        if filas:
            return filas[0]["COLUMN_NAME"]
    except Exception:
        pass
    return None


# ── Listar tablas ──────────────────────────────────────────────────────────────

@bp_tablas.get("/api/tablas")
def listar_tablas():
    nodo = get_local_node()
    try:
        filas = execute_on_node(nodo, "SHOW TABLES")
        tablas = [list(fila.values())[0] for fila in filas]
    except Exception as exc:
        return _err(f"Error al listar tablas: {exc}", 500)
    return _ok(tablas)


# ── Obtener estructura (columnas) de una tabla ─────────────────────────────────

@bp_tablas.get("/api/tablas/<nombre>/estructura")
def obtener_estructura(nombre: str):
    """Retorna las columnas y tipos de una tabla en el nodo local."""
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    nodo = get_local_node()
    try:
        filas = execute_on_node(
            nodo,
            "SELECT COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, "
            "COLUMN_KEY, EXTRA "
            "FROM information_schema.COLUMNS "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s "
            "ORDER BY ORDINAL_POSITION",
            (nombre,),
        )
    except Exception as exc:
        return _err(f"Error al obtener estructura: {exc}", 500)
    if not filas:
        return _err(f"La tabla '{nombre}' no existe o no tiene columnas.", 404)
    return _ok(filas)


# ── Crear tabla en todos los nodos ─────────────────────────────────────────────

@bp_tablas.post("/api/tablas")
def crear_tabla():
    datos = request.get_json(silent=True) or {}
    nombre   = datos.get("nombre",   "").strip()
    columnas = datos.get("columnas", [])

    if not nombre:
        return _err("El campo 'nombre' es obligatorio.")
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido. Use solo letras, números y guión bajo.")
    if not columnas or not isinstance(columnas, list):
        return _err("Se debe definir al menos una columna.")
    if nombre in TABLAS_SISTEMA:
        return _err(f"La tabla '{nombre}' es del sistema y no puede recrearse desde aquí.")

    try:
        ddl = _build_ddl(nombre, columnas)
    except ValueError as exc:
        return _err(str(exc))

    resultados = execute_on_all_nodes(ddl, fetch=False)
    return _ok({"tabla": nombre, "nodos": resultados}), 201


# ── Eliminar tabla en todos los nodos ──────────────────────────────────────────

@bp_tablas.delete("/api/tablas/<nombre>")
def eliminar_tabla(nombre: str):
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err(f"La tabla '{nombre}' es del sistema y no puede eliminarse desde aquí.")

    ddl = f"DROP TABLE IF EXISTS `{nombre}`"
    resultados = execute_on_all_nodes(ddl, fetch=False)
    return _ok({"tabla": nombre, "nodos": resultados})


# ══════════════════════════════════════════════════════════════════════════════
# CRUD DINÁMICO — opera sobre cualquier tabla creada por el usuario
# ══════════════════════════════════════════════════════════════════════════════

# ── Listar registros de una tabla (todos los nodos) ───────────────────────────

@bp_tablas.get("/api/tablas/<nombre>/registros")
def listar_registros(nombre: str):
    """Lista todos los registros de una tabla desde todos los nodos en paralelo."""
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err("Use los endpoints específicos para Clientes/Direcciones.")

    columnas = _obtener_columnas_tabla(nombre)
    if not columnas:
        return _err(f"La tabla '{nombre}' no existe.", 404)

    consulta = f"SELECT * FROM `{nombre}` ORDER BY 1"
    try:
        filas = execute_on_all_nodes_parallel(consulta)
    except Exception as exc:
        return _err(f"Error al consultar: {exc}", 500)
    return _ok(filas)


# ── Obtener un registro por PK ─────────────────────────────────────────────────

@bp_tablas.get("/api/tablas/<nombre>/registros/<pk_valor>")
def obtener_registro(nombre: str, pk_valor: str):
    """Obtiene un registro por el valor de su PRIMARY KEY (busca en todos los nodos)."""
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err("Use los endpoints específicos para Clientes/Direcciones.")

    pk_col = _obtener_pk_tabla(nombre)
    if pk_col is None:
        return _err(f"La tabla '{nombre}' no tiene PRIMARY KEY definida.")

    for i, nodo in enumerate(get_all_nodes()):
        try:
            filas = execute_on_node(
                nodo,
                f"SELECT * FROM `{nombre}` WHERE `{pk_col}` = %s",
                (pk_valor,),
            )
            if filas:
                fila = filas[0]
                fila["node_index"] = i
                return _ok(fila)
        except Exception:
            continue

    return _err("Registro no encontrado.", 404)


# ── Insertar un registro (nodo local) ─────────────────────────────────────────

@bp_tablas.post("/api/tablas/<nombre>/registros")
def insertar_registro(nombre: str):
    """Inserta un registro en una tabla en el nodo local."""
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err("Use los endpoints específicos para Clientes/Direcciones.")

    columnas = _obtener_columnas_tabla(nombre)
    if not columnas:
        return _err(f"La tabla '{nombre}' no existe.", 404)

    datos = request.get_json(silent=True) or {}
    # Solo aceptar columnas que existen en la tabla
    datos_validos = {k: v for k, v in datos.items() if k in columnas}
    if not datos_validos:
        return _err("No se proporcionaron campos válidos para insertar.")

    cols_sql  = ", ".join(f"`{c}`" for c in datos_validos)
    vals_sql  = ", ".join(["%s"] * len(datos_validos))
    valores   = list(datos_validos.values())

    nodo = get_local_node()
    try:
        nuevo_id = execute_on_node(
            nodo,
            f"INSERT INTO `{nombre}` ({cols_sql}) VALUES ({vals_sql})",
            valores,
            fetch=False,
        )
    except Exception as exc:
        return _err(f"Error al insertar: {exc}", 500)

    return _ok({"lastrowid": nuevo_id}), 201


# ── Actualizar un registro (todos los nodos) ──────────────────────────────────

@bp_tablas.put("/api/tablas/<nombre>/registros/<pk_valor>")
def actualizar_registro(nombre: str, pk_valor: str):
    """
    Actualiza un registro por PK en TODOS los nodos donde se encuentre.
    Propaga el cambio a todos los nodos para mantener coherencia.
    """
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err("Use los endpoints específicos para Clientes/Direcciones.")

    pk_col  = _obtener_pk_tabla(nombre)
    if pk_col is None:
        return _err(f"La tabla '{nombre}' no tiene PRIMARY KEY definida.")

    columnas = _obtener_columnas_tabla(nombre)
    datos    = request.get_json(silent=True) or {}
    # Excluir la PK de los campos a actualizar
    datos_validos = {k: v for k, v in datos.items() if k in columnas and k != pk_col}
    if not datos_validos:
        return _err("No se proporcionaron campos válidos para actualizar.")

    set_sql = ", ".join(f"`{c}` = %s" for c in datos_validos)
    valores = list(datos_validos.values()) + [pk_valor]

    total_afectadas = 0
    errores = []
    for i, nodo in enumerate(get_all_nodes()):
        try:
            afectadas = execute_on_node(
                nodo,
                f"UPDATE `{nombre}` SET {set_sql} WHERE `{pk_col}` = %s",
                valores,
                fetch=False,
            )
            total_afectadas += (afectadas or 0)
        except Exception as exc:
            errores.append(f"Nodo {i}: {exc}")

    if errores:
        return _err(f"Errores en algunos nodos: {'; '.join(errores)}", 500)
    if total_afectadas == 0:
        return _err("Registro no encontrado.", 404)
    return _ok({"actualizado": pk_valor, "filas_afectadas": total_afectadas})


# ── Eliminar un registro (todos los nodos) ────────────────────────────────────

@bp_tablas.delete("/api/tablas/<nombre>/registros/<pk_valor>")
def eliminar_registro(nombre: str, pk_valor: str):
    """Elimina un registro por PK en TODOS los nodos."""
    if not _valid_name(nombre):
        return _err("Nombre de tabla inválido.")
    if nombre in TABLAS_SISTEMA:
        return _err("Use los endpoints específicos para Clientes/Direcciones.")

    pk_col = _obtener_pk_tabla(nombre)
    if pk_col is None:
        return _err(f"La tabla '{nombre}' no tiene PRIMARY KEY definida.")

    total_afectadas = 0
    errores = []
    for i, nodo in enumerate(get_all_nodes()):
        try:
            afectadas = execute_on_node(
                nodo,
                f"DELETE FROM `{nombre}` WHERE `{pk_col}` = %s",
                (pk_valor,),
                fetch=False,
            )
            total_afectadas += (afectadas or 0)
        except Exception as exc:
            errores.append(f"Nodo {i}: {exc}")

    if errores:
        return _err(f"Errores en algunos nodos: {'; '.join(errores)}", 500)
    if total_afectadas == 0:
        return _err("Registro no encontrado.", 404)
    return _ok({"eliminado": pk_valor})
