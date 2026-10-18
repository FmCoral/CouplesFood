import { pool } from '../db.js';
import { config } from '../config.js';
import { hashPassword } from '../auth.js';

/** 预设分类（每对情侣各自复制一套） */
export const PRESET_TYPES = ['荤菜', '素菜', '汤', '主食', '甜品', '其他'] as const;
export const PRESET_FLAVORS = ['重口', '清淡', '辣', '甜', '酸', '香', '无'] as const;

/**
 * 关系建立时初始化：为这对情侣复制预设分类。
 * 必须在绑定事务内调用（传入 client）。
 */
export async function initCoupleCategories(client: import('pg').PoolClient, coupleId: string) {
  for (const [i, name] of PRESET_TYPES.entries()) {
    await client.query(
      `INSERT INTO dish_types (couple_id, name, sort_order, is_preset) VALUES ($1,$2,$3,true)
       ON CONFLICT (couple_id, name) DO NOTHING`,
      [coupleId, name, i],
    );
  }
  for (const [i, name] of PRESET_FLAVORS.entries()) {
    await client.query(
      `INSERT INTO dish_flavors (couple_id, name, sort_order, is_preset) VALUES ($1,$2,$3,true)
       ON CONFLICT (couple_id, name) DO NOTHING`,
      [coupleId, name, i],
    );
  }
}

/**
 * 启动时确保超管存在（幂等）。
 * 密码只来自环境变量，代码里绝不硬编码。
 */
export async function ensureAdmin() {
  const { rows } = await pool.query('SELECT id, is_admin FROM users WHERE phone = $1', [config.ADMIN_PHONE]);
  const existing = rows[0];

  if (existing) {
    if (!existing.is_admin) {
      await pool.query('UPDATE users SET is_admin = true WHERE id = $1', [existing.id]);
    }
    return { created: false, userId: existing.id as string };
  }

  const { rows: created } = await pool.query(
    `INSERT INTO users (phone, password_hash, nickname, is_admin)
     VALUES ($1,$2,$3,true) RETURNING id`,
    [config.ADMIN_PHONE, await hashPassword(config.ADMIN_PASSWORD), config.ADMIN_NICKNAME],
  );
  return { created: true, userId: created[0].id as string };
}
