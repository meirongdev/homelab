# squoosh — 自建镜像：把上游镜像里已构建好的静态产物换到干净的 nginx 壳里
#
# WHY（2026-08-05）：原先直接跑 dko0/squoosh:1.12.0，实测该镜像
#   - 上游 2022-07-20 后停更（Docker Hub 上只有 latest / 1.12.0 两个 tag，同一天推的）；
#   - 入口是 `serve --listen=8080 --config ./serve.json ./build`，即一个 **Node 16.16.0**
#     （2023-09 已 EOL）静态文件服务器，且经 squoosh.meirong.dev 公网可达；
#   - Trivy 报 15 条 Critical（占 oracle-k3s 全部 73 条的 21%），来源全是那套陈旧运行时：
#     nodejs 16 四条、zlib 1.2.12-r1(9.8)、busybox 1.35(9.8)、libssl/libcrypto 1.1.1q、
#     以及 ejs / shell-quote / loader-utils / minimist 等构建期残留依赖。
#
# 关键观察：squoosh 是**纯客户端** WASM 图片压缩器，Node 只用来发静态文件——
# 那 15 条 CVE 全在"发文件的壳"里，产物本身（build/，24.8MB）不含任何包管理元数据。
# 所以只取 build/ 换进 nginx:1.31-alpine（实测 libssl3/libcrypto3 3.5.7-r0）即可清零，
# 且公网上不再跑 EOL Node。上游 google/squoosh 已归档，不存在"等上游修"的选项。
#
# 由 .github/workflows/squoosh-image.yml 构建多架构（arm64 + amd64）推到
# ghcr.io/meirongdev/squoosh —— 同 images/excalidraw-room 的既有模式。

# 产物提取阶段。用 $BUILDPLATFORM 固定在构建机原生架构上跑：build/ 是平台无关的
# 静态文件，没必要为它走 QEMU 模拟。digest 固定保证确定性构建（该 tag 已停更，不会变）。
FROM --platform=$BUILDPLATFORM dko0/squoosh:1.12.0@sha256:582cceee7385a45c6d3d5d84459b6bc8adc2773c0b33fef5c623db5b0b76dfff AS assets

FROM nginx:1.31-alpine

# 只搬产物：build/ 里是 rollup 输出（index.html + c/ + 21 个 .wasm + sw.js 等），
# 无 package.json / node_modules → Trivy 在这层扫不出任何依赖。
COPY --from=assets /app/squoosh/build /usr/share/nginx/html
COPY squoosh.conf /etc/nginx/conf.d/default.conf

# 监听 8080 而非 nginx 默认的 80：沿用原镜像端口，Deployment/Service/HTTPRoute/探针
# 全部无需改动（见 squoosh.conf 里的 listen）。
EXPOSE 8080
