const express = require('express');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');

const app = express();
const port = 3000;

app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

app.get('/debug-logs', (req, res) => {
    const logPath = '/tmp/xray.log';
    res.header('Content-Type', 'text/plain; charset=utf-8');
    
    if (fs.existsSync(logPath)) {
        const logs = fs.readFileSync(logPath, 'utf8');
        res.send(logs || "empty");
    } else {
        res.send("not found");
    }
});

function generateXrayConfig() {
    try {
        const tunnelProtocol = process.env.TUNNEL_PROTOCOL || 'vless';
        const gcpIp = process.env.GCP_IP;
        const gcpPort = parseInt(process.env.GCP_PORT, 10);
        const tunnelKey = process.env.TUNNEL_KEY;
        const tunnelCipher = process.env.TUNNEL_CIPHER || 'aes-128-gcm'; 
        const tunnelNetwork = process.env.TUNNEL_NETWORK || 'tcp';
        const tunnelPath = process.env.TUNNEL_PATH || '/';
        const tunnelTag = process.env.TUNNEL_TAG || 'reverse-0';
        const tunnelDomain = process.env.TUNNEL_DOMAIN || 'reverse.xui';

        if (!gcpIp || !gcpPort || !tunnelKey) {
            fs.writeFileSync('/tmp/xray.log', "error: missing env\n");
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

        fs.mkdirSync('/tmp/xray-config', { recursive: true });
        fs.writeFileSync('/tmp/xray-config/config.json', JSON.stringify(config, null, 2));
        return true;
    } catch (e) {
        console.error("failed to generate config", e);
        return false;
    }
}

function startXray() {
    try {
        if (!generateXrayConfig()) return;
        exec('/usr/bin/xray -config /tmp/xray-config/config.json > /tmp/xray.log 2>&1');
    } catch (e) {
        console.error("failed to start xray", e);
    }
}

setInterval(() => {
    const logPath = '/tmp/xray.log';
    try {
        if (fs.existsSync(logPath)) {
            const stats = fs.statSync(logPath);
            const maxSizeBytes = 2 * 1024 * 1024;
            if (stats.size > maxSizeBytes) {
                fs.writeFileSync(logPath, "log truncated due to size limit\n");
            }
        }
    } catch (e) {
        console.error("failed to truncate log", e);
    }
}, 3600000);

app.listen(port, () => {
    startXray();
});
