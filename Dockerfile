FROM caddy:2-alpine AS caddy

FROM alpine:latest

ARG XRAY_VERSION=26.3.27

RUN apk add --no-cache \
        ca-certificates \
        curl \
        jq \
        openssl \
        tzdata \
        unzip \
        wget \
    && wget -q -O /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-64.zip" \
    && unzip -q /tmp/xray.zip -d /usr/local/bin/ \
    && mv /usr/local/bin/xray /usr/local/bin/simpweb \
    && rm -f /tmp/xray.zip /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat /usr/local/bin/LICENSE /usr/local/bin/README.md \
    && chmod +x /usr/local/bin/simpweb

COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

RUN mkdir -p /etc/web /etc/caddy

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
