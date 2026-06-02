#!/bin/sh

# === 默认环境变量设置 ===
TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL:-vless}     # 默认协议为 vless，可选 shadowsocks, trojan
TUNNEL_CIPHER=${TUNNEL_CIPHER:-256-gcm}       # 仅在 shadowsocks 协议时有效 (如 256-gcm, chacha20-ietf-poly1305)
TUNNEL_NETWORK=${TUNNEL_NETWORK:-tcp}         # 传输协议，如 tcp, ws, grpc
WEB_PORT=${PORT:-80}                          # 伪装网页端口

# === 根据选择的协议，动态生成 Xray 出站（Outbound） JSON 块 ===
if [ "$TUNNEL_PROTOCOL" = "shadowsocks" ] || [ "$TUNNEL_PROTOCOL" = "ss" ]; then
  # 1. Shadowsocks 出站配置
  OUTBOUND_JSON='{
    "tag": "outbound-to-gcp",
    "protocol": "shadowsocks",
    "settings": {
      "servers": [
        {
          "address": "'"${GCP_IP}"'",
          "port": '"${GCP_PORT}"',
          "password": "'"${TUNNEL_KEY}"'",
          "method": "'"${TUNNEL_CIPHER}"'"
        }
      ]
    },
    "streamSettings": {
      "network": "'"${TUNNEL_NETWORK}"'"
    }
  }'
elif [ "$TUNNEL_PROTOCOL" = "trojan" ]; then
  # 2. Trojan 出站配置
  OUTBOUND_JSON='{
    "tag": "outbound-to-gcp",
    "protocol": "trojan",
    "settings": {
      "servers": [
        {
          "address": "'"${GCP_IP}"'",
          "port": '"${GCP_PORT}"',
          "password": "'"${TUNNEL_KEY}"'"
        }
      ]
    },
    "streamSettings": {
      "network": "'"${TUNNEL_NETWORK}"'"
    }
  }'
else
  # 3. 默认：VLESS 出站配置
  OUTBOUND_JSON='{
    "tag": "outbound-to-gcp",
    "protocol": "vless",
    "settings": {
      "vnext": [
        {
          "address": "'"${GCP_IP}"'",
          "port": '"${GCP_PORT}"',
          "users": [
            {
              "id": "'"${TUNNEL_KEY}"'",
              "encryption": "none"
            }
          ]
        }
      ]
    },
    "streamSettings": {
      "network": "'"${TUNNEL_NETWORK}"'"
    }
  }'
fi

# === 创建 Xray 配置目录 ===
mkdir -p /etc/xray

# === 动态拼接完整的 config.json ===
cat <<EOF > /etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "reverse": {
    "privates": [
      {
        "tag": "private-portal",
        "domain": "reverse.tunnel",
        "shuttle": "outbound-to-gcp"
      }
    ]
  },
  "outbounds": [
    ${OUTBOUND_JSON},
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "private-portal"
        ],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

# === 启动伪装静态网页服务 ===
mkdir -p /www
cp /etc/xray/index.html /www/index.html
busybox httpd -p ${WEB_PORT} -h /www

echo "Camouflage Web Server started on port ${WEB_PORT}."
echo "Xray config generated successfully with protocol [${TUNNEL_PROTOCOL}]."

# === 启动 Xray 主程序 ===
exec /usr/bin/xray -config /etc/xray/config.json
