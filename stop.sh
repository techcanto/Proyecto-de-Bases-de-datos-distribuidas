#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# stop.sh — Detiene el backend Flask
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/backend.pid"

GREEN="\033[0;32m"
RED="\033[0;31m"
RESET="\033[0m"

if [[ ! -f "$PID_FILE" ]]; then
  echo -e "${RED}[✘]${RESET} No se encontró backend.pid. El backend puede no estar corriendo."
  exit 0
fi

PID=$(cat "$PID_FILE")

if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  rm -f "$PID_FILE"
  echo -e "${GREEN}[✔]${RESET} Backend detenido (PID $PID)."
else
  echo -e "${RED}[✘]${RESET} El proceso $PID ya no existe."
  rm -f "$PID_FILE"
fi
