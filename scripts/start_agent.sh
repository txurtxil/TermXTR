#!/bin/bash
# XTR Agent — start_agent.sh v14.13
# Arranca el agent-server autonomo (STDLIB PURO: no necesita pip ni red)
set -e

AGENT_PORT="${AGENT_PORT:-8765}"
export AGENT_PORT
export LLM_BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:8090/v1}"
export LLM_MODEL="${LLM_MODEL:-gemma3-local}"
export LLM_API_KEY="${LLM_API_KEY:-local}"
export AGENT_PID_FILE="${AGENT_PID_FILE:-/tmp/agent.pid}"
export AGENT_MAX_STEPS="${AGENT_MAX_STEPS:-15}"
export AGENT_GOAL_TIMEOUT="${AGENT_GOAL_TIMEOUT:-420}"

PY=/usr/bin/python3
[ -x /usr/local/bin/python3 ] && PY=/usr/local/bin/python3
echo "[XTR] Usando python: $PY"
echo "[XTR] LLM_BASE_URL=$LLM_BASE_URL"
echo "[XTR] Modelo=$LLM_MODEL"
echo "[XTR] Puerto=$AGENT_PORT"
echo "[XTR] v14.13: nmap bloqueado, imagenes falsas rechazadas, UA navegador (Groq)"

# Directorio de memoria persistente
mkdir -p /root/agent_memory/logs

# Si ya hay un agente corriendo, lo matamos
if [ -f "$AGENT_PID_FILE" ]; then
  OLD_PID=$(cat "$AGENT_PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "[XTR] Agente anterior (pid $OLD_PID) detectado, reiniciando..."
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
  fi
fi

echo "[XTR] Arrancando agent-server v14.13 en puerto $AGENT_PORT..."
nohup $PY /root/agent_server.py > /tmp/agent_server.log 2>&1 &
echo $! > "$AGENT_PID_FILE"

sleep 2
if kill -0 "$(cat $AGENT_PID_FILE)" 2>/dev/null; then
  echo "[XTR] Agente corriendo (pid $(cat $AGENT_PID_FILE)) — http://127.0.0.1:$AGENT_PORT"
  curl -s http://127.0.0.1:$AGENT_PORT/health 2>/dev/null || \
    wget -qO- http://127.0.0.1:$AGENT_PORT/health 2>/dev/null || true
  echo ""
else
  echo "[XTR] ERROR: el agente no arranco. Log:"
  tail -20 /tmp/agent_server.log
  exit 1
fi
