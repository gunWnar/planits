#!/bin/sh

# 1. 动态获取环境端口 (适配 Railway / Koyeb / 纯 VPS)
if [ -n "$PORT" ]; then
    LISTEN_PORT=$PORT
else
    LISTEN_PORT=$(awk 'BEGIN{srand();print int(rand()*64536)+1000}')
fi

# 获取对外显示的域名和外网端口
if [ -n "$RAILWAY_TCP_PROXY_DOMAIN" ]; then
    CLIENT_IP="$RAILWAY_TCP_PROXY_DOMAIN"
    CLIENT_PORT="$RAILWAY_TCP_PROXY_PORT"
elif [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    CLIENT_IP="$RAILWAY_PUBLIC_DOMAIN"
    CLIENT_PORT="443"
elif [ -n "$KOYEB_PUBLIC_DOMAIN" ]; then
    CLIENT_IP="$KOYEB_PUBLIC_DOMAIN"
    CLIENT_PORT="443"
else
    CLIENT_IP="你的云平台域名或VPS公网IP"
    CLIENT_PORT=$LISTEN_PORT
fi

# 2. 获取节点协议类型 (默认设为 xhttp-reality)
PROTOCOL_TYPE=${PROTOCOL_TYPE:-"xhttp-reality"}
echo "======================================================"
echo "⚙️ 当前部署节点协议类型: $PROTOCOL_TYPE"
echo "======================================================"

# 3. 核心密钥提取 (使用最强健的正则和列提取，无视Xray格式暗改)
UUID=$(/usr/local/bin/web uuid | head -n 1 | tr -d '\r\n ')
SHORT_ID=$(openssl rand -hex 4 | tr -d '\r\n ')
PATH_STR=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8 | tr -d '\r\n ')

REALITY_KEYS=$(/usr/local/bin/web x25519 2>&1)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep -iE "Private" | head -n 1 | awk -F ':' '{print $2}' | tr -d '\r\n ')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep -iE "Public|Password" | head -n 1 | awk -F ':' '{print $2}' | tr -d '\r\n ')

VLESSENC=$(/usr/local/bin/web vlessenc 2>&1)
DECRYPTION=$(echo "$VLESSENC" | grep '"decryption"' | head -n 1 | awk -F '"' '{print $4}' | tr -d '\r\n ')
ENCRYPTION=$(echo "$VLESSENC" | grep '"encryption"' | head -n 1 | awk -F '"' '{print $4}' | tr -d '\r\n ')

# 4. 随机选择伪装域名
if [ "$PROTOCOL_TYPE" = "raw-tls" ]; then
    # TLS 模式按照要求使用游戏资讯网站
    DOMAINS="www.ign.com www.gamespot.com www.polygon.com"
    set -- $DOMAINS
    shift $(expr $(awk 'BEGIN{srand();print int(rand()*3)}') )
    SNI=$1
else
    # REALITY 模式使用常规大厂
    DOMAINS="www.bing.com www.yahoo.com"
    set -- $DOMAINS
    shift $(expr $(awk 'BEGIN{srand();print int(rand()*2)}') )
    SNI=$1
fi

# 5. 根据协议类型动态生成完整配置 (直接抛弃sed和jq，使用原生Heredoc)
if [ "$PROTOCOL_TYPE" = "xhttp-reality" ]; then
cat <<EOF > /etc/web/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-xhttp-reality",
    "listen": "0.0.0.0",
    "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "$DECRYPTION"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {"mode": "auto", "path": "/$PATH_STR"},
      "realitySettings": {
        "target": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom","tag": "direct"},{"protocol": "blackhole","tag": "block"}]
}
EOF
VLESS_LINK="vless://${UUID}@${CLIENT_IP}:${CLIENT_PORT}?type=xhttp&security=reality&encryption=${ENCRYPTION}&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&path=%2F${PATH_STR}&flow=xtls-rprx-vision#Xray-XHTTP-Reality"

elif [ "$PROTOCOL_TYPE" = "tcp-reality" ]; then
cat <<EOF > /etc/web/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-tcp-reality",
    "listen": "0.0.0.0",
    "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "$DECRYPTION"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "target": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE_KEY",
        "shortIds": ["$SHORT_ID"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom","tag": "direct"},{"protocol": "blackhole","tag": "block"}]
}
EOF
VLESS_LINK="vless://${UUID}@${CLIENT_IP}:${CLIENT_PORT}?type=tcp&security=reality&encryption=${ENCRYPTION}&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&flow=xtls-rprx-vision#Xray-TCP-Reality"

elif [ "$PROTOCOL_TYPE" = "raw-tls" ]; then
# 为 RAW+TLS 模式自动生成 10 年自签名证书
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/web/server.key -out /etc/web/server.crt -subj "/CN=$SNI" 2>/dev/null
cat <<EOF > /etc/web/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-raw-tls",
    "listen": "0.0.0.0",
    "port": $LISTEN_PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "$DECRYPTION"
    },
    "streamSettings": {
      "network": "raw",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{"certificateFile": "/etc/web/server.crt", "keyFile": "/etc/web/server.key"}]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom","tag": "direct"},{"protocol": "blackhole","tag": "block"}]
}
EOF
# 注意: RAW+TLS 因为是自签证书，客户端必须设置 allowInsecure=1 (跳过证书验证)
VLESS_LINK="vless://${UUID}@${CLIENT_IP}:${CLIENT_PORT}?type=raw&security=tls&encryption=${ENCRYPTION}&fp=chrome&sni=${SNI}&allowInsecure=1&flow=xtls-rprx-vision#Xray-RAW-TLS"
fi

# 6. 打印输出
echo "🎯 节点初始化成功！"
echo "🔗 节点分享链接 (直接复制到最新版 v2rayN / Shadowrocket 导入):"
echo ""
echo "$VLESS_LINK"
echo ""
echo "⚠️ 注意：如果是部署在云平台且未自动识别域名，请手动将链接中的 IP 和 端口 替换为您自己的公网域名和映射端口。"
echo "======================================================"

# 7. 启动进程
exec /usr/local/bin/web run -c /etc/web/config.json
