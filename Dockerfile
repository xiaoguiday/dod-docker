FROM --platform=$TARGETPLATFORM node:alpine3.22
ARG TARGETARCH
WORKDIR /app
COPY index.js index.html package.json ./
EXPOSE 3000/tcp
RUN apk update && apk upgrade && \
    apk add --no-cache openssl curl gcompat iproute2 coreutils bash unzip && \
    if [ "$TARGETARCH" = "arm64" ]; then \
        curl -L -o /app/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm64-v8a.zip; \
    else \
        curl -L -o /app/xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip; \
    fi && \
    unzip /app/xray.zip -d /app/xray-bin && \
    mv /app/xray-bin/xray /usr/bin/xray && \
    mv /app/xray-bin/geoip.dat /usr/bin/geoip.dat && \
    mv /app/xray-bin/geosite.dat /usr/bin/geosite.dat && \
    rm -rf /app/xray.zip /app/xray-bin && \
    chmod +x index.js /usr/bin/xray && \
    npm install
CMD ["node", "index.js"]
