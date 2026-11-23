#!/bin/sh
set -euo pipefail

# ==============================================================================
# PDFtrack Proxy Entrypoint (PID 1)
# ==============================================================================
# 1. Export default environment variables if not defined (Twelve-Factor III)
# 2. Render static and dynamic configuration templates using envsubst
# 3. Validate absence of unresolved placeholders and non-empty files
# 4. Replace shell process with Traefik v3 via exec (PID 1, Factor IX)
# ==============================================================================

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

TEMPLATE_STATIC="/etc/traefik/traefik.yml.template"
TARGET_STATIC="/etc/traefik/traefik.yml"

TEMPLATE_DYNAMIC="/etc/traefik/dynamic.yml.template"
TARGET_DYNAMIC="/etc/traefik/dynamic.yml"

echo "[entrypoint] Rendering Traefik static configuration: $TARGET_STATIC"
if [ ! -f "$TEMPLATE_STATIC" ]; then
    echo "[entrypoint] FATAL: Missing static template: $TEMPLATE_STATIC" >&2
    exit 1
fi
envsubst < "$TEMPLATE_STATIC" > "$TARGET_STATIC"

echo "[entrypoint] Rendering Traefik dynamic configuration: $TARGET_DYNAMIC"
if [ ! -f "$TEMPLATE_DYNAMIC" ]; then
    echo "[entrypoint] FATAL: Missing dynamic template: $TEMPLATE_DYNAMIC" >&2
    exit 1
fi
envsubst < "$TEMPLATE_DYNAMIC" > "$TARGET_DYNAMIC"

# Validate that no unexpanded placeholders remain
for cfg in "$TARGET_STATIC" "$TARGET_DYNAMIC"; do
    if grep -q '\${' "$cfg"; then
        echo "[entrypoint] FATAL: Unresolved variable placeholders detected in $cfg:" >&2
        grep -n '\${' "$cfg" >&2
        exit 1
    fi
    if [ ! -s "$cfg" ]; then
        echo "[entrypoint] FATAL: Rendered configuration $cfg is empty." >&2
        exit 1
    fi
done

echo "[entrypoint] Configuration rendered successfully. Launching Traefik v3 (PID 1)..."
exec traefik --configFile="$TARGET_STATIC"
