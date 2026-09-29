# planits

单 Service 的 Xray VLESS 部署镜像。

## Railway

只需要在 Railway Service -> Variables 添加：

```env
RAILWAY_API_TOKEN=你的 Account API Token
```

Railway 会在运行时提供：

- `RAILWAY_PROJECT_ID`
- `RAILWAY_ENVIRONMENT_ID`
- `RAILWAY_SERVICE_ID`
- `RAILWAY_PUBLIC_DOMAIN`
- `RAILWAY_TCP_PROXY_DOMAIN`
- `RAILWAY_TCP_PROXY_PORT`

容器启动后会通过 Railway Public GraphQL API：

1. 自动创建或读取 Service Domain；
2. 确保 Service Domain 指向 Railway 注入的 `PORT`；
3. 自动创建或读取一个 TCP Proxy，并把它指向 Reality 内部端口（默认 `2053`）；
4. 在日志中输出节点信息。

Token 只应存放在 Railway Variables，不要提交到 GitHub。

## 节点结构

- VLESS + TCP + Reality
  - Reality SNI: `www.apple.com`
  - 公网地址：Railway 自动生成的 TCP Proxy 高位端口
- VLESS + XHTTP + TLS
  - 公网地址：Railway Service Domain:443
  - TLS 路径：启动时随机生成 8 位字母+数字
- VLESS + gRPC + TLS
  - 配置会生成并打印
  - Railway 公网 HTTP 代理目前不支持把 gRPC 的 HTTP/2 端到端转发给服务，因此该链接不适用于 Railway Service Domain:443。需要使用 TCP Proxy 或不经过 Railway HTTP Edge 的环境。

## 关键变量

```env
REALITY_PORT=2053
XHTTP_BACKEND_PORT=10001
GRPC_BACKEND_PORT=10002

REALITY_SNI=www.apple.com
REALITY_TARGET=www.apple.com:443

TLS_PATH=
TLS_SNI=
```

`TLS_PATH` 留空时自动生成严格 8 位的字母+数字路径。

Railway 的 HTTPS Service Domain 会负责公网 TLS，因此 Railway 模式下 TLS SNI 使用 Railway Service Domain，而不是 `www.microsoft.com`；直接在 Railway 443 上使用 `www.microsoft.com` 会与 Railway 的证书匹配机制冲突。
