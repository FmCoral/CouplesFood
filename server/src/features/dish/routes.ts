import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, withTx } from '../../db.js';
import { config } from '../../config.js';
import { Conflict, Forbidden, NotFound, Validation, zodIssues } from '../../errors.js';
import { authenticate, currentCoupleId, me, requireNotAdmin } from '../../middleware/auth.js';
import { ensureCoupleEditable } from '../order/routes.js';
import { broadcast, emitInTx, type SyncEvent } from '../../events.js';

const UUID = z.string().uuid();

const dishShape = {
  id: UUID.optional(),
  name: z.string().trim().min(1, '菜名不能为空').max(40, '菜名最多 40 字'),
  imageKey: z.string().max(300).nullable().optional(),
  note: z.string().max(200, '备注最多 200 字').nullable().optional(),
  tags: z.array(z.string().trim().min(1).max(12)).max(10, '标签最多 10 个').default([]),
  typeId: UUID.nullable().optional(),
  flavorIds: z.array(UUID).max(10).default([]),
  isAvailable: z.boolean().optional(),
};

function mediaUrl(key: string | null): string | null {
  if (!key) return null;
  const base = config.MEDIA_BASE_URL || '';
  return `${base}${config.MEDIA_BASE_PATH}/${key}`;
}

/** 一次性取菜品的分类/口味，避免 N+1 */
async function attachCategories(coupleId: string, dishIds: string[]) {
  if (dishIds.length === 0) return { types: new Map<string, any>(), flavors: new Map<string, any[]>() };
  const t = await pool.query(
    `SELECT l.dish_id, t.id, t.name FROM dish_type_links l
       JOIN dish_types t ON t.id = l.type_id
      WHERE l.dish_id = ANY($1::uuid[]) AND t.couple_id = $2`,
    [dishIds, coupleId],
  );
  const f = await pool.query(
    `SELECT l.dish_id, f.id, f.name FROM dish_flavor_links l
       JOIN dish_flavors f ON f.id = l.flavor_id
      WHERE l.dish_id = ANY($1::uuid[]) AND f.couple_id = $2
      ORDER BY f.sort_order`,
    [dishIds, coupleId],
  );
  const types = new Map<string, any>();
  for (const r of t.rows) types.set(r.dish_id, { id: r.id, name: r.name });
  const flavors = new Map<string, any[]>();
  for (const r of f.rows) {
    const arr = flavors.get(r.dish_id) ?? [];
    arr.push({ id: r.id, name: r.name });
    flavors.set(r.dish_id, arr);
  }
  return { types, flavors };
}

export default async function dishRoutes(app: FastifyInstance) {
  // ---------------- 列表 ----------------
  app.get('/api/dishes', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    const q = z.object({
      typeId: UUID.optional(),
      flavorIds: z.string().optional(),        // 逗号分隔，取交集
      q: z.string().max(40).optional(),
      includeUnavailable: z.coerce.boolean().default(false),
      updatedSince: z.string().datetime().optional(),
      limit: z.coerce.number().min(1).max(200).default(100),
    }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));

    const flavorIds = q.data.flavorIds ? q.data.flavorIds.split(',').filter(Boolean) : [];

    // 口味取交集：用 GROUP BY + HAVING 保证全部命中，而不是任一命中
    const { rows } = await pool.query(
      `SELECT d.id, d.name, d.image_key, d.note, d.tags, d.is_available, d.version,
              d.created_by, d.created_at, d.updated_at
         FROM dishes d
         JOIN couples c ON c.id = d.couple_id
        WHERE d.couple_id = $1
          AND c.status <> 'dissolved'
          AND d.deleted_at IS NULL
          AND ($2::uuid IS NULL OR EXISTS (
                SELECT 1 FROM dish_type_links l WHERE l.dish_id = d.id AND l.type_id = $2))
          AND ($5::boolean OR d.is_available = true)
          AND ($6::timestamptz IS NULL OR d.updated_at > $6)
          AND ($7::text IS NULL OR d.name ILIKE '%' || $7 || '%')
          AND ($3::uuid[] = '{}' OR d.id IN (
                SELECT l.dish_id FROM dish_flavor_links l
                 WHERE l.flavor_id = ANY($3::uuid[])
                 GROUP BY l.dish_id
                HAVING COUNT(DISTINCT l.flavor_id) = $4::int))
        ORDER BY d.updated_at DESC
        LIMIT $8`,
      [coupleId, q.data.typeId ?? null, flavorIds, flavorIds.length, q.data.includeUnavailable, q.data.updatedSince ?? null, q.data.q ?? null, q.data.limit],
    );

    const { types, flavors } = await attachCategories(coupleId, rows.map((r) => r.id));
    return {
      data: rows.map((r) => ({
        id: r.id,
        name: r.name,
        imageKey: r.image_key,
        imageUrl: mediaUrl(r.image_key),
        note: r.note,
        tags: r.tags,
        type: types.get(r.id) ?? null,
        flavors: flavors.get(r.id) ?? [],
        isAvailable: r.is_available,
        version: r.version,
        createdBy: r.created_by,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
      })),
      nextCursor: null,
    };
  });

  // ---------------- 增量 ----------------
  app.get('/api/dishes/changes', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    const q = z.object({ since: z.string().datetime() }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));
    const { rows } = await pool.query(
      `SELECT id, name, version, is_available AS "isAvailable", deleted_at AS "deletedAt", updated_at AS "updatedAt"
         FROM dishes WHERE couple_id = $1 AND updated_at > $2 ORDER BY updated_at ASC LIMIT 500`,
      [coupleId, q.data.since],
    );
    return { data: rows };
  });

  // ---------------- 单条 ----------------
  app.get('/api/dishes/:id', { preHandler: authenticate }, async (req) => {
    const { id } = z.object({ id: UUID }).parse(req.params);
    const coupleId = currentCoupleId(req);
    const { rows } = await pool.query(
      `SELECT d.*, d.image_key FROM dishes d WHERE d.id = $1 AND d.couple_id = $2 AND d.deleted_at IS NULL`,
      [id, coupleId],
    );
    const r = rows[0];
    if (!r) throw new NotFound();
    const { types, flavors } = await attachCategories(coupleId, [id]);
    return {
      data: {
        id: r.id,
        name: r.name,
        imageKey: r.image_key,
        imageUrl: mediaUrl(r.image_key),
        note: r.note,
        tags: r.tags,
        type: types.get(id) ?? null,
        flavors: flavors.get(id) ?? [],
        isAvailable: r.is_available,
        version: r.version,
        createdBy: r.created_by,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
      },
    };
  });

  // ---------------- 新建（支持客户端 UUID，离线新建）----------------
  app.post('/api/dishes', { preHandler: [authenticate, requireNotAdmin] }, async (req, reply) => {
    const parsed = z.object(dishShape).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const d = parsed.data;
    const coupleId = currentCoupleId(req);
    const u = me(req);
    await ensureCoupleEditable(coupleId);

    // 幂等：离线队列重放时，同一个 id 不应重复创建
    if (d.id) {
      const exist = await pool.query('SELECT id, version FROM dishes WHERE id = $1 AND couple_id = $2', [d.id, coupleId]);
      if (exist.rowCount) {
        reply.code(200);
        return { data: { id: d.id, version: exist.rows[0].version, idempotent: true } };
      }
    }

    if (d.typeId) {
      const ok = await pool.query('SELECT 1 FROM dish_types WHERE id = $1 AND couple_id = $2', [d.typeId, coupleId]);
      if (!ok.rowCount) throw new Validation([{ path: ['typeId'], message: '种类不存在' }]);
    }
    if (d.flavorIds.length) {
      const ok = await pool.query(
        'SELECT id FROM dish_flavors WHERE id = ANY($1::uuid[]) AND couple_id = $2', [d.flavorIds, coupleId]);
      if (ok.rowCount !== d.flavorIds.length) throw new Validation([{ path: ['flavorIds'], message: '口味不存在' }]);
    }

    const result = await withTx(async (c) => {
      const { rows } = await c.query(
        `INSERT INTO dishes (id, couple_id, name, image_key, note, tags, is_available, created_by)
         VALUES (COALESCE($1::uuid, gen_random_uuid()), $2,$3,$4,$5,$6,$7,$8)
         RETURNING id, version, created_at`,
        [d.id ?? null, coupleId, d.name, d.imageKey ?? null, d.note ?? null, d.tags, d.isAvailable ?? true, u.userId],
      );
      const dish = rows[0];
      if (d.typeId) {
        await c.query('INSERT INTO dish_type_links (dish_id, type_id) VALUES ($1,$2)', [dish.id, d.typeId]);
      }
      for (const fid of d.flavorIds) {
        await c.query(
          'INSERT INTO dish_flavor_links (dish_id, flavor_id) VALUES ($1,$2) ON CONFLICT DO NOTHING',
          [dish.id, fid],
        );
      }
      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'dish.created', entityType: 'dish', entityId: dish.id,
        payload: { ...d, id: dish.id, version: dish.version }, version: dish.version,
      });
      return { dish, events: [evt] as SyncEvent[] };
    });

    broadcast(coupleId, result.events);
    reply.code(201);
    return { data: { id: result.dish.id, version: result.dish.version, createdAt: result.dish.created_at } };
  });

  // ---------------- 编辑（乐观锁）----------------
  app.patch('/api/dishes/:id', { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
    const { id } = z.object({ id: UUID }).parse(req.params);
    const parsed = z.object(dishShape).partial().extend({
      version: z.number().int().positive('version 必填'),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const { version, ...patch } = parsed.data;
    const coupleId = currentCoupleId(req);
    const u = me(req);
    await ensureCoupleEditable(coupleId);

    const exists = await pool.query(
      'SELECT id FROM dishes WHERE id = $1 AND couple_id = $2 AND deleted_at IS NULL', [id, coupleId]);
    if (!exists.rowCount) throw new NotFound();

    if (patch.typeId) {
      const ok = await pool.query('SELECT 1 FROM dish_types WHERE id = $1 AND couple_id = $2', [patch.typeId, coupleId]);
      if (!ok.rowCount) throw new Validation([{ path: ['typeId'], message: '种类不存在' }]);
    }

    const result = await withTx(async (c) => {
      // 乐观锁：版本不匹配 = 对方改过 → 409
      const { rows } = await c.query(
        `UPDATE dishes SET
            name = COALESCE($4, name),
            image_key = COALESCE($5, image_key),
            note = COALESCE($6, note),
            tags = COALESCE($7, tags),
            is_available = COALESCE($8, is_available),
            version = version + 1
          WHERE id = $1 AND couple_id = $2 AND version = $3 AND deleted_at IS NULL
          RETURNING id, version, updated_at`,
        [id, coupleId, version, patch.name ?? null, patch.imageKey ?? null, patch.note ?? null,
         patch.tags ?? null, patch.isAvailable ?? null],
      );
      if (!rows[0]) throw new Conflict('这道菜已被对方修改，请刷新后重试', { expectedVersion: version });
      const updated = rows[0];

      if (patch.typeId !== undefined) {
        await c.query('DELETE FROM dish_type_links WHERE dish_id = $1', [id]);
        if (patch.typeId) {
          await c.query('INSERT INTO dish_type_links (dish_id, type_id) VALUES ($1,$2)', [id, patch.typeId]);
        }
      }
      if (patch.flavorIds !== undefined) {
        await c.query('DELETE FROM dish_flavor_links WHERE dish_id = $1', [id]);
        for (const fid of patch.flavorIds) {
          await c.query(
            'INSERT INTO dish_flavor_links (dish_id, flavor_id) VALUES ($1,$2) ON CONFLICT DO NOTHING', [id, fid]);
        }
      }

      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'dish.updated', entityType: 'dish', entityId: id,
        payload: patch, version: updated.version,
      });
      return { updated, events: [evt] as SyncEvent[] };
    });

    broadcast(coupleId, result.events);
    return { data: { id, version: result.updated.version, updatedAt: result.updated.updated_at } };
  });

  // ---------------- 软删除 ----------------
  app.delete('/api/dishes/:id', { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
    const { id } = z.object({ id: UUID }).parse(req.params);
    const coupleId = currentCoupleId(req);
    const u = me(req);
    await ensureCoupleEditable(coupleId);

    const result = await withTx(async (c) => {
      const { rows } = await c.query(
        `UPDATE dishes SET deleted_at = now(), is_available = false, version = version + 1
          WHERE id = $1 AND couple_id = $2 AND deleted_at IS NULL
          RETURNING version`,
        [id, coupleId],
      );
      if (!rows[0]) throw new NotFound();
      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'dish.deleted', entityType: 'dish', entityId: id,
        payload: {}, version: rows[0].version,
      });
      return { version: rows[0].version as number, events: [evt] as SyncEvent[] };
    });

    broadcast(coupleId, result.events);
    return { data: { id, version: result.version, deletedAt: new Date().toISOString() } };
  });
}
