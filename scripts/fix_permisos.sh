#!/usr/bin/env bash
# =============================================================================
# fix_permisos.sh — Corrección del error 1045 en MariaDB
#
# Ejecutar en CADA máquina con acceso root a MariaDB:
#   sudo bash scripts/fix_permisos.sh
#
# El script detecta automáticamente en qué nodo está corriendo y aplica
# los permisos correctos para la base de datos correspondiente.
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail() { echo -e "  ${RED}✘${RESET}  $*"; }
info() { echo -e "  ${BLUE}ℹ${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }

echo -e "\n${BOLD}=== Fix de permisos MariaDB — Error 1045 ===${RESET}\n"

# ── Configuración del proyecto ────────────────────────────────────────────────
USUARIO="Compañero"
PASSWORD="UnaContraseñaSegura123!"

# Mapeo de IPs Tailscale → nombre de BD
declare -A IP_A_BD=(
    ["100.120.137.4"]="sucursal_morelia"
    ["100.119.128.65"]="suc_patzcuaro"
)

# ── Detectar IP Tailscale local ───────────────────────────────────────────────
IP_LOCAL=""
if command -v tailscale &>/dev/null; then
    IP_LOCAL=$(tailscale ip -4 2>/dev/null | head -1 || true)
fi

# Si tailscale no está disponible, intentar con ip addr
if [[ -z "$IP_LOCAL" ]]; then
    IP_LOCAL=$(ip addr show | grep -oP '100\.\d+\.\d+\.\d+' | head -1 || true)
fi

info "IP Tailscale local detectada: ${IP_LOCAL:-'(no detectada)'}"

# ── Determinar BD local ───────────────────────────────────────────────────────
BD_LOCAL=""
if [[ -n "$IP_LOCAL" && -v "IP_A_BD[$IP_LOCAL]" ]]; then
    BD_LOCAL="${IP_A_BD[$IP_LOCAL]}"
    ok "Nodo identificado: $IP_LOCAL → BD '$BD_LOCAL'"
else
    warn "No se pudo identificar automáticamente el nodo."
    echo
    echo "  ¿En cuál nodo estás ejecutando este script?"
    echo "  1) 100.120.137.4  →  sucursal_morelia  (Morelia)"
    echo "  2) 100.119.128.65 →  suc_patzcuaro     (Pátzcuaro)"
    echo
    read -rp "  Escribe 1 o 2: " opcion
    case "$opcion" in
        1) BD_LOCAL="sucursal_morelia" ;;
        2) BD_LOCAL="suc_patzcuaro" ;;
        *) fail "Opción inválida. Saliendo."; exit 1 ;;
    esac
    ok "BD seleccionada manualmente: '$BD_LOCAL'"
fi

# ── Verificar acceso a MariaDB como root ──────────────────────────────────────
echo
info "Verificando acceso a MariaDB como root..."

MARIADB_CMD=""
if mariadb -u root -e "SELECT 1" &>/dev/null 2>&1; then
    MARIADB_CMD="mariadb -u root"
elif sudo mariadb -u root -e "SELECT 1" &>/dev/null 2>&1; then
    MARIADB_CMD="sudo mariadb -u root"
else
    warn "No se puede conectar como root sin contraseña."
    echo
    echo "  Opciones:"
    echo "  A) Si conoces la contraseña de root de MariaDB:"
    echo "     mariadb -u root -p"
    echo "     (pegar el SQL que se imprimirá abajo)"
    echo
    echo "  B) Si usas auth_socket (Ubuntu/Debian típico):"
    echo "     sudo mariadb  (sin contraseña)"
    echo
    echo "  El SQL a ejecutar manualmente es:"
    echo
    echo "  ─────────────────────────────────────────────────────────"
    cat <<ENDSQL
-- Paso 1: Ver estado actual
SELECT user, host, plugin FROM mysql.user WHERE user='${USUARIO}';

-- Paso 2: Eliminar entradas solo-localhost (si existen)
DROP USER IF EXISTS '${USUARIO}'@'localhost';
DROP USER IF EXISTS '${USUARIO}'@'127.0.0.1';
DROP USER IF EXISTS '${USUARIO}'@'::1';

-- Paso 3: Crear usuario para cualquier host
CREATE USER IF NOT EXISTS '${USUARIO}'@'%'
    IDENTIFIED BY '${PASSWORD}';

-- Si ya existe pero la contraseña puede estar mal:
ALTER USER '${USUARIO}'@'%'
    IDENTIFIED BY '${PASSWORD}';

-- Paso 4: Otorgar permisos
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON \`${BD_LOCAL}\`.*
    TO '${USUARIO}'@'%';

-- Paso 5: Aplicar
FLUSH PRIVILEGES;

-- Paso 6: Verificar
SELECT user, host, plugin FROM mysql.user WHERE user='${USUARIO}';
SHOW GRANTS FOR '${USUARIO}'@'%';
ENDSQL
    echo "  ─────────────────────────────────────────────────────────"
    echo
    info "Copia el SQL de arriba, conéctate a MariaDB como root y ejecútalo."
    exit 0
fi

ok "Acceso a MariaDB como root: OK"

# ── Diagnóstico previo ────────────────────────────────────────────────────────
echo
info "Estado actual del usuario '${USUARIO}' en MariaDB:"
$MARIADB_CMD -e \
    "SELECT user, host, plugin, password_expired, account_locked
       FROM mysql.user
      WHERE user='${USUARIO}'
      ORDER BY host;" 2>&1 || true

# ── Verificar si bind-address permite conexiones remotas ─────────────────────
echo
info "Verificando bind-address..."
BIND_ADDR=$($MARIADB_CMD -e "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null \
    | awk 'NR==2 {print $2}' || echo "desconocido")
info "bind_address = $BIND_ADDR"
if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
    warn "bind_address es 127.0.0.1 — MariaDB solo acepta conexiones locales."
    warn "Cambiar en /etc/mysql/mariadb.conf.d/50-server.cnf:"
    warn "  bind-address = 0.0.0.0"
    warn "Luego: sudo systemctl restart mariadb"
    warn "Continuando con la configuración de usuarios de todas formas..."
fi

# ── Aplicar corrección ────────────────────────────────────────────────────────
echo
info "Aplicando corrección de permisos para BD '${BD_LOCAL}'..."

$MARIADB_CMD <<ENDSQL
-- Eliminar entradas restrictivas
DROP USER IF EXISTS '${USUARIO}'@'localhost';
DROP USER IF EXISTS '${USUARIO}'@'127.0.0.1';
DROP USER IF EXISTS '${USUARIO}'@'::1';

-- Crear usuario para cualquier host (wildcard %)
CREATE USER IF NOT EXISTS '${USUARIO}'@'%'
    IDENTIFIED BY '${PASSWORD}';

-- Actualizar contraseña si el usuario ya existía
ALTER USER '${USUARIO}'@'%'
    IDENTIFIED BY '${PASSWORD}';

-- Otorgar permisos sobre la BD local
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP,
      INDEX, ALTER, LOCK TABLES, EXECUTE, SHOW VIEW
    ON \`${BD_LOCAL}\`.*
    TO '${USUARIO}'@'%';

-- Aplicar cambios
FLUSH PRIVILEGES;
ENDSQL

ok "Permisos aplicados."

# ── Verificación post-corrección ──────────────────────────────────────────────
echo
info "Verificación final:"
$MARIADB_CMD -e \
    "SELECT user, host, plugin FROM mysql.user WHERE user='${USUARIO}';" 2>&1

echo
$MARIADB_CMD -e "SHOW GRANTS FOR '${USUARIO}'@'%';" 2>&1

# ── Verificar bind_address y sugerir cambio si es necesario ──────────────────
if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
    echo
    warn "ACCIÓN REQUERIDA: bind-address sigue siendo 127.0.0.1"
    warn "Los permisos están corregidos pero MariaDB no acepta"
    warn "conexiones remotas hasta que se cambie bind-address."
    echo
    echo "  Ejecutar:"
    echo "    sudo sed -i 's/^bind-address.*=.*/bind-address = 0.0.0.0/' \\"
    echo "        /etc/mysql/mariadb.conf.d/50-server.cnf"
    echo "    sudo systemctl restart mariadb"
else
    echo
    ok "bind-address = $BIND_ADDR — acepta conexiones remotas."
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}=== Pasos siguientes ===${RESET}"
echo
echo "  1. Repetir este script en la OTRA máquina de la red."
echo "  2. Desde esta máquina, verificar:"
echo "     python scripts/pruebas/prueba_conectividad.py"
echo "  3. Si el backend Flask está corriendo:"
echo "     curl http://localhost:5000/api/diagnostico"
echo
ok "Script completado en BD '${BD_LOCAL}'."
