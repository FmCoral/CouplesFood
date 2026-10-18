import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type pg from 'pg';
import { pool } from '../db.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));

/**
 * schema.sql 在仓库里的位置（按优先级探测）：
 *   - 容器内：镜像把 docs/schema.sql 拷到 /app/schema.sql
 *   - 本机开发：server/src/shared/ → ../../../docs/schema.sql
 */
const CANDIDATES = [
  path.resolve(HERE, '../../schema.sql'), // dist/shared/ -> /app/schema.sql 或 server/src/shared/ -> server/schema.sql
  path.resolve(HERE, '../../../docs/schema.sql'),
  path.resolve(process.cwd(), 'schema.sql'),
  path.resolve(process.cwd(), '../docs/schema.sql'),
];

async function loadSchemaSql(): Promise<string | null> {
  for (const p of CANDIDATES) {
    if (existsSync(p)) return readFile(p, 'utf8');
  }
  return null;
}

/**
 * 幂等迁移。
 *
 * 做法：整个 schema 在一个事务里跑，若 `users` 表已存在则整体跳过。
 * 这比「逐条 IF NOT EXISTS」简单可靠 —— schema.sql 里的 CREATE TRIGGER
 * 不支持 IF NOT EXISTS，逐条改写极易出错。
 *
 * 局限：只处理「从零建库」。后续演进需要引入带版本号的迁移文件，
 * 但对 5 人以内的内部应用，一次性建表 + 备份恢复已经足够。
 */
export async function runMigrations(log: { info: (o: object, m: string) => void; warn: (o: object, m: string) => void }) {
  // 已有表 → 直接返回
  const probe = await pool.query(`SELECT to_regclass('public.users') AS t`);
  if (probe.rows[0]?.t) {
    log.info({ table: probe.rows[0].t }, 'schema 已存在，跳过迁移');
    return { applied: false };
  }

  const sql = await loadSchemaSql();
  if (!sql) {
    throw new Error(
      `找不到 schema.sql。已尝试：\n  ${CANDIDATES.join('\n  ')}\n` +
        '请确认 Dockerfile 里 COPY 了 docs/schema.sql，或本地把 docs/ 放在仓库根目录。',
    );
  }

  const client: pg.PoolClient = await pool.connect();
  try {
    await client.query('BEGIN');
    // 建表期间不要在别人的锁上干等
    await client.query(`SET LOCAL lock_timeout = '10s'`);
    await client.query(sql);
    await client.query('COMMIT');
    log.info({ bytes: sql.length }, 'schema 迁移完成');
    return { applied: true };
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}
