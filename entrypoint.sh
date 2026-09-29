#!/bin/sh

set -eu

XRAY_BIN="/usr/local/bin/simpweb"
CONFIG_DIR="/etc/web"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "${CONFIG_DIR}"

echo "======================================================"
echo "        Xray VLESS Multi-Protocol Node"
echo "======================================================"

# ======================================================
# 1. 基础配置
# ======================================================

# 协议类型：
#
# tcp-reality
# xhttp-tls
# grpc-tls
# all
#
# Railway 建议每个 Service 单独运行一种协议。
# Koyeb / VPS 可以使用 all。
PROTOCOL_TYPE="${PROTOCOL_TYPE:-tcp-reality}"

# Railway / Koyeb 通常会注入 PORT
BASE_PORT="${PORT:-8443}"

TCP_PORT="${VLESS_TCP_PORT:-${BASE_PORT}}"
XHTTP_PORT="${VLESS_XHTTP_PORT:-$((BASE_PORT + 1))}"
GRPC_PORT="${VLESS_GRPC_PORT:-$((BASE_PORT + 2))}"

# ======================================================
# 2. Token
# ======================================================

# 不把 Token 写进代码。
# 可以通过 TOKEN / PLATFORM_TOKEN / RAILWAY_API_TOKEN /
# KOYEB_API_TOKEN 注入。
#
# 当前代码不会把 Token 打印出来。
TOKEN="${TOKEN:-${PLATFORM_TOKEN:-}}"

if [ -n "${TOKEN}" ]; then
    echo "Platform token: detected"
else
    echo "Platform token: not set"
fi

# ======================================================
# 3. UUID
# ======================================================

if [ -n "${UUID:-}" ]; then
    NODE_UUID="${UUID}"
else
    NODE_UUID="$("${XRAY_BIN}" uuid | head -n 1 | tr -d '\r\n ')"
fi

if [ -z "${NODE_UUID}" ]; then
    echo "ERROR: UUID generation failed."
    exit 1
fi

# ======================================================
# 4. Reality Key
# ======================================================

SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 4 | tr -d '\r\n ')}"

REALITY_KEYS="$("${XRAY_BIN}" x25519 2>&1)"

PRIVATE_KEY="$(
    printf '%s\n' "${REALITY_KEYS}" |
    awk -F ': ' 'tolower($0) ~ /private key/ {print $2; exit}' |
    tr -d '\r\n '
)"

PUBLIC_KEY="$(
    printf '%s\n' "${REALITY_KEYS}" |
    awk -F ': ' 'tolower($0) ~ /public key|password/ {print $2; exit}' |
    tr -d '\r\n '
)"

if [ -z "${PRIVATE_KEY}" ] || [ -z "${PUBLIC_KEY}" ]; then
    echo "ERROR: Reality key generation failed."
    echo "${REALITY_KEYS}"
    exit 1
fi

# ======================================================
# 5. Reality
# ======================================================

# 按你的要求：
# Reality 伪装 / SNI = Apple 官方网站
REALITY_SNI="${REALITY_SNI:-www.apple.com}"

# Reality target
REALITY_TARGET="${REALITY_TARGET:-${REALITY_SNI}:443}"

# ======================================================
# 6. TLS
# ======================================================

# 按你的要求：
# TLS SNI = Microsoft 官方网站
TLS_SNI="${TLS_SNI:-www.microsoft.com}"

TLS_CERT_FILE="${TLS_CERT_FILE:-${CONFIG_DIR}/server.crt}"
TLS_KEY_FILE="${TLS_KEY_FILE:-${CONFIG_DIR}/server.key}"

# ======================================================
# 7. XHTTP
# ======================================================

XHTTP_PATH="${XHTTP_PATH:-}"

if [ -z "${XHTTP_PATH}" ]; then
    XHTTP_PATH="$(
        tr -dc 'a-zA-Z0-9' < /dev/urandom |
        head -c 12 |
        tr -d '\r\n ' || true
    )"
fi

XHTTP_PATH="${XHTTP_PATH:-xraypath123}"

# 保证 path 以 / 开头
case "${XHTTP_PATH}" in
    /*)
        ;;
    *)
        XHTTP_PATH="/${XHTTP_PATH}"
        ;;
esac

# ======================================================
# 8. gRPC
# ======================================================

GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-}"

if [ -z "${GRPC_SERVICE_NAME}" ]; then
    GRPC_SERVICE_NAME="$(
        tr -dc 'a-zA-Z0-9' < /dev/urandom |
        head -c 10 |
        tr -d '\r\n ' || true
    )"
fi

GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-grpcservice}"

# ======================================================
# 9. TLS Certificate
# ======================================================

if [ -n "${TLS_CERT:-}" ] && [ -n "${TLS_KEY:-}" ]; then

    echo "${TLS_CERT}" > "${TLS_CERT_FILE}"
    echo "${TLS_KEY}" > "${TLS_KEY_FILE}"

    echo "Using TLS certificate from environment."

else

    if [ ! -f "${TLS_CERT_FILE}" ] || [ ! -f "${TLS_KEY_FILE}" ]; then

        echo "TLS certificate not found."
        echo "Generating temporary self-signed certificate..."

        openssl req \
            -x509 \
            -nodes \
            -days 3650 \
            -newkey rsa:2048 \
            -keyout "${TLS_KEY_FILE}" \
            -out "${TLS_CERT_FILE}" \
            -subj "/CN=${TLS_SNI}" \
            2>/dev/null

    fi

fi

# ======================================================
# 10. Public Host
# ======================================================

PUBLIC_HOST="${PUBLIC_HOST:-}"

if [ -z "${PUBLIC_HOST}" ]; then

    if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ]; then
        PUBLIC_HOST="${RAILWAY_TCP_PROXY_DOMAIN}"

    elif [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
        PUBLIC_HOST="${RAILWAY_PUBLIC_DOMAIN}"

    elif [ -n "${KOYEB_PUBLIC_DOMAIN:-}" ]; then
        PUBLIC_HOST="${KOYEB_PUBLIC_DOMAIN}"

    fi

fi

PUBLIC_HOST="${PUBLIC_HOST:-YOUR_PUBLIC_HOST}"

# ======================================================
# 11. Public Ports
# ======================================================

TCP_PUBLIC_PORT="${VLESS_TCP_PUBLIC_PORT:-}"

XHTTP_PUBLIC_PORT="${VLESS_XHTTP_PUBLIC_PORT:-}"

GRPC_PUBLIC_PORT="${VLESS_GRPC_PUBLIC_PORT:-}"

# Railway 自带的 TCP Proxy
if [ -z "${TCP_PUBLIC_PORT}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ]; then
    TCP_PUBLIC_PORT="${RAILWAY_TCP_PROXY_PORT}"
fi

# ======================================================
# 12. Config Helpers
# ======================================================

write_tcp_reality() {

cat >> "${CONFIG_FILE}" <<EOF
    {
      "tag": "vless-tcp-reality",
      "listen": "0.0.0.0",
      "port": ${TCP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${NODE_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
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
    }
EOF

}

write_xhttp_tls() {

cat >> "${CONFIG_FILE}" <<EOF
    {
      "tag": "vless-xhttp-tls",
      "listen": "0.0.0.0",
      "port": ${XHTTP_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${NODE_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${TLS_CERT_FILE}",
              "keyFile": "${TLS_KEY_FILE}"
            }
          ],
          "alpn": [
            "h2",
            "http/1.1"
          ]
        },
        "xhttpSettings": {
          "mode": "auto",
          "path": "${XHTTP_PATH}"
        }
      }
    }
EOF

}

write_grpc_tls() {

cat >> "${CONFIG_FILE}" <<EOF
    {
      "tag": "vless-grpc-tls",
      "listen": "0.0.0.0",
      "port": ${GRPC_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${NODE_UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${TLS_CERT_FILE}",
              "keyFile": "${TLS_KEY_FILE}"
            }
          ],
          "alpn": [
            "h2"
          ]
        },
        "grpcSettings": {
          "serviceName": "${GRPC_SERVICE_NAME}"
        }
      }
    }
EOF

}

# ======================================================
# 13. Generate Xray Config
# ======================================================

cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "${LOG_LEVEL:-warning}"
  },
  "inbounds": [
EOF

case "${PROTOCOL_TYPE}" in

    tcp-reality)

        write_tcp_reality
        ;;

    xhttp-tls)

        write_xhttp_tls
        ;;

    grpc-tls)

        write_grpc_tls
        ;;

    all)

        write_tcp_reality
        printf ',\n' >> "${CONFIG_FILE}"

        write_xhttp_tls
        printf ',\n' >> "${CONFIG_FILE}"

        write_grpc_tls
        ;;

    *)

        echo "ERROR: Unsupported PROTOCOL_TYPE:"
        echo "${PROTOCOL_TYPE}"
        echo
        echo "Supported:"
        echo "  tcp-reality"
        echo "  xhttp-tls"
        echo "  grpc-tls"
        echo "  all"
        exit 1
        ;;

esac

cat >> "${CONFIG_FILE}" <<EOF
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

# ======================================================
# 14. Fix JSON commas for single inbound
# ======================================================

if [ "${PROTOCOL_TYPE}" != "all" ]; then
    # 单入口 JSON 已经合法，无需处理
    :
fi

# ======================================================
# 15. Validate config
# ======================================================

echo
echo "Checking Xray configuration..."

"${XRAY_BIN}" run -test -c "${CONFIG_FILE}"

echo
echo "Xray configuration OK."
echo

# ======================================================
# 16. Build VLESS links
# ======================================================

echo "======================================================"
echo "              VLESS NODE INFORMATION"
echo "======================================================"

echo
echo "Protocol:"
echo "${PROTOCOL_TYPE}"

echo
echo "UUID:"
echo "${NODE_UUID}"

echo
echo "VLESS Encryption:"
echo "none"

echo
echo "Reality SNI:"
echo "${REALITY_SNI}"

echo
echo "Reality Public Key:"
echo "${PUBLIC_KEY}"

echo
echo "Reality Short ID:"
echo "${SHORT_ID}"

echo
echo "TLS SNI:"
echo "${TLS_SNI}"

echo
echo "XHTTP Path:"
echo "${XHTTP_PATH}"

echo
echo "gRPC Service Name:"
echo "${GRPC_SERVICE_NAME}"

echo
echo "------------------------------------------------------"
echo

# ======================================================
# 17. TCP + Reality Link
# ======================================================

if [ "${PROTOCOL_TYPE}" = "tcp-reality" ] || [ "${PROTOCOL_TYPE}" = "all" ]; then

    TCP_LINK_PORT="${TCP_PUBLIC_PORT:-${TCP_PORT}}"
    TCP_LINK_HOST="${VLESS_TCP_PUBLIC_HOST:-${PUBLIC_HOST}}"

    TCP_LINK="vless://${NODE_UUID}@${TCP_LINK_HOST}:${TCP_LINK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&type=tcp&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#VLESS-TCP-Reality"

    echo "VLESS + TCP + Reality"
    echo
    echo "${TCP_LINK}"
    echo

fi

# ======================================================
# 18. XHTTP + TLS Link
# ======================================================

if [ "${PROTOCOL_TYPE}" = "xhttp-tls" ] || [ "${PROTOCOL_TYPE}" = "all" ]; then

    XHTTP_LINK_PORT="${XHTTP_PUBLIC_PORT:-${XHTTP_PORT}}"
    XHTTP_LINK_HOST="${VLESS_XHTTP_PUBLIC_HOST:-${PUBLIC_HOST}}"

    XHTTP_LINK="vless://${NODE_UUID}@${XHTTP_LINK_HOST}:${XHTTP_LINK_PORT}?encryption=none&security=tls&type=xhttp&path=$(printf '%s' "${XHTTP_PATH}" | sed 's#/#%2F#g')&sni=${TLS_SNI}&fp=chrome&allowInsecure=1#VLESS-XHTTP-TLS"

    echo "VLESS + XHTTP + TLS"
    echo
    echo "${XHTTP_LINK}"
    echo

fi

# ======================================================
# 19. gRPC + TLS Link
# ======================================================

if [ "${PROTOCOL_TYPE}" = "grpc-tls" ] || [ "${PROTOCOL_TYPE}" = "all" ]; then

    GRPC_LINK_PORT="${GRPC_PUBLIC_PORT:-${GRPC_PORT}}"
    GRPC_LINK_HOST="${VLESS_GRPC_PUBLIC_HOST:-${PUBLIC_HOST}}"

    GRPC_LINK="vless://${NODE_UUID}@${GRPC_LINK_HOST}:${GRPC_LINK_PORT}?encryption=none&security=tls&type=grpc&serviceName=${GRPC_SERVICE_NAME}&sni=${TLS_SNI}&fp=chrome&alpn=h2&allowInsecure=1#VLESS-gRPC-TLS"

    echo "VLESS + gRPC + TLS"
    echo
    echo "${GRPC_LINK}"
    echo

fi

echo "======================================================"
echo
echo "Xray binary:"
echo "${XRAY_BIN}"
echo
echo "Config:"
echo "${CONFIG_FILE}"
echo
echo "Starting Xray..."
echo

# ======================================================
# 20. Start
# ======================================================

exec "${XRAY_BIN}" run -c "${CONFIG_FILE}"
