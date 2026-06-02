FROM node:alpine3.22

# 使用稳定的 /app 目录
WORKDIR /app

COPY index.js index.html package.json ./

EXPOSE 3000/tcp

# 安装系统依赖并下载 Xray-core（包括其 geoip.dat 和 geosite.dat 路由数据文件）
RUN apk update && apk upgrade && \
    apk add --no-cache openssl curl gcompat iproute2 coreutils bash unzip && \
    # 下载官方最新版 Xray-core
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && \
    unzip /tmp/xray.zip -d /tmp/xray-bin && \
    # 核心修正：不仅复制 xray 主程序，还要将同级目录下的数据文件一并复制到 /usr/bin/ 目录下
    mv /tmp/xray-bin/xray /usr/bin/xray && \
    mv /tmp/xray-bin/geoip.dat /usr/bin/geoip.dat && \
    mv /tmp/xray-bin/geosite.dat /usr/bin/geosite.dat && \
    rm -rf /tmp/xray.zip /tmp/xray-bin && \
    # 赋予执行权限
    chmod +x index.js /usr/bin/xray && \
    npm install

CMD ["node", "index.js"]
