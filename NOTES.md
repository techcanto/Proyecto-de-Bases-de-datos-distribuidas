# DistributedDatabasesProject — Notas del Proyecto

## Descripción general

Sistema de base de datos distribuida para una tienda con múltiples sucursales.  
Conecta 2 (o más) instancias de **MariaDB** en computadoras diferentes sobre redes distintas usando **Tailscale** como VPN.

La arquitectura implementa **fragmentación horizontal**: cada sucursal almacena solo los clientes de ese nodo, pero desde la interfaz el usuario ve una sola base de datos unificada.

---

## Arquitectura

```
┌──────────────────────────────────────────────────────┐
│  Navegador  →  http://localhost:5000/                │
│             (frontend servido por Flask)             │
└─────────────────────┬────────────────────────────────┘
                      │ API REST (JSON)
              ┌───────▼───────┐
              │  Flask 3.x    │  backend/app.py
              │  puerto 5000  │
              └──┬────────┬───┘
     ┌───────────┘        └───────────┐
     ▼                               ▼
 Nodo 0                           Nodo 1
 MariaDB                          MariaDB
 100.120.137.4:3306               100.119.128.65:3306
 IDs 1 – 1500                     IDs 1501 – 3000
 (Sucursal A)                     (Sucursal B — esta máquina)
```

---

## Reglas de negocio / enrutamiento

| Operación        | Nodo destino                          |
|------------------|---------------------------------------|
| INSERT cliente   | Solo nodo **local** (sucursal actual) |
| UPDATE cliente   | Nodo propietario del ID               |
| DELETE cliente   | Nodo propietario del ID               |
| SELECT / buscar  | **Todos** los nodos en paralelo       |
| DDL (CREATE TABLE, DROP TABLE) | **Todos** los nodos    |

**Fragmentación horizontal:** los IDs se asignan en bloques de `BLOCK_SIZE = 1500`.  
El nodo con índice `i` maneja IDs en el rango `[i*1500+1, (i+1)*1500]`.

**Sin duplicados:** columna `RFC` tiene `UNIQUE` en cada nodo. Las búsquedas por RFC cruzan todos los nodos, garantizando unicidad global.

---

## Estructura del proyecto

```
DistributedDatabasesProject/
├── frontend/
│   ├── index.html      # UI completa (SPA)
│   ├── app.js          # Toda la lógica JS del frontend
│   └── style.css       # Estilos
├── backend/
│   ├── app.py          # Flask app: rutas estáticas + blueprints
│   ├── config.py       # NODES, BLOCK_SIZE, detect_local_node()
│   ├── db.py           # Helpers de conexión y ejecución distribuida
│   ├── requirements.txt
│   └── routes/
│       ├── clientes.py    # CRUD de Clientes
│       ├── direcciones.py # CRUD de Direcciones
│       ├── tablas.py      # Gestión de tablas distribuidas (DDL)
│       └── tailscale.py   # Estado de conectividad Tailscale
├── start.sh            # Arranca el backend Flask en background
├── stop.sh             # Detiene el backend
├── NOTES.md            # Este archivo
└── README.md
```

---

## API REST

### Clientes
| Método | Endpoint                        | Descripción                              |
|--------|---------------------------------|------------------------------------------|
| GET    | `/api/clientes`                 | Listar todos (todos los nodos)           |
| GET    | `/api/clientes/buscar?q=&campo=`| Buscar por `nombre`, `rfc` o `domicilio` |
| GET    | `/api/clientes/<id>`            | Obtener uno por ID                       |
| POST   | `/api/clientes`                 | Crear (solo nodo local)                  |
| PUT    | `/api/clientes/<id>`            | Actualizar (nodo propietario del ID)     |
| DELETE | `/api/clientes/<id>`            | Eliminar (nodo propietario del ID)       |
| GET    | `/api/nodo-info`                | Info del nodo local (index, IPs, rango)  |

### Direcciones
| Método | Endpoint                                | Descripción                       |
|--------|-----------------------------------------|-----------------------------------|
| GET    | `/api/clientes/<id>/direcciones`        | Listar direcciones de un cliente  |
| POST   | `/api/clientes/<id>/direcciones`        | Agregar dirección (solo local)    |
| PUT    | `/api/direcciones/<dir_id>`             | Actualizar (nodo del cliente)     |
| DELETE | `/api/direcciones/<dir_id>`             | Eliminar (nodo del cliente)       |

### Tablas
| Método | Endpoint           | Descripción                           |
|--------|--------------------|---------------------------------------|
| GET    | `/api/tablas`      | Listar tablas (nodo local)            |
| POST   | `/api/tablas`      | Crear tabla en TODOS los nodos (DDL)  |
| DELETE | `/api/tablas/<n>`  | Eliminar tabla en TODOS los nodos     |

### Tailscale
| Método | Endpoint         | Descripción                                      |
|--------|------------------|--------------------------------------------------|
| GET    | `/api/tailscale` | Estado de conectividad: nodos online/offline     |

---

## Configuración de nodos (`config.py`)

```python
BLOCK_SIZE = 1500   # IDs por nodo

NODES = [
    {"host": "100.120.137.4",  "port": 3306, "db": "sucursal_morelia", "user": "...", "password": "..."},
    {"host": "100.119.128.65", "port": 3306, "db": "suc_patzcuaro",    "user": "...", "password": "..."},
]
```

### Agregar una nueva sucursal

1. Añadir un dict en `NODES` con la IP Tailscale del nuevo nodo.
2. En la nueva BD ejecutar:
   ```sql
   ALTER TABLE Clientes AUTO_INCREMENT = <indice> * 1500 + 1;
   ```
3. Reiniciar el backend.

---

## Tailscale (VPN entre sucursales)

Cada máquina debe estar conectada a la misma red Tailscale.

- **Verificar estado:** botón **Tailscale** en la barra de navegación de la UI.
  - 🟢 Verde = todos los nodos del sistema en línea.
  - 🟡 Naranja = algunos nodos en línea (conexión parcial).
  - 🔴 Rojo = sin conectividad Tailscale.
- **Conectarse:** `tailscale up`
- **Ver peers:** `tailscale status`

---

## Cómo ejecutar

```bash
# Arrancar
bash start.sh

# Detener
bash stop.sh
```

El frontend queda disponible en **http://localhost:5000/**.

---

## Cambios realizados (historial)

### 2026-11-16
- **Fix crítico:** Flask ahora sirve el frontend en `http://localhost:5000/`.  
  Antes: `GET /` devolvía 404 (Flask no tenía ruta raíz).  
  Ahora: `app.py` agrega rutas `"/"` y `"/<path:filename>"` para servir la carpeta `frontend/`.
- **Fix backend:** Detectado que el modo debug de Flask con el reloader forkea un proceso hijo, haciendo que el PID guardado en `backend.pid` fuera el del proceso padre (que termina). Solución: `app.run(debug=False)` cuando no hay TTY (modo background). `start.sh` usa `setsid nohup` para garantizar que el proceso sobreviva al cierre del shell.
- **API Tailscale:** Nuevo endpoint `GET /api/tailscale` en `backend/routes/tailscale.py` que ejecuta `tailscale status --json` y devuelve el estado de cada nodo del sistema y de todos los peers.
- **UI Tailscale:** Botón en la navbar con indicador de color (verde/naranja/rojo) y modal con detalle de conectividad por nodo.
- **API relativa:** `app.js` ahora usa `const API = ""` (URL relativa) en lugar de `http://localhost:5000`, para funcionar desde cualquier máquina.
- **NOTES.md:** Creado este archivo de documentación.
