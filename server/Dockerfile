# syntax=docker/dockerfile:1.7
# 构建上下文 = 仓库根目录（见 docker-compose.yml 的 context: ..），
# 这样才能 COPY 到 docs/schema.sql，保证建表脚本只有一份真相源。
# ---- 构建阶段：装全量依赖 + 编译 TS ----
FROM node:22-alpine AS build
WORKDIR /app
ENV npm_config_update_notifier=false

COPY server/package.json server/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY server/tsconfig.json ./
COPY server/src ./src
RUN npx tsc -p tsconfig.json

# 剥掉 devDependencies，只留运行时依赖
RUN npm prune --omit=dev --no-audit --no-fund

# ---- 运行阶段：只拷贝必要产物 ----
FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    TZ=Asia/Shanghai

# 运行阶段不装任何额外包：alpine 自带 wget 做健康检查，
# Node 自己处理 SIGTERM（main.ts 里有优雅退出逻辑），无需 tini

COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json
COPY server/scripts ./scripts
# schema.sql 是建表的唯一真相源，必须进镜像（migrate.ts 启动时执行它）
COPY docs/schema.sql ./schema.sql

RUN mkdir -p /data/images /data/backup \
    && chown -R node:node /app /data

# 注意：宿主机的 /data/couple/images 与 /data/couple/backup 是 bind mount，
# 镜像里的 chown 不生效。所以镜像以 root 启动，由 entrypoint 把两个目录
# chown 给 node 后再降权运行，否则上传图片会 EACCES。
COPY server/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER root
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["node", "--enable-source-maps", "dist/main.js"]
