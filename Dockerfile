FROM alpine:latest

# 安装必要依赖并固定拉取 v26.3.27 稳定版
RUN apk add --no-cache tzdata openssl ca-certificates && \
    wget -O xray.zip https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-linux-64.zip && \
    unzip xray.zip -d /usr/local/bin/ && \
    mv /usr/local/bin/xray /usr/local/bin/web && \
    rm -f xray.zip /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat /usr/local/bin/LICENSE /usr/local/bin/README.md && \
    chmod +x /usr/local/bin/web

# 创建配置目录并拷贝入口脚本
RUN mkdir -p /etc/web
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
