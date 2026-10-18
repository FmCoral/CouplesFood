#!/bin/sh
# 全量备份：数据库 + schema + 图片，打包成一个 tar.gz，只保留最近 N 份
#
# 设计说明：本脚本「只做一次备份然后退出」，不做循环调度。
# 调度交给宿主机 cron（见 docker-compose.yml 的注释），原因：
#   ① postgres:16-alpine 是 busybox，`date -d 'tomorrow 03:00'` 不被支持，
#      在容器内做睡眠调度会算出负数并进入死循环；
#   ② 容器只跑单次任务，`docker compose run --rm backup` 才能干净地交互执行。
#
# 手动执行：
#   docker compose run --rm backup
set -eu

: "${PGHOST:=db}"
: "${PGUSER:=couple}"
: "${PGDATABASE:=couple}"
: "${BACKUP_KEEP:=3}"
: "${BACKUP_DIR_OVERRIDE:=/backup}"
: "${IMAGE_DIR:=/images}"

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="/tmp/backup-${STAMP}"
mkdir -p "$WORK"

log() { echo "[backup $(date '+%F %T')] $*"; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

log "开始备份 → $WORK"

# ---------- 1. 数据库（自定义格式，可选择性恢复） ----------
if pg_dump --no-owner --no-acl -Fc -f "$WORK/db.dump"; then
  log "数据库导出完成 $(du -h "$WORK/db.dump" | cut -f1)"
else
  log "数据库导出失败，终止本次备份"
  exit 1
fi

# ---------- 2. 纯文本 schema，便于肉眼比对 / 应急 ----------
pg_dump --no-owner --no-acl --schema-only -f "$WORK/schema.sql" || log "schema 导出失败（忽略）"

# ---------- 3. 图片 ----------
if [ -d "$IMAGE_DIR" ]; then
  tar -czf "$WORK/images.tar.gz" -C "$IMAGE_DIR" . 2>/dev/null || true
  log "图片打包完成 $(du -h "$WORK/images.tar.gz" 2>/dev/null | cut -f1)"
else
  log "图片目录不存在，跳过"
fi

# ---------- 4. 汇总 ----------
mkdir -p "$BACKUP_DIR_OVERRIDE"
PKG="${BACKUP_DIR_OVERRIDE}/couple-${STAMP}.tar.gz"
tar -czf "$PKG" -C "$WORK" .
chmod 600 "$PKG" 2>/dev/null || true
log "备份包生成：$PKG ($(du -h "$PKG" | cut -f1))"

# ---------- 5. 只保留最近 N 份 ----------
# 按修改时间倒序（不依赖文件名解析），删掉 N 之后的
count=0
for old in $(ls -1t "$BACKUP_DIR_OVERRIDE"/couple-*.tar.gz 2>/dev/null); do
  count=$((count + 1))
  if [ "$count" -gt "$BACKUP_KEEP" ]; then
    rm -f "$old" && log "清理旧备份：$(basename "$old")"
  fi
done

log "完成，当前保留 $BACKUP_KEEP 份以内："
ls -lh "$BACKUP_DIR_OVERRIDE"/couple-*.tar.gz 2>/dev/null | awk '{print "  " $9 "  " $5}' || true
