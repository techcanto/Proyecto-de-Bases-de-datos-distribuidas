#!/usr/bin/env bash
# =============================================================================
# setup_nuevo_nodo.sh — Configuración automática de una nueva sucursal
#
# Uso (desde la raíz del proyecto clonado):
#   bash scripts/setup_nuevo_nodo.sh
#
# Lo que hace este script:
#   1. Verifica que Tailscale esté instalado y activo.
#   2. Verifica que MariaDB esté instalado y en ejecución.
#   3. Pide al usuario los datos de la nueva sucursal y los datos de acceso
#      a TODOS los nodos ya existentes en la red.
#   4. Inicializa la base de datos local con el AUTO_INCREMENT correcto.
#   5. Crea el archivo .env listo para usar.
#   6. Instala las dependencias Python.
#   7. Muestra el resumen con los datos que hay que compartir con los
#      demás nodos (para que actualicen su .env).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/.env"
BACKEND_DIR="$ROOT_DIR/backend"

# ── Colores ────────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
BOLD="\033[1m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
paso()    { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; }
error()   { echo -e "${RED}[✘]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }

# ── Lectura segura con valor por defecto ───────────────────────────────────────
ask() {
    # ask "Pregunta" "valor_default" → escribe en variable $REPLY
    local prompt="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        echo -ne "${YELLOW}  →${RESET} $prompt [${default}]: "
    else
        echo -ne "${YELLOW}  →${RESET} $prompt: "
    fi
    read -r REPLY
    if [[ -z "$REPLY" && -n "$default" ]]; then
        REPLY="$default"
    fi
}

ask_secret() {
    local prompt="$1"
    echo -ne "${YELLOW}  →${RESET} $prompt (oculto): "
    read -rs REPLY
    echo
}

# =============================================================================
# PASO 0 — Presentación
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Configuración de nueva sucursal — Sistema Distribuido  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  Este script configura esta máquina como un nuevo nodo de la red."
echo "  Necesitarás tener a mano:"
echo "    • Los datos de conexión (IP, BD, usuario, contraseña) de cada nodo"
echo "      que ya forma parte de la red."
echo "    • Acceso root (o sudo) a MariaDB en esta máquina."
echo ""
warn "Si ya existe un archivo .env en este directorio, será sobreescrito."
echo ""

# =============================================================================
# PASO 1 — Verificar Tailscale
# =============================================================================
paso "1/5  Verificando Tailscale"

if ! command -v tailscale &>/dev/null; then
    error "Tailscale no está instalado."
    echo ""
    echo "  Instálalo desde: https://tailscale.com/download"
    echo ""
    echo "  Linux (una línea):"
    echo "    curl -fsSL https://tailscale.com/install.sh | sh"
    echo "    sudo tailscale up"
    echo ""
    fatal "Instala Tailscale y vuelve a ejecutar este script."
fi

TS_IP=""
if TS_IP=$(tailscale ip -4 2>/dev/null) && [[ -n "$TS_IP" ]]; then
    info "Tailscale activo. IP de esta máquina: ${BOLD}$TS_IP${RESET}"
else
    error "Tailscale está instalado pero no está activo o no tiene IP asignada."
    echo ""
    echo "  Ejecuta: sudo tailscale up"
    echo "  Luego vuelve a correr este script."
    echo ""
    fatal "Activa Tailscale antes de continuar."
fi

# =============================================================================
# PASO 2 — Verificar MariaDB
# =============================================================================
paso "2/5  Verificando MariaDB"

MARIADB_CMD=""
for cmd in mariadb mysql; do
    if command -v "$cmd" &>/dev/null; then
        MARIADB_CMD="$cmd"
        break
    fi
done

if [[ -z "$MARIADB_CMD" ]]; then
    error "No se encontró el cliente de MariaDB (mariadb o mysql)."
    echo ""
    echo "  Instala MariaDB:"
    echo "    Ubuntu/Debian: sudo apt install mariadb-server"
    echo "    Arch Linux:    sudo pacman -S mariadb && sudo mariadb-install-db && sudo systemctl start mariadb"
    echo "    Fedora/RHEL:   sudo dnf install mariadb-server && sudo systemctl start mariadb"
    echo ""
    fatal "Instala MariaDB y vuelve a ejecutar este script."
fi

if ! systemctl is-active --quiet mariadb 2>/dev/null && \
   ! systemctl is-active --quiet mysql   2>/dev/null; then
    warn "El servicio MariaDB no parece estar activo."
    echo ""
    echo "  Inicia el servicio:"
    echo "    sudo systemctl start mariadb"
    echo ""
    ask "¿Deseas continuar de todas formas? (s/n)" "s"
    [[ "$REPLY" =~ ^[sS]$ ]] || fatal "Inicia MariaDB y vuelve a ejecutar el script."
fi

info "Cliente MariaDB disponible: $MARIADB_CMD"

# Verificar que bind-address no sea 127.0.0.1
MY_CNF_PATHS=(
    /etc/mysql/mariadb.conf.d/50-server.cnf
    /etc/mysql/my.cnf
    /etc/my.cnf
    /etc/mariadb/my.cnf
)
BIND_WARNING=false
for cfg in "${MY_CNF_PATHS[@]}"; do
    if [[ -f "$cfg" ]] && grep -qE '^\s*bind-address\s*=\s*127\.0\.0\.1' "$cfg" 2>/dev/null; then
        BIND_WARNING=true
        warn "ATENCIÓN: $cfg tiene bind-address = 127.0.0.1"
        echo "  Esto impide conexiones remotas. Cámbialo a:"
        echo "    bind-address = 0.0.0.0"
        echo "  y reinicia: sudo systemctl restart mariadb"
        echo ""
    fi
done

# =============================================================================
# PASO 3 — Recopilar información de la nueva sucursal y de los nodos existentes
# =============================================================================
paso "3/5  Configuración de la red"

echo ""
echo -e "  ${BOLD}=== Datos de ESTA nueva sucursal ===${RESET}"
echo ""

ask "Nombre de la base de datos para ESTA sucursal (ej: suc_guadalajara)" ""
while [[ -z "$REPLY" ]]; do
    warn "El nombre de la BD no puede estar vacío."
    ask "Nombre de la base de datos para ESTA sucursal" ""
done
NEW_DB="$REPLY"

ask "Nombre del usuario MariaDB para la aplicación (ej: app_user)" "app_user"
NEW_USER="$REPLY"

ask_secret "Contraseña para el usuario '$NEW_USER' (solo caracteres ASCII, sin ñ ni acentos)"
while [[ -z "$REPLY" ]]; do
    warn "La contraseña no puede estar vacía."
    ask_secret "Contraseña para el usuario '$NEW_USER'"
done
NEW_PASSWORD="$REPLY"

ask "Puerto MariaDB de ESTA sucursal" "3306"
NEW_PORT="$REPLY"

echo ""
echo -e "  ${BOLD}=== Nodos existentes en la red ===${RESET}"
echo ""
echo "  Ingresa los datos de cada nodo ya existente."
echo "  Cuando no haya más nodos, deja el HOST en blanco y presiona Enter."
echo ""

EXISTING_NODES=()   # array de "HOST PORT DB USER PASSWORD"
NODE_IDX=0

while true; do
    echo -e "  --- Nodo existente #${NODE_IDX} ---"
    ask "HOST (IP Tailscale, ej: 100.x.x.x) — deja vacío para terminar" ""
    EX_HOST="$REPLY"
    [[ -z "$EX_HOST" ]] && break

    ask "Puerto" "3306"
    EX_PORT="$REPLY"

    ask "Nombre de la base de datos en ese nodo" ""
    while [[ -z "$REPLY" ]]; do
        warn "No puede estar vacío."
        ask "Nombre de la base de datos en ese nodo" ""
    done
    EX_DB="$REPLY"

    ask "Usuario MariaDB de ese nodo" "app_user"
    EX_USER="$REPLY"

    ask_secret "Contraseña para '$EX_USER' en $EX_HOST"
    EX_PASSWORD="$REPLY"

    # Guardar como string separado por tabulador
    EXISTING_NODES+=("${EX_HOST}\t${EX_PORT}\t${EX_DB}\t${EX_USER}\t${EX_PASSWORD}")
    NODE_IDX=$((NODE_IDX + 1))
    echo ""
done

TOTAL_EXISTING=${#EXISTING_NODES[@]}
NEW_NODE_INDEX=$TOTAL_EXISTING   # El nuevo nodo ocupa el siguiente índice
AI_INICIO=$(( NEW_NODE_INDEX * 1500 + 1 ))

echo ""
info "Esta sucursal será el Nodo ${NEW_NODE_INDEX} (AUTO_INCREMENT = ${AI_INICIO})"

# =============================================================================
# PASO 4 — Inicializar la base de datos local
# =============================================================================
paso "4/5  Inicializando la base de datos local"

echo ""
echo "  Necesitamos acceso root (o administrador) a MariaDB para crear la BD."
echo ""
ask "Usuario root de MariaDB" "root"
ROOT_USER="$REPLY"

echo -ne "${YELLOW}  →${RESET} Contraseña para '$ROOT_USER' en MariaDB local (oculto): "
read -rs ROOT_PASSWORD
echo ""

# Construir el SQL de inicialización de forma segura
INIT_SQL=$(cat <<ENDSQL
CREATE DATABASE IF NOT EXISTS \`${NEW_DB}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE \`${NEW_DB}\`;

CREATE TABLE IF NOT EXISTS Clientes (
    Id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    Nombre          VARCHAR(80)     NOT NULL,
    ApellidoPaterno VARCHAR(80)     NOT NULL,
    ApellidoMaterno VARCHAR(80)     DEFAULT NULL,
    RFC             VARCHAR(13)     NOT NULL,
    IdDireccion     BIGINT UNSIGNED  DEFAULT NULL,
    PRIMARY KEY (Id),
    UNIQUE KEY uq_rfc (RFC)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS Direcciones (
    Id         BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    Calle      VARCHAR(120)     NOT NULL,
    Numero     VARCHAR(20)      NOT NULL,
    Colonia    VARCHAR(100)     NOT NULL,
    Estado     VARCHAR(100)     NOT NULL,
    CP         CHAR(5)          NOT NULL,
    IdCliente  BIGINT UNSIGNED  NOT NULL,
    PRIMARY KEY (Id),
    FOREIGN KEY (IdCliente) REFERENCES Clientes(Id) ON DELETE CASCADE
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

ALTER TABLE Clientes AUTO_INCREMENT = ${AI_INICIO};

CREATE USER IF NOT EXISTS '${NEW_USER}'@'%'
    IDENTIFIED BY '${NEW_PASSWORD}';

ALTER USER '${NEW_USER}'@'%'
    IDENTIFIED BY '${NEW_PASSWORD}';

GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON \`${NEW_DB}\`.*
    TO '${NEW_USER}'@'%';

FLUSH PRIVILEGES;
ENDSQL
)

if echo "$INIT_SQL" | "$MARIADB_CMD" -u "$ROOT_USER" -p"${ROOT_PASSWORD}" 2>/dev/null; then
    info "Base de datos '${NEW_DB}' inicializada correctamente."
    info "AUTO_INCREMENT = ${AI_INICIO} (Nodo ${NEW_NODE_INDEX})"
else
    error "Error al ejecutar el SQL de inicialización."
    echo ""
    echo "  Verifica que el usuario '${ROOT_USER}' tenga permisos de administrador"
    echo "  y que MariaDB esté en ejecución."
    echo ""
    echo "  Puedes ejecutar manualmente el SQL de inicialización."
    echo "  Consulta: scripts/sql/setup.sql"
    echo ""
    fatal "Fallo en la inicialización de la BD."
fi

# =============================================================================
# PASO 5 — Generar .env
# =============================================================================
paso "5/5  Generando archivo .env"

{
    echo "# Generado automáticamente por scripts/setup_nuevo_nodo.sh"
    echo "# $(date)"
    echo ""
    echo "# ── Nodos existentes ──────────────────────────────────────────────────────────"
    echo ""

    local_idx=0
    for entry in "${EXISTING_NODES[@]}"; do
        IFS=$'\t' read -r EX_HOST EX_PORT EX_DB EX_USER EX_PASSWORD <<< "$(echo -e "$entry")"
        echo "NODE${local_idx}_HOST=${EX_HOST}"
        echo "NODE${local_idx}_PORT=${EX_PORT}"
        echo "NODE${local_idx}_DB=${EX_DB}"
        echo "NODE${local_idx}_USER=${EX_USER}"
        echo "NODE${local_idx}_PASSWORD=${EX_PASSWORD}"
        echo ""
        local_idx=$((local_idx + 1))
    done

    echo "# ── Este nodo (Nodo ${NEW_NODE_INDEX}) ─────────────────────────────────────────────────────"
    echo ""
    echo "NODE${NEW_NODE_INDEX}_HOST=${TS_IP}"
    echo "NODE${NEW_NODE_INDEX}_PORT=${NEW_PORT}"
    echo "NODE${NEW_NODE_INDEX}_DB=${NEW_DB}"
    echo "NODE${NEW_NODE_INDEX}_USER=${NEW_USER}"
    echo "NODE${NEW_NODE_INDEX}_PASSWORD=${NEW_PASSWORD}"
    echo ""
    echo "# ── Configuración general ────────────────────────────────────────────────────"
    echo "BLOCK_SIZE=1500"
    echo ""
    echo "# Forzar que esta máquina sea el nodo ${NEW_NODE_INDEX}"
    echo "LOCAL_NODE_INDEX=${NEW_NODE_INDEX}"
} > "$ENV_FILE"

info ".env generado en: $ENV_FILE"

# =============================================================================
# Instalar dependencias Python
# =============================================================================

PYTHON_BIN=""
for candidato in "$ROOT_DIR/.venv/bin/python3" "$ROOT_DIR/venv/bin/python3" \
                 "$ROOT_DIR/env/bin/python3"; do
    [[ -x "$candidato" ]] && { PYTHON_BIN="$candidato"; break; }
done
[[ -z "$PYTHON_BIN" ]] && command -v python3 &>/dev/null && PYTHON_BIN="$(command -v python3)"

if [[ -n "$PYTHON_BIN" ]]; then
    if ! "$PYTHON_BIN" -c "import flask, pymysql, flask_cors" &>/dev/null; then
        warn "Instalando dependencias Python..."
        "$PYTHON_BIN" -m pip install -r "$BACKEND_DIR/requirements.txt" --quiet \
            && info "Dependencias instaladas."
    else
        info "Dependencias Python ya instaladas."
    fi
else
    warn "No se encontró python3. Instala las dependencias manualmente:"
    echo "  pip install -r backend/requirements.txt"
fi

# =============================================================================
# RESUMEN FINAL
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ✔  Configuración completada                            ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Resumen de esta sucursal (Nodo ${NEW_NODE_INDEX}):${RESET}"
echo -e "    IP Tailscale : ${YELLOW}${TS_IP}${RESET}"
echo -e "    Base de datos: ${YELLOW}${NEW_DB}${RESET}"
echo -e "    Usuario BD   : ${YELLOW}${NEW_USER}${RESET}"
echo -e "    Puerto       : ${YELLOW}${NEW_PORT}${RESET}"
echo -e "    AUTO_INCREMENT inicia en: ${YELLOW}${AI_INICIO}${RESET}"
echo ""
echo -e "  ${BOLD}${YELLOW}⚠  ACCIÓN REQUERIDA en los otros nodos:${RESET}"
echo ""
echo "  Comparte estos datos con cada nodo existente en la red y pídeles"
echo "  que ejecuten el siguiente script para agregar esta sucursal:"
echo ""
echo -e "    ${CYAN}bash scripts/unirse_a_la_red.sh${RESET}"
echo ""
echo "  Los datos que necesitan ingresar:"
echo -e "    HOST     : ${BOLD}${TS_IP}${RESET}"
echo -e "    Puerto   : ${BOLD}${NEW_PORT}${RESET}"
echo -e "    Base de datos: ${BOLD}${NEW_DB}${RESET}"
echo -e "    Usuario  : ${BOLD}${NEW_USER}${RESET}"
echo -e "    Contraseña: (la que configuraste)"
echo ""
echo "  Una vez que TODOS los nodos hayan actualizado su .env, arranca el sistema:"
echo ""
echo -e "    ${CYAN}bash start.sh${RESET}"
echo ""
