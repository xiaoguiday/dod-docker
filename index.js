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

// 2. 秘密日志诊断页面（访问 https://您的网址/debug-logs 即可查看）
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

// 3. 动态生成 Xray 配置文件
function generateXrayConfig() {
    const gcpIp = process.env.GCP_IP;
    const gcpPort = parseInt(process.env.GCP_PORT, 10);
    const tunnelKey = process.env.TUNNEL_KEY;
    const tunnelCipher = process.env.TUNNEL_CIPHER || '2022-blake3-aes-128-gcm';

    if (!gcpIp || !gcpPort || !tunnelKey) {
        fs.writeFileSync('/app/xray.log', "【错误】缺少关键环境变量：GCP_IP, GCP_PORT 或 TUNNEL_KEY\n");
        return false;
    }

    const config = {
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
            {
                "tag": "outbound-to-gcp",
                "protocol": "shadowsocks",
                "settings": {
                    "servers": [
                        {
                            "address": gcpIp,
                            "port": gcpPort,
                            "password": tunnelKey,
                            "method": tunnelCipher
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp"
                }
            },
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
                    "inboundTag": ["private-portal"],
                    "outboundTag": "direct"
                }
            ]
        }
    };

    fs.mkdirSync('/app/xray-config', { recursive: true });
    fs.writeFileSync('/app/xray-config/config.json', JSON.stringify(config, null, 2));
    return true;
}

// 4. 启动 Xray 并将日志重定向到文件
function startXray() {
    if (!generateXrayConfig()) return;

    console.log("【系统】正在启动后台 Xray 通道...");
    
    // 将标准输出和错误输出全部重定向写入到 /app/xray.log
    exec('/usr/bin/xray -config /app/xray-config/config.json > /app/xray.log 2>&1');
}

// 5. 监听端口
app.listen(port, () => {
    console.log(`【系统】Camouflage Node Server 启动，监听端口: ${port}`);
    startXray();
});
