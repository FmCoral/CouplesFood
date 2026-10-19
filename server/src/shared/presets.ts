import { pool } from '../db.js';
import { config } from '../config.js';
import { hashPassword } from '../auth.js';

/** 预设分类（每对情侣各自复制一套） */
export const PRESET_TYPES = ['荤菜', '素菜', '汤', '主食', '甜品', '其他'] as const;
export const PRESET_FLAVORS = ['重口', '清淡', '辣', '甜', '酸', '香', '无'] as const;

type PresetType = (typeof PRESET_TYPES)[number];
type PresetFlavor = (typeof PRESET_FLAVORS)[number];

/**
 * 预设菜品（每对情侣复制一份）。
 * imageKey 指向 MEDIA_ROOT 下共享的静态资源 preset/*，所有关系共用同一份文件，
 * 因此删除情侣不会回收这些图片（它们不属于任何一段关系）。
 */
export const PRESET_DISHES: ReadonlyArray<{
  name: string;
  imageKey: string;
  type: PresetType;
  flavors: readonly PresetFlavor[];
}> = [
  { name: '冰淇淋', imageKey: 'preset/icecream.webp', type: '甜品', flavors: ['甜'] },
  { name: '奶茶', imageKey: 'preset/milktea.webp', type: '其他', flavors: ['甜', '香'] },
  { name: '火鸡面', imageKey: 'preset/fire-noodle.webp', type: '主食', flavors: ['辣', '重口'] },
  { name: '螺蛳粉', imageKey: 'preset/luosifen.jpg', type: '主食', flavors: ['辣', '酸', '重口'] },
];

/**
 * 关系建立时初始化：为这对情侣复制预设分类与预设菜品。
 * 必须在绑定事务内调用（传入 client）。
 * createdBy 是预设菜的创建者：dishes.created_by 是 NOT NULL 外键，
 * 绑定场景传发起邀请的一方（member_a）。
 */
export async function initCouplePresets(
  client: import('pg').PoolClient,
  coupleId: string,
  createdBy: string,
) {
  // DO UPDATE 而非 DO NOTHING：冲突时也要把 id 取回来（本函数只在全新关系上跑，
  // 冲突仅出现在重复调用时）。dish_types/dish_flavors 没有 UPDATE 触发器，空更新无副作用。
  const typeIds = new Map<string, string>();
  for (const [i, name] of PRESET_TYPES.entries()) {
    const { rows } = await client.query(
      `INSERT INTO dish_types (couple_id, name, sort_order, is_preset) VALUES ($1,$2,$3,true)
       ON CONFLICT (couple_id, name) DO UPDATE SET name = EXCLUDED.name
       RETURNING id`,
      [coupleId, name, i],
    );
    typeIds.set(name, rows[0].id as string);
  }

  const flavorIds = new Map<string, string>();
  for (const [i, name] of PRESET_FLAVORS.entries()) {
    const { rows } = await client.query(
      `INSERT INTO dish_flavors (couple_id, name, sort_order, is_preset) VALUES ($1,$2,$3,true)
       ON CONFLICT (couple_id, name) DO UPDATE SET name = EXCLUDED.name
       RETURNING id`,
      [coupleId, name, i],
    );
    flavorIds.set(name, rows[0].id as string);
  }

  for (const [i, dish] of PRESET_DISHES.entries()) {
    // updated_at 逐条往回退 1ms：接口按 updated_at DESC 取，本地库按 rowid DESC 渲染，
    // 两层反序叠起来正好还原 PRESET_DISHES 的排列，避免同时间戳导致顺序随机。
    const { rows } = await client.query(
      `INSERT INTO dishes (couple_id, name, image_key, is_available, created_by, updated_at)
       VALUES ($1,$2,$3,true,$4, now() - ($5::float8 * interval '1 second'))
       RETURNING id`,
      [coupleId, dish.name, dish.imageKey, createdBy, (PRESET_DISHES.length - i) * 0.001],
    );
    const dishId = rows[0].id as string;
    await client.query(
      `INSERT INTO dish_type_links (dish_id, type_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
      [dishId, typeIds.get(dish.type)],
    );
    for (const f of dish.flavors) {
      await client.query(
        `INSERT INTO dish_flavor_links (dish_id, flavor_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
        [dishId, flavorIds.get(f)],
      );
    }
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
