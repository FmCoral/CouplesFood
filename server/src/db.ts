import pg from 'pg';
import { config } from './config.js';

// 2C2G 机器：连接池必须小。默认 10 条在内存紧张时会成为负担。
export const pool = new pg.Pool({
  connectionString: config.DATABASE_URL,
  max: 8,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 8_000,
  statement_timeout: 15_000,
  query_timeout: 20_000,
});

pool.on('error', (err) => {
  // 空闲连接被服务端断开是正常的，不要让它冒泡成未捕获异常
  console.error(JSON.stringify({ level: 'error', msg: 'pg idle client error', err: err.message }));
});

/** 事务封装；fn 内抛错自动回滚 */
export async function withTx<T>(fn: (c: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const out = await fn(client);
    await client.query('COMMIT');
    return out;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

export type Db = pg.Pool | pg.PoolClient;

export async function dbHealthy(): Promise<boolean> {
  try { await pool.query('SELECT 1'); return true; } catch { return false; }
}
