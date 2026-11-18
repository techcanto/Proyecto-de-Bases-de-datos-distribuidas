#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh — Arranca el backend Flask y abre el frontend en el navegador
# Uso: bash start.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/backend"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
LOG_FILE="$SCRIPT_DIR/backend.log"
PID_FILE="$SCRIPT_DIR/backend.pid"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Colores ────────────────────────────────────────────────────────────────────
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

info()    { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✘]${RESET} $*" >&2; }

# ── Verificar Python ───────────────────────────────────────────────────────────
# Búsqueda del intérprete (portable, sin rutas absolutas de nadie):
#   1. PYTHON_BIN del entorno (si el usuario lo define)
#   2. Venv dentro del proyecto: .venv/, venv/, env/, o cualquier carpeta con pyvenv.cfg
#   3. VENV_DIR (ruta explícita a un venv)
#   4. python3 del sistema
if [[ -z "${PYTHON_BIN:-}" ]]; then
  for candidato in "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/venv/bin/python3" "$SCRIPT_DIR/env/bin/python3"; do
    if [[ -x "$candidato" ]]; then PYTHON_BIN="$candidato"; break; fi
  done
fi
if [[ -z "${PYTHON_BIN:-}" ]]; then
  for cfg in "$SCRIPT_DIR"/*/pyvenv.cfg; do
    [[ -f "$cfg" ]] || continue
    candidato="$(dirname "$cfg")/bin/python3"
    if [[ -x "$candidato" ]]; then PYTHON_BIN="$candidato"; break; fi
  done
fi
if [[ -z "${PYTHON_BIN:-}" && -n "${VENV_DIR:-}" && -x "${VENV_DIR%/}/bin/python3" ]]; then
  PYTHON_BIN="${VENV_DIR%/}/bin/python3"
fi
if [[ -z "${PYTHON_BIN:-}" ]] && command -v python3 &>/dev/null; then
  PYTHON_BIN="$(command -v python3)"
fi
if [[ -z "${PYTHON_BIN:-}" ]] || ! "$PYTHON_BIN" --version &>/dev/null; then
  error "No se encontró python3. Instala Python 3.10+ o crea un venv en el proyecto."
  echo -e "  ${YELLOW}Alternativa:${RESET} VENV_DIR=/ruta/a/tu/venv bash start.sh"
  exit 1
fi
if ! "$PYTHON_BIN" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' &>/dev/null; then
  error "El intérprete '$PYTHON_BIN' no es Python 3.10+."
  exit 1
fi
info "Intérprete: $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

# ── Verificar que existe el archivo .env ──────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  error "No se encontró el archivo .env"
  echo ""
  echo -e "  ${YELLOW}Solución:${RESET} copia la plantilla y rellena tus valores:"
  echo -e "    cp .env.example .env"
  echo -e "    nano .env   # (o el editor que prefieras)"
  echo ""
  echo -e "  Necesitas configurar:"
  echo -e "    NODE0_HOST, NODE0_DB, NODE0_USER, NODE0_PASSWORD"
  echo -e "    NODE1_HOST, NODE1_DB, NODE1_USER, NODE1_PASSWORD"
  echo ""
  exit 1
fi

# ── Verificar que las dependencias estén instaladas ────────────────────────────
if ! "$PYTHON_BIN" -c "import flask, pymysql, flask_cors" &>/dev/null; then
  warn "Dependencias no encontradas. Instalando desde requirements.txt..."
  "$PYTHON_BIN" -m pip install -r "$BACKEND_DIR/requirements.txt" --quiet
fi

# ── Verificar que la configuración es válida antes de arrancar ────────────────
if ! "$PYTHON_BIN" -c "
import sys
sys.path.insert(0, '$BACKEND_DIR')
try:
    from config import NODES, LOCAL_NODE_INDEX
    if not NODES:
        print('ERROR: No hay nodos configurados en .env')
        sys.exit(1)
    print(f'Configuración OK: {len(NODES)} nodo(s), nodo local: {LOCAL_NODE_INDEX}')
except Exception as e:
    print(f'ERROR en config.py: {e}')
    sys.exit(1)
" 2>&1; then
  error "La configuración del backend tiene errores. Revisa tu archivo .env"
  exit 1
fi

# ── Matar instancia anterior si existe ────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    warn "Deteniendo instancia anterior del backend (PID $OLD_PID)..."
    kill "$OLD_PID"
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

# ── Arrancar backend en segundo plano ─────────────────────────────────────────
info "Iniciando backend Flask..."
cd "$BACKEND_DIR"
setsid bash -c "cd '$BACKEND_DIR' && exec "$PYTHON_BIN" app.py >> '$LOG_FILE' 2>&1" &
BACKEND_PID=$!
echo "$BACKEND_PID" > "$PID_FILE"

# ── Esperar a que el servidor esté listo (máx. 15 s) ─────────────────────────
info "Esperando que el backend esté listo..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:5000/api/nodo-info >/dev/null 2>&1; then
    info "Backend listo en http://localhost:5000 (PID $BACKEND_PID)"
    break
  fi
  # Si el proceso ya murió, mostrar el log inmediatamente
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    error "El backend terminó inesperadamente. Últimas líneas del log:"
    echo ""
    tail -20 "$LOG_FILE" >&2
    echo ""
    error "Revisa el log completo en: $LOG_FILE"
    exit 1
  fi
  if [[ $i -eq 30 ]]; then
    error "El backend no respondió en 15 segundos. Últimas líneas del log:"
    echo ""
    tail -20 "$LOG_FILE" >&2
    echo ""
    error "Revisa el log completo en: $LOG_FILE"
    exit 1
  fi
  sleep 0.5
done

# ── Abrir frontend en el navegador ────────────────────────────────────────────
FRONTEND_URL="http://localhost:5000"

if command -v xdg-open &>/dev/null; then
  info "Abriendo frontend en el navegador..."
  xdg-open "$FRONTEND_URL" >/dev/null 2>&1 &
elif command -v open &>/dev/null; then
  open "$FRONTEND_URL" >/dev/null 2>&1 &
else
  warn "No se pudo abrir el navegador automáticamente."
  warn "Abre manualmente: $FRONTEND_URL"
fi

echo ""
echo -e "  ${GREEN}Sistema corriendo${RESET}"
echo -e "  URL → ${YELLOW}http://localhost:5000${RESET}"
echo -e "  Logs    → ${YELLOW}$LOG_FILE${RESET}"
echo ""
echo -e "  Para detener: ${YELLOW}bash stop.sh${RESET}"
echo ""
