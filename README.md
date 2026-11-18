# Sistema de Tiendas con Base de Datos Distribuida

Sistema de gestión de clientes con **fragmentación horizontal** sobre múltiples nodos MariaDB conectados mediante Tailscale. Cada sucursal tiene su propio servidor de base de datos y el backend enruta las operaciones automáticamente al nodo correcto.

---

## ¿Qué hace este sistema?

- **Registrar** clientes y direcciones en la sucursal local
- **Consultar y actualizar** clientes desde cualquier sucursal
- **Buscar** por nombre, RFC o domicilio en todos los nodos simultáneamente
- **Crear tablas distribuidas** propagando el esquema a todos los nodos

La lógica de enrutamiento es transparente: el backend determina automáticamente a qué nodo enviar cada operación según el ID del cliente.

---

## Arquitectura

```
[Navegador — HTML/CSS/JS]
        │
        │ HTTP (fetch)
        ▼
[Backend Flask — Python]
        │
        ├─── INSERT (solo nodo local) ──────► [MariaDB Nodo 0]
        ├─── UPDATE/DELETE (por ID) ────────► [Nodo correcto según rango]
        ├─── SELECT global (paralelo) ──────► [Todos los nodos — merge]
        └─── CREATE/DROP TABLE ─────────────► [Todos los nodos]
```

### Fragmentación por rangos de IDs

| Nodo | BD | Rango de IDs | AUTO_INCREMENT inicial |
|------|----|--------------|------------------------|
| 0    | `NODE0_DB` | 1 – 1500       | 1    |
| 1    | `NODE1_DB` | 1501 – 3000    | 1501 |
| 2    | `NODE2_DB` | 3001 – 4500    | 3001 |

El tamaño del bloque (`BLOCK_SIZE=1500`) se configura en `.env`.

---

## Requisitos previos

- Python 3.10+
- MariaDB 10.6+ (o MySQL 8+) accesible en cada nodo
- [Tailscale](https://tailscale.com/) instalado y activo en todas las máquinas

---

## Instalación paso a paso

### 1. Clonar el repositorio

```bash
git clone https://github.com/tu-usuario/DistributedDatabasesProject.git
cd DistributedDatabasesProject
```

### 2. Instalar dependencias Python

```bash
pip install -r backend/requirements.txt
```

### 3. Configurar variables de entorno

Copiar el archivo de ejemplo y rellenarlo con los datos reales:

```bash
cp .env.example .env
```

Editar `.env`:

```ini
NODE0_HOST=100.x.x.x          # IP Tailscale del Nodo 0
NODE0_PORT=3306
NODE0_DB=sucursal_morelia
NODE0_USER=usuario_app         # usuario MariaDB (solo caracteres ASCII)
NODE0_PASSWORD=contraseña_app  # contraseña (solo caracteres ASCII — sin ñ ni acentos)

NODE1_HOST=100.x.x.x          # IP Tailscale del Nodo 1
NODE1_PORT=3306
NODE1_DB=suc_patzcuaro
NODE1_USER=usuario_app
NODE1_PASSWORD=contraseña_app

BLOCK_SIZE=1500
```

> **Importante:** Las contraseñas deben usar solo caracteres ASCII (sin `ñ` ni acentos). Esto es un requisito del driver PyMySQL en su interacción con MariaDB 13.

### 4. Inicializar la base de datos en cada nodo

Ejecutar en MariaDB de cada nodo (como root):

```bash
# Personalizar las variables y ejecutar:
mariadb -u root -p < scripts/sql/setup.sql
```

Los valores a reemplazar en `setup.sql`:

| Variable | Nodo 0 | Nodo 1 |
|----------|--------|--------|
| `<nombre_bd>` | `sucursal_morelia` | `suc_patzcuaro` |
| `<usuario>` | valor de `NODE0_USER` | valor de `NODE1_USER` |
| `<contraseña>` | valor de `NODE0_PASSWORD` | valor de `NODE1_PASSWORD` |
| `<ai_inicio>` | `1` | `1501` |

> **Nota sobre contraseñas y PyMySQL:** Si el usuario ya existe con una contraseña que contiene caracteres non-ASCII (como `ñ`), PyMySQL no podrá autenticarse porque codifica la contraseña en latin-1 durante el handshake mientras el hash en la BD fue creado en UTF-8. Cambiar la contraseña a una ASCII resuelve el problema:
> ```sql
> SET PASSWORD = PASSWORD('NuevaContrasenaSinEnie123!');
> ```

### 5. Verificar conectividad

```bash
python scripts/pruebas/prueba_conectividad.py
```

Salida esperada:
```
✔  TCP 100.x.x.x:3306  →  alcanzable  (X ms)
✔  Autenticación  →  exitosa como 'usuario_app'
✔  Tablas encontradas: Clientes, Direcciones
```

### 6. Arrancar el sistema

```bash
bash start.sh
```

El sistema estará disponible en **http://localhost:5000**.

Para detenerlo:

```bash
bash stop.sh
```

---

## Estructura del proyecto

```
├── .env.example              ← Plantilla de configuración (copiar a .env)
├── .gitignore
├── start.sh                  ← Arranca el sistema completo
├── stop.sh                   ← Detiene el backend
│
├── backend/
│   ├── app.py                ← Instancia Flask y registro de blueprints
│   ├── config.py             ← Carga .env, construye NODES, detecta nodo local
│   ├── db.py                 ← Enrutamiento y helpers de BD
│   ├── requirements.txt      ← Dependencias Python
│   └── routes/
│       ├── clientes.py       ← CRUD de clientes (8 endpoints)
│       ├── diagnostico.py    ← Diagnóstico de conectividad entre nodos
│       ├── direcciones.py    ← CRUD de direcciones (4 endpoints)
│       ├── tablas.py         ← Gestión de tablas distribuidas (3 endpoints)
│       └── tailscale.py      ← Estado de conectividad Tailscale
│
├── frontend/
│   ├── index.html
│   ├── style.css
│   └── app.js
│
└── scripts/
    ├── setup_nuevo_nodo.sh              ← ★ Nueva sucursal: configura BD, .env y Python
    ├── unirse_a_la_red.sh               ← ★ Nodo existente: agrega la nueva sucursal a su .env
    ├── sql/
    │   ├── setup.sql                    ← Inicialización de BD (manual, usar en cada nodo)
    │   ├── 01_usuarios_permisos.sql     ← Configuración de usuarios
    │   └── fix_definitivo_nodo*.sql     ← Fix del error 1045
    └── pruebas/
        └── prueba_conectividad.py       ← Prueba TCP + auth + replicación
```

---

## API — Endpoints

### Clientes

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/nodo-info` | Info del nodo local (índice, rango de IDs, host) |
| `GET` | `/api/clientes` | Lista todos los clientes de todos los nodos |
| `GET` | `/api/clientes/buscar?q=&campo=` | Busca por `nombre`, `rfc` o `domicilio` |
| `GET` | `/api/clientes/<id>` | Obtiene un cliente por ID (con fallback a búsqueda global) |
| `GET` | `/api/clientes/rfc/<rfc>` | Obtiene un cliente por RFC (único globalmente) |
| `POST` | `/api/clientes` | Crea un cliente en el nodo local |
| `PUT` | `/api/clientes/<id>` | Actualiza un cliente (con fallback global) |
| `DELETE` | `/api/clientes/<id>` | Elimina un cliente y sus direcciones (con fallback global) |

### Direcciones

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/clientes/<id>/direcciones` | Lista las direcciones de un cliente |
| `POST` | `/api/clientes/<id>/direcciones` | Agrega dirección (solo si el cliente es del nodo local) |
| `PUT` | `/api/direcciones/<id>` | Actualiza una dirección (requiere `IdCliente` en body) |
| `DELETE` | `/api/direcciones/<id>` | Elimina una dirección (requiere `IdCliente` en body) |

### Tablas distribuidas

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/tablas` | Lista las tablas del nodo local |
| `POST` | `/api/tablas` | Crea una tabla en **todos** los nodos |
| `DELETE` | `/api/tablas/<nombre>` | Elimina una tabla en **todos** los nodos |

### Diagnóstico

| Método | Ruta | Descripción |
|--------|------|-------------|
| `GET` | `/api/diagnostico` | TCP + auth + replicación de cada nodo |
| `GET` | `/api/diagnostico/consulta-cruzada` | COUNT(*) de Clientes en cada nodo |

---

## Agregar una nueva sucursal (automatizado)

La incorporación de un nuevo nodo se divide en dos partes: lo que hace la **nueva sucursal** y lo que hacen los **nodos existentes**.

### En la nueva máquina (nueva sucursal)

```bash
# 1. Instalar Tailscale y unirse a la red del equipo
#    https://tailscale.com/download
sudo tailscale up

# 2. Clonar el proyecto
git clone https://github.com/tu-usuario/DistributedDatabasesProject.git
cd DistributedDatabasesProject

# 3. Ejecutar el script de configuración
bash scripts/setup_nuevo_nodo.sh
```

El script guía paso a paso:
- Verifica que Tailscale esté activo y obtiene la IP asignada.
- Verifica que MariaDB esté instalado y en ejecución.
- Pide el nombre de la BD, usuario y contraseña para esta sucursal.
- Pide los datos de conexión de **cada nodo ya existente** en la red.
- Inicializa la BD local con las tablas correctas y el `AUTO_INCREMENT` correspondiente al índice del nuevo nodo.
- Genera el archivo `.env` completo listo para usar.
- Al finalizar, imprime un resumen con los datos que hay que compartir.

> **Nota sobre AUTO_INCREMENT:** cada nodo tiene un bloque de IDs reservado.
> El nodo N arranca en `N × 1500 + 1`. Esto garantiza que los IDs de clientes
> sean únicos en toda la red sin necesidad de coordinación centralizada.

### En cada nodo existente (Morelia, Pátzcuaro, etc.)

Cuando la nueva sucursal esté lista y te comparta sus datos, ejecuta en **cada** nodo ya existente:

```bash
bash scripts/unirse_a_la_red.sh
```

El script:
- Detecta automáticamente cuántos nodos hay en el `.env` actual.
- Pide los datos del nuevo nodo (IP Tailscale, BD, usuario, contraseña).
- Verifica la conectividad TCP, la autenticación MariaDB, que las tablas existan y que el `AUTO_INCREMENT` sea correcto.
- Hace un backup del `.env` actual y agrega el nuevo nodo.
- Reinicia el backend si ya estaba en ejecución.

### ¿Qué pasa con los datos existentes?

- Los registros de clientes ya existentes en Morelia y Pátzcuaro **no se migran** al nuevo nodo.
- El nuevo nodo puede **consultar** todos los registros de los demás nodos en tiempo real (el backend los une en paralelo automáticamente).
- Los **nuevos clientes** que lleguen a la nueva sucursal se guardarán localmente en su MariaDB (fragmentación horizontal).
- El esquema de tablas se propaga automáticamente cuando alguien crea una tabla nueva desde cualquier sucursal (el DDL se ejecuta en todos los nodos).

### Resumen del flujo

```
Nueva sucursal                    Nodos existentes
─────────────                     ────────────────
1. sudo tailscale up
2. git clone ...
3. bash scripts/setup_nuevo_nodo.sh
   → configura BD local
   → genera .env
   → imprime IP + datos
                    ──datos──►  bash scripts/unirse_a_la_red.sh
                                → verifica conectividad
                                → actualiza .env
                                → reinicia backend
4. bash start.sh
```

---

## Troubleshooting

### Error 1045 — Access denied

```
Causa:   El usuario de MariaDB no tiene permisos para el host remoto,
         o la contraseña contiene caracteres non-ASCII (bug de PyMySQL).

Solución A — permisos:
  GRANT ALL ON <bd>.* TO 'usuario'@'%' IDENTIFIED BY 'contraseña';
  FLUSH PRIVILEGES;

Solución B — contraseña non-ASCII:
  SET PASSWORD = PASSWORD('NuevaContrasenaSinEnie123!');
  (actualizar también en .env)
```

### Error 2003 — Can't connect

```
Causa:   MariaDB no escucha en la interfaz Tailscale.

Verificar /etc/mysql/mariadb.conf.d/50-server.cnf:
  bind-address = 0.0.0.0   ← debe ser esto, NO 127.0.0.1

Reiniciar: sudo systemctl restart mariadb
```

### "Cliente no encontrado" al editar/eliminar

```
Causa:   AUTO_INCREMENT no estaba configurado al valor correcto para el nodo.
         Los clientes se crearon con IDs del rango de otro nodo.

Verificar:
  SELECT AUTO_INCREMENT FROM information_schema.TABLES
   WHERE TABLE_SCHEMA='<bd>' AND TABLE_NAME='Clientes';

El valor debe ser:
  Nodo 0: entre 1 y 1500
  Nodo 1: entre 1501 y 3000

Corregir:
  ALTER TABLE Clientes AUTO_INCREMENT = 1501;  -- para el nodo 1
```

### El nodo local no se detecta correctamente

```
Causa:   socket.gethostname() no resuelve a la IP Tailscale.

Solución: agregar en .env:
  LOCAL_NODE_INDEX=1   ← índice explícito del nodo (0, 1, 2...)
```

---

## Reglas de negocio

| Operación | Regla |
|-----------|-------|
| Insertar cliente o dirección | Solo desde la **sucursal local** |
| Actualizar cliente o dirección | Desde **cualquier** sucursal |
| Buscar / listar clientes | Desde **cualquier** sucursal — consulta todos los nodos en paralelo |
| Crear / eliminar tablas | Se propaga a **todos** los nodos |
