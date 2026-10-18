#!/bin/sh
# 全量备份：数据库 + 图片，打包成一个 tar.gz，只保留最近 N 份
# 由 docker compose 的 backup 服务每天 03:00 调用；也可手动执行：
#   docker compose exec backup /bin/sh /usr/local/bin/backup.sh
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

# ---------- 2. 纯文本 schema，便于肉眼比对/应急 ----------
pg_dump --no-owner --no-acl --schema-only -f "$WORK/schema.sql" || log "schema 导出失败（忽略）"

# ---------- 3. 图片 ----------
if [ -d "$IMAGE_DIR" ]; then
  tar -czf "$WORK/images.tar.gz" -C "$IMAGE_DIR" . 2>/dev/null || true
  log "图片打包完成 $(du -h "$WORK/images.tar.gz" 2>/dev/null | cut -f1)"
else
  log "图片目录不存在，跳过"
fi

# ---------- 4. 汇总 ----------
PKG="${BACKUP_DIR_OVERRIDE}/couple-${STAMP}.tar.gz"
tar -czf "$PKG" -C "$WORK" . 
chmod 600 "$PKG" 2>/dev/null || true
log "备份包生成：$PKG ($(du -h "$PKG" | cut -f1))"

# ---------- 5. 只保留最近 N 份 ----------
# 按文件名倒序（时间戳天然可比），删掉 N 之后的
ls -1t "${BACKUP_DIR_OVERRIDE}"/couple-*.tar.gz 2>/dev/null \
  | tail -n +"$((BACKUP_KEEP + 1))" \
  | while read -r old; do
      rm -f "$old" && log "清理旧备份：$(basename "$old")"
    done

log "完成，当前保留："
ls -lh "${BACKUP_DIR_OVERRIDE}"/couple-*.tar.gz 2>/dev/null | awk '{print "  " $9 "  " $5}'
