# Replicación Bidireccional MariaDB — Guía de Implementación

## Tabla de contenidos

1. [Análisis de la causa raíz del error 1045](#1-análisis-de-la-causa-raíz-del-error-1045)
2. [Arquitectura de replicación bidireccional](#2-arquitectura-de-replicación-bidireccional)
3. [Paso 1 — Configurar usuarios y permisos](#3-paso-1--configurar-usuarios-y-permisos)
4. [Paso 2 — Preparar el archivo my.cnf en ambos nodos](#4-paso-2--preparar-el-archivo-mycnf-en-ambos-nodos)
5. [Paso 3 — Configurar la replicación binlog](#5-paso-3--configurar-la-replicación-binlog)
6. [Paso 4 — Verificar con el script de pruebas](#6-paso-4--verificar-con-el-script-de-pruebas)
7. [Paso 5 — Usar la API de diagnóstico del backend](#7-paso-5--usar-la-api-de-diagnóstico-del-backend)
8. [Troubleshooting](#8-troubleshooting)
9. [Consideraciones sobre el diseño de particionamiento](#9-consideraciones-sobre-el-diseño-de-particionamiento)

---

## 1. Análisis de la causa raíz del error 1045

```
Access denied for user 'Compañero'@'pc.taile8f403.ts.net' (using password: YES)
```

### Por qué ocurre

En MariaDB (y MySQL), un **usuario no es solo un nombre** — es una dupla
`'nombre'@'host_origen'`. Cuando el backend Flask corre en la máquina del
compañero (`pc.taile8f403.ts.net`, con IP Tailscale `100.x.x.x`) e intenta
conectarse al servidor MariaDB local del mismo nodo, el servidor evalúa:

```
¿Existe un registro en mysql.user donde user='Compañero' Y host coincide con 'pc.taile8f403.ts.net'?
```

Si el usuario fue creado solo como `'Compañero'@'localhost'`, la respuesta
es **no** — y se devuelve el error 1045 aunque la contraseña sea correcta.

### Cadena de eventos en el log

```
backend.log línea 22:
127.0.0.1 - - [15/Nov/2026 23:34:18] "GET /api/tablas HTTP/1.1" 500

routes/tablas.py:89  listar_tablas()
  → get_local_node()           # obtiene config del nodo 0
  → execute_on_node(node, "SHOW TABLES")
    → get_connection(node)
      → pymysql.connect(host='100.120.137.4', user='Compañero', ...)
        ← ERROR 1045
  ← HTTP 500 {"error": "Error al listar tablas: (1045, ...)"}
```

### Causas posibles en orden de probabilidad

| # | Causa | Señal diagnóstica |
|---|-------|-------------------|
| 1 | Usuario creado solo para `localhost` | `SELECT user,host FROM mysql.user WHERE user='Compañero'` muestra solo `localhost` |
| 2 | Usuario no creado en ese nodo | Mismo SELECT no devuelve filas |
| 3 | Contraseña diferente en algún nodo | Error 1045 con `using password: YES` |
| 4 | `bind-address = 127.0.0.1` en my.cnf | Error 2003 (Connection refused), no 1045 |
| 5 | Firewall bloqueando puerto 3306 | Timeout de conexión TCP |

---

## 2. Arquitectura de replicación bidireccional

```
┌─────────────────────────────────────────────────────────────────┐
│                    Red Tailscale (100.x.x.x)                    │
│                                                                 │
│  ┌──────────────────────┐       ┌──────────────────────────┐   │
│  │   Nodo 0 — Morelia   │       │   Nodo 1 — Pátzcuaro     │   │
│  │   100.120.137.4      │       │   100.119.128.65         │   │
│  │                      │       │                          │   │
│  │  MariaDB             │       │  MariaDB                 │   │
│  │  BD: sucursal_morelia│       │  BD: suc_patzcuaro       │   │
│  │  IDs: 1–1500         │       │  IDs: 1501–3000          │   │
│  │                      │       │                          │   │
│  │  MASTER ─────────────┼──────►│  SLAVE (lee binlog N0)   │   │
│  │  SLAVE  ◄────────────┼───────┤  MASTER                  │   │
│  │  (lee binlog N1)     │       │                          │   │
│  │                      │       │                          │   │
│  │  Flask Backend       │       │  Flask Backend           │   │
│  │  :5000               │       │  :5000                   │   │
│  └──────────────────────┘       └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Fragmentación horizontal + replicación

El proyecto usa **fragmentación horizontal por rango de IDs** (no replicación
de los mismos datos). Cada nodo tiene datos exclusivos:

| Nodo | BD | Rango IDs | Propósito de la replicación |
|------|----|-----------|-----------------------------|
| 0 (Morelia) | `sucursal_morelia` | 1–1500 | Recibe réplica del binlog del Nodo 1 |
| 1 (Pátzcuaro) | `suc_patzcuaro` | 1501–3000 | Recibe réplica del binlog del Nodo 0 |

> **Nota importante:** En este diseño la replicación sirve para **alta
> disponibilidad y auditoría**, no para duplicar datos idénticos. Cada
> BD contiene su fragmento propio y el backend Flask realiza el enrutamiento
> de consultas a través de la capa `db.py`.

---

## 3. Paso 1 — Configurar usuarios y permisos

**Ejecutar en AMBAS máquinas** como `root` de MariaDB:

```bash
# Conectarse como root al MariaDB local:
sudo mysql -u root -p

# O bien ejecutar el script directamente:
mysql -u root -p < scripts/sql/01_usuarios_permisos.sql
```

### En el Nodo 0 (Morelia, 100.120.137.4):

```sql
-- 1. Verificar estado actual
SELECT user, host FROM mysql.user WHERE user = 'Compañero';

-- 2. Eliminar entradas restrictivas (si existen)
DROP USER IF EXISTS 'Compañero'@'localhost';

-- 3. Crear usuario para acceso remoto
CREATE USER IF NOT EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';

-- 4. Otorgar permisos
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, SHOW VIEW
    ON `sucursal_morelia`.*
    TO 'Compañero'@'%';

-- 5. Aplicar
FLUSH PRIVILEGES;

-- 6. Verificar
SHOW GRANTS FOR 'Compañero'@'%';
```

### En el Nodo 1 (Pátzcuaro, 100.119.128.65):

```sql
-- Mismo proceso, cambiando el nombre de la BD:
DROP USER IF EXISTS 'Compañero'@'localhost';
CREATE USER IF NOT EXISTS 'Compañero'@'%'
    IDENTIFIED BY 'UnaContraseñaSegura123!';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, SHOW VIEW
    ON `suc_patzcuaro`.*
    TO 'Compañero'@'%';
FLUSH PRIVILEGES;
```

---

## 4. Paso 2 — Preparar el archivo my.cnf en ambos nodos

Editar `/etc/mysql/mariadb.conf.d/50-server.cnf` (Debian/Ubuntu) o
`/etc/my.cnf.d/server.cnf` (Arch/RHEL).

Los archivos de configuración de referencia están en `scripts/sql/`:
- `04_my_cnf_nodo0_morelia.ini` — para el Nodo 0
- `05_my_cnf_nodo1_patzcuaro.ini` — para el Nodo 1

### Cambios críticos en ambos nodos:

```ini
[mariadb]
# 1. Escuchar en todas las interfaces (CRÍTICO para Tailscale)
bind-address     = 0.0.0.0

# 2. ID único por servidor (1 para Morelia, 2 para Pátzcuaro)
server-id        = 1   # ← cambiar a 2 en Pátzcuaro

# 3. Habilitar binlog para actuar como MASTER
log_bin          = /var/log/mysql/mariadb-bin
binlog_format    = ROW

# 4. Charset unicode (soporte de ñ, acentos)
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
```

```bash
# Reiniciar MariaDB después de editar:
sudo systemctl restart mariadb
sudo systemctl status mariadb
```

---

## 5. Paso 3 — Configurar la replicación binlog

> **Orden recomendado:** Primero configurar ambos nodos como MASTER (habilitar
> binlog), luego cruzar las configuraciones de SLAVE.

### En el Nodo 0 (Morelia) — como MASTER:

```sql
-- Crear usuario de replicación (el Nodo 1 usará este usuario)
CREATE USER IF NOT EXISTS 'repl_morelia'@'100.%.%.%'
    IDENTIFIED BY 'ReplMorelia_Segura!2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl_morelia'@'100.%.%.%';
FLUSH PRIVILEGES;

-- Anotar los valores que se pasan al Nodo 1:
SHOW MASTER STATUS;
-- Ejemplo de salida:
-- +--------------------+----------+
-- | File               | Position |
-- +--------------------+----------+
-- | mariadb-bin.000001 |      769 |
-- +--------------------+----------+
```

### En el Nodo 1 (Pátzcuaro) — como MASTER:

```sql
-- Crear usuario de replicación (el Nodo 0 usará este usuario)
CREATE USER IF NOT EXISTS 'repl_patzcuaro'@'100.%.%.%'
    IDENTIFIED BY 'ReplPatzcuaro_Segura!2026';
GRANT REPLICATION SLAVE ON *.* TO 'repl_patzcuaro'@'100.%.%.%';
FLUSH PRIVILEGES;

SHOW MASTER STATUS;
-- Anotar File y Position para el Nodo 0.
```

### En el Nodo 0 — configurar como SLAVE del Nodo 1:

```sql
-- Usar los valores de SHOW MASTER STATUS del Nodo 1:
CHANGE MASTER TO
    MASTER_HOST     = '100.119.128.65',
    MASTER_PORT     = 3306,
    MASTER_USER     = 'repl_patzcuaro',
    MASTER_PASSWORD = 'ReplPatzcuaro_Segura!2026',
    MASTER_LOG_FILE = 'mariadb-bin.000001',  -- valor real de SHOW MASTER STATUS
    MASTER_LOG_POS  = 4;                      -- valor real de SHOW MASTER STATUS

START SLAVE;
SHOW SLAVE STATUS\G
-- Verificar: Slave_IO_Running: Yes  /  Slave_SQL_Running: Yes
```

### En el Nodo 1 — configurar como SLAVE del Nodo 0:

```sql
CHANGE MASTER TO
    MASTER_HOST     = '100.120.137.4',
    MASTER_PORT     = 3306,
    MASTER_USER     = 'repl_morelia',
    MASTER_PASSWORD = 'ReplMorelia_Segura!2026',
    MASTER_LOG_FILE = 'mariadb-bin.000001',  -- valor real del Nodo 0
    MASTER_LOG_POS  = 4;

START SLAVE;
SHOW SLAVE STATUS\G
```

---

## 6. Paso 4 — Verificar con el script de pruebas

```bash
# Desde el directorio raíz del proyecto:
python scripts/pruebas/prueba_conectividad.py
```

**Salida esperada (todo OK):**

```
=== Prueba de conectividad y consultas cruzadas MariaDB ===
Nodos configurados: 2
  Nodo 0: 100.120.137.4:3306  BD=sucursal_morelia  user=Compañero
  Nodo 1: 100.119.128.65:3306 BD=suc_patzcuaro     user=Compañero

──────────────────────────────────────────────────────────────────────
  NODO 0: 100.120.137.4 — sucursal_morelia
──────────────────────────────────────────────────────────────────────
  ✔  TCP 100.120.137.4:3306  →  alcanzable  (3.2 ms)
  ✔  Autenticación  →  exitosa como 'Compañero'  (12.1 ms)
  ℹ  Versión:  10.11.6-MariaDB
  ℹ  Charset:  utf8mb4  /  utf8mb4_unicode_ci
  ✔  Replicación activa  ←  master: 100.119.128.65  |  retraso: 0s
  ✔  Master activo  →  binlog: mariadb-bin.000003  pos: 1024
...
──────────────────────────────────────────────────────────────────────
  RESUMEN
──────────────────────────────────────────────────────────────────────
  ✔  Todos los nodos (2/2) están accesibles y autenticados.
```

---

## 7. Paso 5 — Usar la API de diagnóstico del backend

Una vez que el backend Flask esté corriendo (`bash start.sh`), los endpoints
de diagnóstico están disponibles:

### `GET /api/diagnostico`

Verifica TCP + autenticación + estado de replicación de todos los nodos:

```bash
curl http://localhost:5000/api/diagnostico | python3 -m json.tool
```

Respuesta de ejemplo (nodo con error 1045):

```json
{
  "data": [
    {
      "nodo_index": 0,
      "host": "100.120.137.4",
      "estado": "ERROR_AUTH",
      "tcp": { "alcanzable": true, "latencia_ms": 3.2 },
      "autenticacion": {
        "autenticacion_ok": false,
        "error_codigo": 1045,
        "error_mensaje": "Access denied for user 'Compañero'@'...'",
        "diagnostico": "ERROR 1045 — Acceso denegado... SOLUCIÓN: GRANT ALL ON sucursal_morelia.* TO 'Compañero'@'%'..."
      }
    }
  ]
}
```

### `GET /api/diagnostico/consulta-cruzada`

Consulta `SELECT COUNT(*) FROM Clientes` en cada nodo:

```bash
curl http://localhost:5000/api/diagnostico/consulta-cruzada
```

---

## 8. Troubleshooting

### Error 1045 — Access denied

```
Síntoma: (1045, "Access denied for user 'Compañero'@'pc.taile8f403.ts.net'")
Causa:   El usuario no tiene privilegios para el host de origen.

Verificar:
  SELECT user, host FROM mysql.user WHERE user = 'Compañero';

Solución:
  GRANT ALL ON <bd>.* TO 'Compañero'@'%' IDENTIFIED BY '<pass>';
  FLUSH PRIVILEGES;
```

### Error 2003 — Can't connect to server

```
Síntoma: (2003, "Can't connect to MySQL server on '100.x.x.x' (111)")
Causa A: bind-address = 127.0.0.1 en my.cnf
Causa B: MariaDB no está corriendo
Causa C: Firewall bloqueando puerto 3306
Causa D: Tailscale no está activo o el peer está offline

Verificar:
  sudo systemctl status mariadb
  grep bind-address /etc/mysql/mariadb.conf.d/50-server.cnf
  tailscale status
  sudo ss -tlnp | grep 3306
  sudo ufw status   # o: sudo firewall-cmd --list-ports
```

### Replicación detenida (`Slave_IO_Running: No`)

```
Síntoma: SHOW SLAVE STATUS → Slave_IO_Running: No
Causa A: El MASTER_HOST no es alcanzable (Tailscale caído)
Causa B: Credenciales de replicación incorrectas
Causa C: El binlog del master fue rotado/eliminado

Verificar:
  SHOW SLAVE STATUS\G   -- leer Last_IO_Error

Reiniciar:
  STOP SLAVE;
  -- Si el binlog del master cambió, re-ejecutar CHANGE MASTER con nueva posición
  START SLAVE;
```

### Conflictos de ID en replicación bidireccional

```
Síntoma: Duplicate entry '1500' for key 'PRIMARY'
Causa:   Ambos nodos insertan en la misma tabla con overlapping de IDs

Solución en este proyecto:
  El particionamiento por rango (BLOCK_SIZE=1500) + AUTO_INCREMENT
  configurado por nodo garantiza que los IDs nunca colisionen.
  Verificar que AUTO_INCREMENT esté bien configurado:

  Nodo 0: ALTER TABLE Clientes AUTO_INCREMENT = 1;
  Nodo 1: ALTER TABLE Clientes AUTO_INCREMENT = 1501;
```

### Charset — caracteres especiales (ñ, acentos)

```
Síntoma: Nombres como 'Compañero' aparecen como 'Compa?ero'
Causa:   charset del servidor no es utf8mb4

Solución en my.cnf:
  character-set-server = utf8mb4
  collation-server     = utf8mb4_unicode_ci

Y en la conexión Python (ya configurado en config.py via PyMySQL):
  charset='utf8mb4'  # PyMySQL lo usa por defecto en versiones recientes
```

---

## 9. Consideraciones sobre el diseño de particionamiento

### Estrategia actual: fragmentación horizontal por rangos

```
Nodo 0: IDs 1    – 1500   (BLOCK_SIZE × 0 + 1  →  BLOCK_SIZE × 1)
Nodo 1: IDs 1501 – 3000   (BLOCK_SIZE × 1 + 1  →  BLOCK_SIZE × 2)
```

Esta estrategia en [`config.py`](../backend/config.py) + [`db.py`](../backend/db.py)
garantiza:

- **Sin conflictos de ID** entre nodos (cada nodo solo inserta en su rango)
- **Localidad de datos** (un cliente y sus direcciones siempre están en el mismo nodo)
- **Consultas globales eficientes** (`execute_on_all_nodes_parallel` usa threads)

### Rol de la replicación bidireccional en este diseño

La replicación binlog aquí no duplica filas — cada nodo replica su propio
fragmento hacia el otro para:

1. **Respaldo automático**: si un nodo cae, el otro tiene una copia del binlog
2. **Auditoría cruzada**: cada nodo puede ver el historial de operaciones del otro
3. **Alta disponibilidad**: en caso de falla del nodo propietario, se puede
   recuperar el estado desde la réplica

Para un modelo donde ambos nodos deben poder leer **todos** los clientes sin
necesitar consultar el nodo remoto, se requeriría replicar las tablas completas
(no solo el binlog del fragmento local), lo que implicaría un rediseño de la
arquitectura de particionamiento.

---

*Documento generado para el proyecto de Bases de Datos Distribuidas.*
*Nodos Tailscale: 100.120.137.4 (Morelia) · 100.119.128.65 (Pátzcuaro)*
