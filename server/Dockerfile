# syntax=docker/dockerfile:1.7
# ---- 构建阶段：装全量依赖 + 编译 TS ----
FROM node:22-alpine AS build
WORKDIR /app
ENV npm_config_update_notifier=false

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p tsconfig.json

# 剥掉 devDependencies，只留运行时依赖
RUN npm prune --omit=dev --no-audit --no-fund

# ---- 运行阶段：只拷贝必要产物，镜像约 120MB ----
FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    TZ=Asia/Shanghai

# 运行阶段不装任何额外包：alpine 自带 wget 做健康检查，
# Node 自己处理 SIGTERM（main.ts 里有优雅退出逻辑），无需 tini

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json
COPY scripts ./scripts

RUN mkdir -p /data/images /data/backup \
    && chown -R node:node /app /data

# 注意：宿主机的 ./images 与 ./backup 是 bind mount，镜像里的 chown 不生效。
# 所以镜像以 root 启动，由 entrypoint 把两个目录 chown 给 node 后再降权运行，
# 否则上传图片会 EACCES（这是容器化部署最常见的坑之一）。
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER root
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "--enable-source-maps", "dist/main.js"]
