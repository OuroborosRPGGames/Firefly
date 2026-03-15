#!/usr/bin/env bash
# LanguageTool Docker container management
# Usage: scripts/languagetool.sh {start|stop|status|restart}

set -euo pipefail

CONTAINER_NAME="firefly-languagetool"
IMAGE="erikvl87/languagetool"
HOST_PORT="8742"
CONTAINER_PORT="8010"
NGRAM_PATH="${LT_NGRAM_PATH:-/opt/firefly/lt-ngrams}"

ensure_ngram_dir() {
  if [ ! -d "$NGRAM_PATH" ]; then
    echo "Creating n-gram directory: $NGRAM_PATH"
    mkdir -p "$NGRAM_PATH"
  fi
}

start() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "LanguageTool is already running."
    return 0
  fi

  docker rm "$CONTAINER_NAME" 2>/dev/null || true

  ensure_ngram_dir

  echo "Starting LanguageTool on 127.0.0.1:${HOST_PORT}..."
  docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
    -v "${NGRAM_PATH}:/ngrams" \
    -e languageModel=/ngrams \
    -e Java_Xms=512m \
    -e Java_Xmx=2g \
    "$IMAGE"

  echo "LanguageTool started. Waiting for health check..."
  for i in $(seq 1 30); do
    if curl -sf "http://127.0.0.1:${HOST_PORT}/v2/languages" > /dev/null 2>&1; then
      echo "LanguageTool is ready."
      return 0
    fi
    sleep 2
  done
  echo "Warning: LanguageTool did not become healthy within 60 seconds."
}

stop() {
  echo "Stopping LanguageTool..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  docker rm "$CONTAINER_NAME" 2>/dev/null || true
  echo "LanguageTool stopped."
}

status() {
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "LanguageTool is running."
    if curl -sf "http://127.0.0.1:${HOST_PORT}/v2/languages" > /dev/null 2>&1; then
      echo "Health check: OK"
    else
      echo "Health check: FAILED (container running but not responding)"
    fi
  else
    echo "LanguageTool is not running."
  fi
}

restart() {
  stop
  start
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  status)  status ;;
  restart) restart ;;
  *)
    echo "Usage: $0 {start|stop|status|restart}"
    exit 1
    ;;
esac
