const express = require('express');
const path = require('path');
const fs = require('fs');
const { exec } = require('child_process');

const app = express();
const port = process.env.PORT || 3000;

// 1. 托管静态伪装网页（用于通过平台健康检查）
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'index.html'));
});

// 2. 纯粹生成 Shadowsocks 反向出站配置文件
function generateXrayConfig() {
    const gcpIp = process.env.GCP_IP;
    const gcpPort = parseInt(process.env.GCP_PORT, 10);
    const tunnelKey = process.env.TUNNEL_KEY;
    const tunnelCipher = process.env.TUNNEL_CIPHER || '2022-blake3-aes-128-gcm';

    if (!gcpIp || !gcpPort || !tunnelKey) {
        console.error("【错误】缺少关键环境变量：GCP_IP, GCP_PORT 或 TUNNEL_KEY");
        return false;
    }

    // 针对您的 SS 节点定制的最小化 Xray 配置
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

    fs.mkdirSync('/tmp/xray', { recursive: true });
    fs.writeFileSync('/tmp/xray/config.json', JSON.stringify(config, null, 2));
    console.log("【系统】Xray Shadowsocks 配置文件写入成功。");
    return true;
}

// 3. 在后台默默启动 Xray 并连接您的 GCP
function startXray() {
    if (!generateXrayConfig()) return;

    console.log("【系统】正在启动后台 Xray 通道...");
    const xrayProcess = exec('/usr/bin/xray -config /tmp/xray/config.json');

    xrayProcess.stdout.on('data', (data) => console.log(`[Xray] ${data.trim()}`));
    xrayProcess.stderr.on('data', (data) => console.error(`[Xray Error] ${data.trim()}`));
}

// 4. 运行 Express 响应平台检测，并拉起通道
app.listen(port, () => {
    console.log(`【系统】Camouflage Node Server 成功启动，端口: ${port}`);
    startXray();
});
