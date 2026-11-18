#!/usr/bin/env bash
# =============================================================================
# unirse_a_la_red.sh — Agregar una nueva sucursal a un nodo existente
#
# Uso (desde la raíz del proyecto, en un nodo YA existente):
#   bash scripts/unirse_a_la_red.sh
#
# Lo que hace este script:
#   1. Lee el .env actual para detectar cuántos nodos hay configurados.
#   2. Pide los datos del nuevo nodo (IP Tailscale, BD, usuario, contraseña).
#   3. Verifica conectividad TCP + autenticación MariaDB al nuevo nodo.
#   4. Verifica que las tablas Clientes y Direcciones existan en el nuevo nodo.
#   5. Verifica que el AUTO_INCREMENT sea el correcto para ese índice de nodo.
#   6. Agrega el nuevo nodo al .env (hace backup del .env anterior).
#   7. Reinicia el backend si está en ejecución.
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

ask() {
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
# Verificaciones previas
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Agregar nueva sucursal a la red — Nodo existente       ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""

[[ -f "$ENV_FILE" ]] || fatal "No se encontró el archivo .env en $ROOT_DIR. ¿Estás en el directorio correcto?"

# =============================================================================
# PASO 1 — Detectar cuántos nodos hay configurados actualmente
# =============================================================================
paso "1/4  Leyendo configuración actual"

CURRENT_NODES=0
while true; do
    HOST_VAL=$(grep -E "^NODE${CURRENT_NODES}_HOST=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d ' ' || true)
    [[ -n "$HOST_VAL" ]] || break
    CURRENT_NODES=$((CURRENT_NODES + 1))
done

NEW_INDEX=$CURRENT_NODES
info "Nodos actualmente configurados: ${CURRENT_NODES} (índices 0–$((CURRENT_NODES-1)))"
info "El nuevo nodo será el Nodo ${NEW_INDEX}"

EXPECTED_AI=$(( NEW_INDEX * 1500 + 1 ))
echo ""
echo "  El nuevo nodo debe tener AUTO_INCREMENT = ${EXPECTED_AI} en la tabla Clientes."
echo "  (Si no es correcto, el script lo advertirá pero no bloqueará la incorporación.)"
echo ""

# =============================================================================
# PASO 2 — Recopilar datos del nuevo nodo
# =============================================================================
paso "2/4  Datos del nuevo nodo (Nodo ${NEW_INDEX})"

echo ""
ask "IP Tailscale del nuevo nodo (ej: 100.x.x.x)" ""
while [[ -z "$REPLY" ]]; do
    warn "El HOST no puede estar vacío."
    ask "IP Tailscale del nuevo nodo" ""
done
NEW_HOST="$REPLY"

ask "Puerto MariaDB" "3306"
NEW_PORT="$REPLY"

ask "Nombre de la base de datos en ese nodo" ""
while [[ -z "$REPLY" ]]; do
    warn "El nombre de la BD no puede estar vacío."
    ask "Nombre de la base de datos en ese nodo" ""
done
NEW_DB="$REPLY"

ask "Usuario MariaDB de ese nodo" "app_user"
NEW_USER="$REPLY"

ask_secret "Contraseña para '$NEW_USER' en $NEW_HOST"
NEW_PASSWORD="$REPLY"

# =============================================================================
# PASO 3 — Verificar conectividad y estado del nuevo nodo
# =============================================================================
paso "3/4  Verificando conectividad con el nuevo nodo"

# Buscar python3 disponible
PYTHON_BIN=""
for candidato in "$ROOT_DIR/.venv/bin/python3" "$ROOT_DIR/venv/bin/python3" \
                 "$ROOT_DIR/env/bin/python3"; do
    [[ -x "$candidato" ]] && { PYTHON_BIN="$candidato"; break; }
done
[[ -z "$PYTHON_BIN" ]] && command -v python3 &>/dev/null && PYTHON_BIN="$(command -v python3)"

VERIFY_OK=true

if [[ -n "$PYTHON_BIN" ]]; then
    echo ""
    echo "  Probando conexión a ${NEW_HOST}:${NEW_PORT}..."

    VERIFY_RESULT=$("$PYTHON_BIN" - <<PYEOF 2>&1 || true
import sys, socket, time

host = "$NEW_HOST"
port = int("$NEW_PORT")
db   = "$NEW_DB"
user = "$NEW_USER"
password = "$NEW_PASSWORD"
expected_ai = $EXPECTED_AI

# TCP check
try:
    t0 = time.monotonic()
    with socket.create_connection((host, port), timeout=5):
        pass
    ms = round((time.monotonic() - t0) * 1000, 1)
    print(f"TCP_OK {ms}ms")
except Exception as e:
    print(f"TCP_FAIL {e}")
    sys.exit(0)

# Auth + schema check
try:
    import pymysql
    conn = pymysql.connect(
        host=host, port=port, user=user, password=password,
        database=db, connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )
    print("AUTH_OK")

    with conn.cursor() as cur:
        # Verificar tablas
        cur.execute("SHOW TABLES")
        tablas = [list(r.values())[0] for r in cur.fetchall()]
        for t in ["Clientes", "Direcciones"]:
            if t in tablas:
                print(f"TABLE_OK {t}")
            else:
                print(f"TABLE_MISSING {t}")

        # Verificar AUTO_INCREMENT
        cur.execute(
            "SELECT AUTO_INCREMENT FROM information_schema.TABLES "
            "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'Clientes'"
        )
        row = cur.fetchone()
        ai = row["AUTO_INCREMENT"] if row else None
        if ai is not None:
            if ai >= expected_ai and ai < expected_ai + 1500:
                print(f"AI_OK {ai}")
            else:
                print(f"AI_WARN {ai} expected_range={expected_ai}-{expected_ai+1499}")
        else:
            print("AI_UNKNOWN")

    conn.close()
except Exception as e:
    print(f"AUTH_FAIL {e}")
PYEOF
)

    TCP_OK=false
    AUTH_OK=false
    TABLES_OK=true
    AI_OK=true

    while IFS= read -r line; do
        case "$line" in
            TCP_OK*)
                TCP_OK=true
                info "Conexión TCP exitosa (${line#TCP_OK })"
                ;;
            TCP_FAIL*)
                error "No se pudo conectar por TCP a ${NEW_HOST}:${NEW_PORT}"
                echo "  Detalles: ${line#TCP_FAIL }"
                VERIFY_OK=false
                ;;
            AUTH_OK)
                AUTH_OK=true
                info "Autenticación MariaDB exitosa"
                ;;
            AUTH_FAIL*)
                error "Fallo de autenticación en ${NEW_HOST}"
                echo "  Detalles: ${line#AUTH_FAIL }"
                VERIFY_OK=false
                ;;
            TABLE_OK*)
                info "Tabla '${line#TABLE_OK }' encontrada"
                ;;
            TABLE_MISSING*)
                error "Tabla '${line#TABLE_MISSING }' no existe en el nodo nuevo"
                echo "  El nodo nuevo debe ejecutar: bash scripts/setup_nuevo_nodo.sh"
                TABLES_OK=false
                VERIFY_OK=false
                ;;
            AI_OK*)
                info "AUTO_INCREMENT correcto: ${line#AI_OK }"
                ;;
            AI_WARN*)
                warn "AUTO_INCREMENT inesperado: ${line#AI_WARN }"
                echo "  Esperado: ${EXPECTED_AI}–$((EXPECTED_AI+1499))"
                echo "  El nodo nuevo debe corregirlo:"
                echo "    ALTER TABLE Clientes AUTO_INCREMENT = ${EXPECTED_AI};"
                AI_OK=false
                ;;
            AI_UNKNOWN)
                warn "No se pudo leer AUTO_INCREMENT (la tabla podría estar vacía)"
                ;;
        esac
    done <<< "$VERIFY_RESULT"
else
    warn "python3 no disponible — omitiendo verificación de conectividad."
    warn "Asegúrate de que el nodo nuevo esté configurado correctamente."
fi

echo ""
if [[ "$VERIFY_OK" == false ]]; then
    error "Se encontraron problemas al verificar el nuevo nodo."
    ask "¿Deseas agregar el nodo de todas formas? (s/n)" "n"
    [[ "$REPLY" =~ ^[sS]$ ]] || fatal "Operación cancelada. Corrige los problemas y vuelve a ejecutar."
fi

# =============================================================================
# PASO 4 — Actualizar .env
# =============================================================================
paso "4/4  Actualizando .env"

# Backup del .env actual
BACKUP_FILE="${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "$ENV_FILE" "$BACKUP_FILE"
info "Backup del .env guardado en: $BACKUP_FILE"

# Agregar las variables del nuevo nodo al final del .env
{
    echo ""
    echo "# ── Nodo ${NEW_INDEX} — agregado el $(date '+%Y-%m-%d %H:%M') ─────────────────────"
    echo "NODE${NEW_INDEX}_HOST=${NEW_HOST}"
    echo "NODE${NEW_INDEX}_PORT=${NEW_PORT}"
    echo "NODE${NEW_INDEX}_DB=${NEW_DB}"
    echo "NODE${NEW_INDEX}_USER=${NEW_USER}"
    echo "NODE${NEW_INDEX}_PASSWORD=${NEW_PASSWORD}"
} >> "$ENV_FILE"

info "Nodo ${NEW_INDEX} agregado al .env"

# =============================================================================
# Reiniciar backend si está en ejecución
# =============================================================================
PID_FILE="$ROOT_DIR/backend.pid"
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        warn "El backend está en ejecución (PID $OLD_PID). Reiniciando..."
        bash "$ROOT_DIR/stop.sh" 2>/dev/null || true
        sleep 1
        bash "$ROOT_DIR/start.sh"
        info "Backend reiniciado con la nueva configuración."
    fi
fi

# =============================================================================
# RESUMEN
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   ✔  Nueva sucursal incorporada a la red                 ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Nodo ${NEW_INDEX} agregado:"
echo -e "    Host     : ${YELLOW}${NEW_HOST}${RESET}"
echo -e "    Base de datos: ${YELLOW}${NEW_DB}${RESET}"
echo -e "    Usuario  : ${YELLOW}${NEW_USER}${RESET}"
echo ""
echo -e "  ${BOLD}Recuerda:${RESET} todos los demás nodos de la red también deben"
echo "  ejecutar este script para que puedan ver y consultar la nueva sucursal."
echo ""
echo "  Reinicia el sistema si no se reinició automáticamente:"
echo -e "    ${CYAN}bash stop.sh && bash start.sh${RESET}"
echo ""
