#!/bin/sh
set -eu

XRAY_BIN="/usr/local/bin/simpweb"
CONFIG_DIR="/etc/web"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CADDYFILE="/etc/caddy/Caddyfile"
RAILWAY_API_URL="https://backboard.railway.com/graphql/v2"

mkdir -p "${CONFIG_DIR}" /etc/caddy

# -----------------------------
# Runtime ports
# -----------------------------
WEB_PORT="${PORT:-8080}"
REALITY_PORT="${REALITY_PORT:-${RAILWAY_TCP_APPLICATION_PORT:-2053}}"
XHTTP_PORT="${XHTTP_BACKEND_PORT:-10001}"
GRPC_PORT="${GRPC_BACKEND_PORT:-10002}"

# Exactly 8 alphanumeric characters for TLS/XHTTP path.
TLS_PATH="${TLS_PATH:-}"
if [ -z "${TLS_PATH}" ]; then
    TLS_PATH="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || true)"
fi
TLS_PATH="${TLS_PATH:-a1B2c3D4}"

REALITY_SNI="${REALITY_SNI:-www.apple.com}"
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SNI}:443}"

# Railway terminates public TLS on its HTTPS domain.
# The upstream Xray listeners therefore use security=none.
TLS_SNI="${TLS_SNI:-}"

UUID="${UUID:-}"
if [ -z "${UUID}" ]; then
    UUID="$("${XRAY_BIN}" uuid | head -n 1 | tr -d '\r\n ')"
fi

SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 4 | tr -d '\r\n ')}"

REALITY_KEYS="$("${XRAY_BIN}" x25519 2>&1)"
PRIVATE_KEY="$(printf '%s\n' "${REALITY_KEYS}" |
    awk -F ': ' 'tolower($1) == "privatekey" || tolower($1) == "private key" {print $2; exit}' |
    tr -d '\r\n ')"

if [ -z "${PRIVATE_KEY}" ]; then
    echo "ERROR: failed to parse Reality private key."
    exit 1
fi

PUBLIC_KEY_OUTPUT="$("${XRAY_BIN}" x25519 -i "${PRIVATE_KEY}" 2>&1)"
PUBLIC_KEY="$(printf '%s\n' "${PUBLIC_KEY_OUTPUT}" |
    awk -F ': ' 'tolower($1) == "password" || tolower($1) == "public key" {print $2; exit}' |
    tr -d '\r\n ')"

if [ -z "${PUBLIC_KEY}" ]; then
    echo "ERROR: failed to derive Reality public key."
    exit 1
fi

# -----------------------------
# Railway API helpers
# -----------------------------
railway_post() {
    QUERY="$1"
    VARIABLES="$2"

    PAYLOAD="$(jq -cn         --arg query "${QUERY}"         --argjson variables "${VARIABLES}"         '{query:$query,variables:$variables}')"

    RESPONSE="$(curl -fsS --retry 3 --retry-delay 2         -H "Authorization: Bearer ${RAILWAY_API_TOKEN}"         -H "Content-Type: application/json"         --data "${PAYLOAD}"         "${RAILWAY_API_URL}")"

    if ! printf '%s' "${RESPONSE}" | jq -e '(.errors // []) | length == 0' >/dev/null; then
        echo "ERROR: Railway API request failed:" >&2
        printf '%s\n' "${RESPONSE}" | jq -c '.errors // .'
        return 1
    fi

    printf '%s' "${RESPONSE}"
}

bootstrap_railway() {
    if [ -z "${RAILWAY_API_TOKEN:-}" ]; then
        echo "ERROR: RAILWAY_API_TOKEN is required on Railway."
        echo "Add it under Railway -> Service -> Variables, then redeploy."
        exit 1
    fi

    PROJECT_ID="${RAILWAY_PROJECT_ID:?RAILWAY_PROJECT_ID is missing}"
    ENVIRONMENT_ID="${RAILWAY_ENVIRONMENT_ID:?RAILWAY_ENVIRONMENT_ID is missing}"
    SERVICE_ID="${RAILWAY_SERVICE_ID:?RAILWAY_SERVICE_ID is missing}"

    echo "Configuring Railway networking through the Public API..."

    DOMAINS_QUERY='query($projectId:String!,$environmentId:String!,$serviceId:String!){domains(projectId:$projectId,environmentId:$environmentId,serviceId:$serviceId){serviceDomains{id domain targetPort}}}'
    DOMAIN_VARS="$(jq -cn         --arg projectId "${PROJECT_ID}"         --arg environmentId "${ENVIRONMENT_ID}"         --arg serviceId "${SERVICE_ID}"         '{projectId:$projectId,environmentId:$environmentId,serviceId:$serviceId}')"

    DOMAIN_RESPONSE="$(railway_post "${DOMAINS_QUERY}" "${DOMAIN_VARS}")"
    SERVICE_DOMAIN="$(printf '%s' "${DOMAIN_RESPONSE}" | jq -r '.data.domains.serviceDomains[0].domain // empty')"
    SERVICE_DOMAIN_ID="$(printf '%s' "${DOMAIN_RESPONSE}" | jq -r '.data.domains.serviceDomains[0].id // empty')"
    DOMAIN_TARGET_PORT="$(printf '%s' "${DOMAIN_RESPONSE}" | jq -r '.data.domains.serviceDomains[0].targetPort // empty')"

    if [ -z "${SERVICE_DOMAIN}" ]; then
    if [ -z "${SERVICE_DOMAIN}" ]; then
        CREATE_DOMAIN='mutation($serviceId:String!,$environmentId:String!){serviceDomainCreate(serviceId:$serviceId,environmentId:$environmentId){id domain}}'
        CREATE_DOMAIN_VARS="$(jq -cn \
            --arg serviceId "${SERVICE_ID}" \
            --arg environmentId "${ENVIRONMENT_ID}" \
            '{serviceId:$serviceId,environmentId:$environmentId}')"

        CREATE_DOMAIN_RESPONSE="$(railway_post "${CREATE_DOMAIN}" "${CREATE_DOMAIN_VARS}")"
        SERVICE_DOMAIN="$(printf '%s' "${CREATE_DOMAIN_RESPONSE}" | jq -r '.data.serviceDomainCreate.domain // empty')"
        SERVICE_DOMAIN_ID="$(printf '%s' "${CREATE_DOMAIN_RESPONSE}" | jq -r '.data.serviceDomainCreate.id // empty')"

        if [ -z "${SERVICE_DOMAIN}" ]; then
            echo "ERROR: Railway Service Domain was not created." >&2
            printf '%s\n' "${CREATE_DOMAIN_RESPONSE}" | jq -c '.errors // .'
            exit 1
        fi

        echo "Created Railway service domain: ${SERVICE_DOMAIN}"
    fi

    # Railway maps the Service Domain to the service's detected PORT.
    # No serviceDomainUpdate is required.
    TCP_QUERY='query($environmentId:String!,$serviceId:String!){tcpProxies(environmentId:$environmentId,serviceId:$serviceId){id domain proxyPort applicationPort}}'
    TCP_VARS="$(jq -cn         --arg environmentId "${ENVIRONMENT_ID}"         --arg serviceId "${SERVICE_ID}"         '{environmentId:$environmentId,serviceId:$serviceId}')"

    TCP_RESPONSE="$(railway_post "${TCP_QUERY}" "${TCP_VARS}")"

    TCP_PROXY_MATCH="$(printf '%s' "${TCP_RESPONSE}" |
        jq -c --argjson port "${REALITY_PORT}" '.data.tcpProxies[]? | select(.applicationPort == $port)' |
        head -n 1 || true)"

    if [ -z "${TCP_PROXY_MATCH}" ]; then
        TCP_COUNT="$(printf '%s' "${TCP_RESPONSE}" | jq '.data.tcpProxies | length')"

        if [ "${TCP_COUNT}" -gt 0 ]; then
            TCP_PROXY_MATCH="$(printf '%s' "${TCP_RESPONSE}" | jq -c '.data.tcpProxies[0]')"
            REALITY_PORT="$(printf '%s' "${TCP_PROXY_MATCH}" | jq -r '.applicationPort')"
            echo "Reusing existing Railway TCP Proxy on :${REALITY_PORT}."
        else

        CREATE_TCP='mutation($input:TCPProxyCreateInput!){tcpProxyCreate(input:$input){id domain proxyPort applicationPort}}'
        CREATE_TCP_VARS="$(jq -cn             --arg serviceId "${SERVICE_ID}"             --arg environmentId "${ENVIRONMENT_ID}"             --argjson applicationPort "${REALITY_PORT}"             '{input:{serviceId:$serviceId,environmentId:$environmentId,applicationPort:$applicationPort}}')"

        CREATE_TCP_RESPONSE="$(railway_post "${CREATE_TCP}" "${CREATE_TCP_VARS}")"
        TCP_PROXY_MATCH="$(printf '%s' "${CREATE_TCP_RESPONSE}" | jq -c '.data.tcpProxyCreate')"

        echo "Created Railway TCP Proxy for :${REALITY_PORT}."
    fi

    TCP_HOST="$(printf '%s' "${TCP_PROXY_MATCH}" | jq -r '.domain')"
    TCP_PUBLIC_PORT="$(printf '%s' "${TCP_PROXY_MATCH}" | jq -r '.proxyPort')"

    TLS_SNI="${TLS_SNI:-${SERVICE_DOMAIN}}"

    # The token is only needed for bootstrap; do not pass it to children.
    unset RAILWAY_API_TOKEN

    echo "Railway service domain: ${SERVICE_DOMAIN}:443"
    echo "Railway TCP proxy: ${TCP_HOST}:${TCP_PUBLIC_PORT}"
}

# -----------------------------
# Platform detection
# -----------------------------
SERVICE_DOMAIN=""
TCP_HOST=""
TCP_PUBLIC_PORT=""

if [ -n "${RAILWAY_SERVICE_ID:-}" ] && [ -n "${RAILWAY_ENVIRONMENT_ID:-}" ]; then
    bootstrap_railway
else
    SERVICE_DOMAIN="${PUBLIC_HOST:-YOUR_PUBLIC_HOST}"
    TLS_SNI="${TLS_SNI:-${SERVICE_DOMAIN}}"
    TCP_HOST="${VLESS_TCP_PUBLIC_HOST:-${SERVICE_DOMAIN}}"
    TCP_PUBLIC_PORT="${VLESS_TCP_PUBLIC_PORT:-${REALITY_PORT}}"
fi

# -----------------------------
# Xray config
# -----------------------------
cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}"
  },
  "inbounds": [
    {
      "tag": "vless-tcp-reality",
      "listen": "0.0.0.0",
      "port": ${REALITY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    },
    {
      "tag": "vless-xhttp-tls",
      "listen": "127.0.0.1",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/${TLS_PATH}"
        }
      }
    },
    {
      "tag": "vless-grpc-tls",
      "listen": "127.0.0.1",
      "port": ${GRPC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${TLS_PATH}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

# Validate generated Xray configuration before starting anything.
"${XRAY_BIN}" run -test -c "${CONFIG_FILE}"

# -----------------------------
# Caddy: public HTTPS edge target
# -----------------------------
# Railway terminates client TLS at its HTTPS edge and sends HTTP to PORT.
# Caddy routes the randomized XHTTP path and gRPC path to local Xray ports.
cat > "${CADDYFILE}" <<EOF
:${WEB_PORT} {
    @health path /health
    respond @health 200

    @grpc path /${TLS_PATH}/Tun*
    reverse_proxy @grpc h2c://127.0.0.1:${GRPC_PORT}

    @xhttp path /${TLS_PATH}*
    reverse_proxy @xhttp 127.0.0.1:${XHTTP_PORT}

    respond 404
}
EOF

if ! caddy validate --config "${CADDYFILE}" --adapter caddyfile >/dev/null; then
    echo "ERROR: Caddy configuration validation failed."
    exit 1
fi

# -----------------------------
# Output node information
# -----------------------------
echo
echo "======================================================"
echo "             VLESS NODE INFORMATION"
echo "======================================================"
echo
echo "UUID: ${UUID}"
echo
echo "VLESS encryption: none"
echo
echo "Reality SNI: ${REALITY_SNI}"
echo "Reality Public Key: ${PUBLIC_KEY}"
echo "Reality Short ID: ${SHORT_ID}"
echo
echo "TLS public SNI: ${TLS_SNI}"
echo "TLS random path: /${TLS_PATH}"
echo

REALITY_LINK="vless://${UUID}@${TCP_HOST}:${TCP_PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#VLESS-TCP-Reality"

XHTTP_LINK="vless://${UUID}@${SERVICE_DOMAIN}:443?encryption=none&security=tls&type=xhttp&path=%2F${TLS_PATH}&sni=${TLS_SNI}&fp=chrome#VLESS-XHTTP-TLS"

GRPC_LINK="vless://${UUID}@${SERVICE_DOMAIN}:443?encryption=none&security=tls&type=grpc&serviceName=${TLS_PATH}&sni=${TLS_SNI}&fp=chrome&alpn=h2#VLESS-gRPC-TLS"

echo "VLESS + TCP + Reality:"
echo
echo "${REALITY_LINK}"
echo

echo "VLESS + XHTTP + TLS:"
echo
echo "${XHTTP_LINK}"
echo

echo "VLESS + gRPC + TLS:"
echo
echo "${GRPC_LINK}"
echo

echo "======================================================"
echo "IMPORTANT:"
echo "Railway HTTPS :443 can serve XHTTP through the HTTP edge."
echo "Railway's HTTP edge converts incoming HTTP/2 to HTTP/1.1 upstream,"
echo "so Xray gRPC is not usable through the Railway HTTPS domain."
echo "The gRPC link is printed for Koyeb/VPS/direct TCP deployments."
echo "======================================================"
echo

# -----------------------------
# Start Xray + Caddy
# -----------------------------
"${XRAY_BIN}" run -c "${CONFIG_FILE}" &
XRAY_PID=$!

caddy run --config "${CADDYFILE}" --adapter caddyfile &
CADDY_PID=$!

cleanup() {
    kill "${XRAY_PID}" "${CADDY_PID}" 2>/dev/null || true
    wait "${XRAY_PID}" 2>/dev/null || true
    wait "${CADDY_PID}" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

while kill -0 "${XRAY_PID}" 2>/dev/null && kill -0 "${CADDY_PID}" 2>/dev/null; do
    sleep 2
done

if ! kill -0 "${XRAY_PID}" 2>/dev/null; then
    wait "${XRAY_PID}" || true
    exit 1
fi

if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
    wait "${CADDY_PID}" || true
    exit 1
fi

exit 1
