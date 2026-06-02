const express = require('express');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');

const app = express();
const port = 3000;

// 1. 托管静态伪装网页
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// 2. 秘密日志诊断页面
app.get('/debug-logs', (req, res) => {
    const logPath = '/app/xray.log';
    res.header('Content-Type', 'text/plain; charset=utf-8');
    
    if (fs.existsSync(logPath)) {
        const logs = fs.readFileSync(logPath, 'utf8');
        res.send(logs || "【提示】日志文件存在，但目前没有任何内容输出。");
    } else {
        res.send("【提示】日志文件 /app/xray.log 还未生成，请稍等或确认容器是否已启动。");
    }
});

// 3. 动态生成支持多设备参数的 Bridge 配置
function generateXrayConfig() {
    const tunnelProtocol = process.env.TUNNEL_PROTOCOL || 'vless';
    const gcpIp = process.env.GCP_IP;
    const gcpPort = parseInt(process.env.GCP_PORT, 10);
    const tunnelKey = process.env.TUNNEL_KEY;
    const tunnelCipher = process.env.TUNNEL_CIPHER || 'aes-128-gcm'; 
    const tunnelNetwork = process.env.TUNNEL_NETWORK || 'tcp';
    const tunnelPath = process.env.TUNNEL_PATH || '/';

    // === 核心新增：多设备反代变量提取（提供默认值以确保向下兼容） ===
    const tunnelTag = process.env.TUNNEL_TAG || 'reverse-4';
    const tunnelDomain = process.env.TUNNEL_DOMAIN || 'reverse.xui4';

    if (!gcpIp || !gcpPort || !tunnelKey) {
        fs.writeFileSync('/app/xray.log', "【错误】缺少关键环境变量：GCP_IP, GCP_PORT 或 TUNNEL_KEY\n");
        return false;
    }

    let outboundSettings = {};
    let streamSettings = {
        "network": tunnelNetwork
    };

    if (tunnelNetwork === 'ws') {
        streamSettings.wsSettings = {
            "path": tunnelPath
        };
    } else if (tunnelNetwork === 'tcp') {
        streamSettings.tcpSettings = {
            "header": {
                "type": "none"
            }
        };
    }

    if (tunnelProtocol === 'shadowsocks' || tunnelProtocol === 'ss') {
        outboundSettings = {
            "servers": [
                {
                    "address": gcpIp,
                    "port": gcpPort,
                    "password": tunnelKey,
                    "method": tunnelCipher,
                    "uot": true 
                }
            ]
        };
    } else {
        // VLESS
        outboundSettings = {
            "vnext": [
                {
                    "address": gcpIp,
                    "port": gcpPort,
                    "users": [
                        {
                            "id": tunnelKey,
                            "encryption": "none"
                        }
                    ]
                }
            ]
        };
    }

    const config = {
        "log": {
            "loglevel": "info"
        },
        "inbounds": [
            {
                "tag": "api",
                "listen": "127.0.0.1",
                "port": 6666,
                "protocol": "dokodemo-door",
                "settings": {
                    "address": "127.0.0.1"
                }
            }
        ],
        "outbounds": [
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {
                    "domainStrategy": "UseIP"
                }
            },
            {
                "tag": "blocked",
                "protocol": "blackhole",
                "settings": {}
            },
            {
                "tag": "reverse-proxy", 
                "protocol": tunnelProtocol === 'ss' ? 'shadowsocks' : tunnelProtocol,
                "settings": outboundSettings,
                "streamSettings": streamSettings
            }
        ],
        "routing": {
            "domainStrategy": "AsIs",
            "rules": [
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "ip": [
                        "geoip:private"
                    ]
                },
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "protocol": [
                        "bittorrent"
                    ]
                },
                {
                    "type": "field",
                    "outboundTag": "reverse-proxy",
                    "inboundTag": [
                        tunnelTag
                    ],
                    "domain": [
                        "full:" + tunnelDomain
                    ]
                },
                {
                    "type": "field",
                    "outboundTag": "direct",
                    "inboundTag": [
                        tunnelTag
                    ]
                }
            ]
        },
        "reverse": {
            "bridges": [
                {
                    "tag": tunnelTag,
                    "domain": tunnelDomain
                }
            ]
        }
    };

    fs.mkdirSync('/app/xray-config', { recursive: true });
    fs.writeFileSync('/app/xray-config/config.json', JSON.stringify(config, null, 2));
    return true;
}

// 4. 启动 Xray
function startXray() {
    if (!generateXrayConfig()) return;

    console.log("【系统】正在启动后台 Xray 通道...");
    exec('/usr/bin/xray -config /app/xray-config/config.json > /app/xray.log 2>&1');
}

// 5. 运行 Node 服务
app.listen(port, () => {
    console.log(`【系统】Camouflage Node Server 启动，监听端口: ${port}`);
    startXray();
});
