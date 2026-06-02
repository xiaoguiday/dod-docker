#!/bin/sh

# === 1. 默认环境变量配置 ===
TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL:-vless}     
TUNNEL_CIPHER=${TUNNEL_CIPHER:-256-gcm}       
TUNNEL_NETWORK=${TUNNEL_NETWORK:-tcp}         
WEB_PORT=${PORT:-443}                         

# === 2. 安全清理并创建双版本 Nginx 目录 ===
rm -f /etc/nginx/http.d/*
rm -f /etc/nginx/conf.d/*
mkdir -p /etc/nginx/http.d
mkdir -p /etc/nginx/conf.d
mkdir -p /run/nginx

# === 3. 自动生成自签名 SSL 证书 ===
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/server.key \
  -out /etc/nginx/ssl/server.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/OU=OrgUnit/CN=localhost"

# === 4. 生成双重兼容的 Nginx 配置文件 ===
NGINX_CONF="server {
    listen ${WEB_PORT} ssl;
    ssl_certificate /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}"

# 同时写入两个可能的配置目录，确保 100% 兼容
echo "$NGINX_CONF" > /etc/nginx/http.d/default.conf
echo "$NGINX_CONF" > /etc/nginx/conf.d/default.conf

# === 5. 测试 Nginx 配置并启动 ===
echo "Testing Nginx configuration..."
nginx -t

echo "Starting Nginx Web Server on port ${WEB_PORT}..."
nginx

# === 6. 动态生成出站（Outbound） JSON 配置 ===
if [ "$TUNNEL_PROTOCOL" = "shadowsocks" ] || [ "$TUNNEL_PROTOCOL" = "ss" ]; then
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

# === 7. 生成完整 config.json 配置文件 ===
mkdir -p /etc/xray

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

echo "Xray tunnel config generated successfully."
echo "Starting Xray core..."

# === 8. 启动 Xray 核心主程序 ===
exec /usr/bin/xray -config /etc/xray/config.json
