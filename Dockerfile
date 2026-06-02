FROM node:alpine3.22

WORKDIR /tmp

COPY index.js index.html package.json ./

EXPOSE 3000/tcp

# 安装基础系统依赖，并自动下载官方最新版 Xray-core
RUN apk update && apk upgrade && \
    apk add --no-cache openssl curl gcompat iproute2 coreutils bash unzip && \
    # 下载官方最新版 Xray-core 二进制文件并移动到 /usr/bin/xray
    curl -L -o /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip && \
    unzip /tmp/xray.zip -d /tmp/xray-bin && \
    mv /tmp/xray-bin/xray /usr/bin/xray && \
    rm -rf /tmp/xray.zip /tmp/xray-bin && \
    # 给启动入口和 Xray 赋予执行权限
    chmod +x index.js /usr/bin/xray && \
    # 安装 node 项目依赖
    npm install

CMD ["node", "index.js"]
