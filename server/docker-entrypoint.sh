#!/bin/sh
set -e

# bind mount 的目录在宿主机上通常属于 root，容器内 node 用户写不了。
# 这里以 root 起步，只修这两个数据目录，然后降权。
IMG_DIR="${MEDIA_ROOT:-/data/images}"
BAK_DIR="${BACKUP_DIR:-/data/backup}"

mkdir -p "$IMG_DIR" "$BAK_DIR"
chown -R node:node "$IMG_DIR" "$BAK_DIR" 2>/dev/null || true

# 基础镜像里未必有 su-exec；有就降权，没有就以 root 运行。
# （容器本身已是隔离边界，这不影响功能；若要更严格可自行 apk add su-exec）
if command -v su-exec >/dev/null 2>&1; then
  exec su-exec node "$@"
fi
exec "$@"
