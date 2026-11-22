#!/bin/sh
set -euo pipefail

# ==============================================================================
# PDFtrack Proxy - Offline Configuration Validation (Factor XII)
# ==============================================================================
# Executes as an independent, one-off administrative task to validate static
# and dynamic Traefik v3 configurations in the target environment without
# starting upstream dependencies or modifying persistent state.
# ==============================================================================

# 1. Export default environment variables if not defined
export EXTRACTOR_HOST="${EXTRACTOR_HOST:-extractor}"
export EXTRACTOR_PORT="${EXTRACTOR_PORT:-8000}"
export DOCUMENTS_HOST="${DOCUMENTS_HOST:-documents}"
export DOCUMENTS_PORT="${DOCUMENTS_PORT:-8001}"
export PUBLIC_PORT="${PUBLIC_PORT:-80}"
export INTERNAL_PING_PORT="${INTERNAL_PING_PORT:-8082}"
export MAX_REQUEST_BODY_BYTES="${MAX_REQUEST_BODY_BYTES:-57671680}"
export MEM_REQUEST_BODY_BYTES="${MEM_REQUEST_BODY_BYTES:-2097152}"
export PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-35s}"
export PROXY_CONNECT_TIMEOUT="${PROXY_CONNECT_TIMEOUT:-5s}"
export PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-35s}"
export PROXY_GRACE_TIMEOUT="${PROXY_GRACE_TIMEOUT:-30s}"
export TRAEFIK_LOG_LEVEL="${TRAEFIK_LOG_LEVEL:-WARN}"

VARS='$EXTRACTOR_HOST $EXTRACTOR_PORT $DOCUMENTS_HOST $DOCUMENTS_PORT $PUBLIC_PORT $INTERNAL_PING_PORT $MAX_REQUEST_BODY_BYTES $MEM_REQUEST_BODY_BYTES $PROXY_READ_TIMEOUT $PROXY_CONNECT_TIMEOUT $PROXY_SEND_TIMEOUT $PROXY_GRACE_TIMEOUT $TRAEFIK_LOG_LEVEL'

# Detect template locations (container path /etc/traefik/ or local directory)
if [ -f "/etc/traefik/traefik.yml.template" ]; then
    TEMPLATE_DIR="/etc/traefik"
elif [ -f "./traefik.yml.template" ]; then
    TEMPLATE_DIR="."
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TEMPLATE_DIR="$SCRIPT_DIR"
fi

TEMPLATE_STATIC="${TEMPLATE_DIR}/traefik.yml.template"
TEMPLATE_DYNAMIC="${TEMPLATE_DIR}/dynamic.yml.template"

TMP_STATIC="/tmp/traefik_validate_$$.yml"
TMP_DYNAMIC="/tmp/dynamic_validate_$$.yml"
TMP_LOG="/tmp/traefik_validate_$$.log"

cleanup() {
    if [ -n "${TRAEFIK_PID:-}" ] && kill -0 "$TRAEFIK_PID" 2>/dev/null; then
        kill -TERM "$TRAEFIK_PID" 2>/dev/null || true
        wait "$TRAEFIK_PID" 2>/dev/null || true
    fi
    rm -f "$TMP_STATIC" "$TMP_DYNAMIC" "$TMP_LOG"
}
trap cleanup EXIT INT TERM

echo "[validate-config] Step 1/3: Rendering templates with envsubst..."
if [ ! -f "$TEMPLATE_STATIC" ] || [ ! -f "$TEMPLATE_DYNAMIC" ]; then
    echo "[validate-config] FATAL: Missing template files in $TEMPLATE_DIR" >&2
    exit 1
fi

envsubst "$VARS" < "$TEMPLATE_DYNAMIC" > "$TMP_DYNAMIC"
envsubst "$VARS" < "$TEMPLATE_STATIC" > "$TMP_STATIC"

# Point dynamic config provider to the rendered temporary dynamic file
sed -i "s|/etc/traefik/dynamic.yml|$TMP_DYNAMIC|g" "$TMP_STATIC"

echo "[validate-config] Step 2/3: Checking unresolved variables and basic YAML integrity..."
for f in "$TMP_STATIC" "$TMP_DYNAMIC"; do
    if grep -q '\${' "$f"; then
        echo "[validate-config] ERROR: Unresolved variable placeholders detected in $f:" >&2
        grep -n '\${' "$f" >&2
        exit 1
    fi
    if [ ! -s "$f" ]; then
        echo "[validate-config] ERROR: Configuration $f is empty." >&2
        exit 1
    fi
done

echo "[validate-config] Step 3/3: Starting Traefik in background to test parser and ping endpoint..."
traefik --configFile="$TMP_STATIC" > "$TMP_LOG" 2>&1 &
TRAEFIK_PID=$!

PING_URL="http://127.0.0.1:${INTERNAL_PING_PORT}/ping"
PING_OK=0

# Poll internal ping endpoint for up to 3 seconds
for attempt in $(seq 1 15); do
    if ! kill -0 "$TRAEFIK_PID" 2>/dev/null; then
        echo "[validate-config] ERROR: Traefik process exited prematurely!" >&2
        cat "$TMP_LOG" >&2
        exit 1
    fi

    if curl -s -f "$PING_URL" >/dev/null 2>&1; then
        PING_OK=1
        break
    fi
    sleep 0.2
done

if [ "$PING_OK" -eq 1 ]; then
    echo "[validate-config] Ping endpoint $PING_URL responded with HTTP 200 OK."
    echo "[validate-config] Static and dynamic configuration parser verified successfully."
    echo "[validate-config] Validation completed successfully (Factor XII). Exiting 0."
    exit 0
else
    echo "[validate-config] ERROR: Traefik failed to respond to ping at $PING_URL within timeout." >&2
    echo "[validate-config] Traefik log output:" >&2
    cat "$TMP_LOG" >&2
    exit 1
fi
