# excalidraw-room — 自建多架构镜像
#
# WHY: 官方 excalidraw/excalidraw-room 只发 amd64,oracle-k3s 是 arm64。upstream 本身
# 是纯 Node/Socket.IO(无原生依赖),用 buildx 多架构重构即可。由
# .github/workflows/excalidraw-room-image.yml 构建并推到 ghcr.io/meirongdev/excalidraw-room。
#
# 源码按 commit pin(见 ROOM_REF),tarball 拉取,确定性构建。upstream 已多年稳定。
ARG NODE_VERSION=20-alpine

FROM node:${NODE_VERSION} AS builder
# excalidraw/excalidraw-room @ master (2023-12-15) — bump 时同步改 workflow 的 tag。
ARG ROOM_REF=03ff435860b508d7cd9e005cfc90f7977ae2a593
WORKDIR /build
RUN apk add --no-cache curl
RUN curl -fsSL "https://codeload.github.com/excalidraw/excalidraw-room/tar.gz/${ROOM_REF}" \
      | tar xz --strip-components=1
RUN yarn install --frozen-lockfile
RUN yarn build
# 剪掉 dev 依赖(typescript 等),给运行时留精简 node_modules
RUN yarn install --frozen-lockfile --production && yarn cache clean

FROM node:${NODE_VERSION} AS runtime
ENV NODE_ENV=production \
    PORT=80
WORKDIR /excalidraw-room
COPY --from=builder /build/package.json /build/yarn.lock ./
COPY --from=builder /build/node_modules ./node_modules
COPY --from=builder /build/dist ./dist
EXPOSE 80
USER node
# upstream package.json: "start" = "node dist/index.js";根路径返回 "... is up :)"
CMD ["node", "dist/index.js"]
