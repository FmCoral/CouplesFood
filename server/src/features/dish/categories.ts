import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, withTx } from '../../db.js';
import { Conflict, Validation, zodIssues } from '../../errors.js';
import { authenticate, currentCoupleId, me, requireNotAdmin } from '../../middleware/auth.js';
import { ensureCoupleEditable } from '../order/routes.js';
import { broadcast, emitInTx, type SyncEvent } from '../../events.js';

/**
 * 种类 / 口味 两个维度接口完全对称，用同一个工厂生成。
 * 分开建两张表的原因见 docs/架构与开发方案.md §4.3
 */
type Dim = 'type' | 'flavor';

const TABLES: Record<Dim, { table: string; linkTable: string; linkCol: string; entity: 'dish_type' | 'dish_flavor' }> = {
  type: { table: 'dish_types', linkTable: 'dish_type_links', linkCol: 'type_id', entity: 'dish_type' },
  flavor: { table: 'dish_flavors', linkTable: 'dish_flavor_links', linkCol: 'flavor_id', entity: 'dish_flavor' },
};

function makeRoutes(dim: Dim) {
  const { table, linkTable, linkCol, entity } = TABLES[dim];

  return async function routes(app: FastifyInstance) {
    const base = dim === 'type' ? '/api/dish-types' : '/api/dish-flavors';

    // 列表（带使用数量）
    app.get(base, { preHandler: authenticate }, async (req) => {
      const coupleId = currentCoupleId(req);
      const { rows } = await pool.query(
        `SELECT t.id, t.name, t.sort_order AS "sortOrder", t.is_preset AS "isPreset",
                COUNT(l.dish_id)::int AS "dishCount"
           FROM ${table} t
           LEFT JOIN ${linkTable} l ON l.${linkCol} = t.id
          WHERE t.couple_id = $1
          GROUP BY t.id
          ORDER BY t.sort_order, t.name`,
        [coupleId],
      );
      return { data: rows };
    });

    // 新增
    app.post(base, { preHandler: [authenticate, requireNotAdmin] }, async (req, reply) => {
      const parsed = z.object({
        name: z.string().trim().min(1, '名称不能为空').max(12, '最多 12 字'),
        sortOrder: z.number().int().min(0).max(999).optional(),
      }).safeParse(req.body);
      if (!parsed.success) throw new Validation(zodIssues(parsed.error));
      const coupleId = currentCoupleId(req);
      const u = me(req);
      await ensureCoupleEditable(coupleId);

      const dup = await pool.query(`SELECT 1 FROM ${table} WHERE couple_id = $1 AND name = $2`, [coupleId, parsed.data.name]);
      if (dup.rowCount) throw new Conflict('同名分类已存在');

      const maxOrder = await pool.query(`SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM ${table} WHERE couple_id = $1`, [coupleId]);

      const events = await withTx(async (c) => {
        const { rows } = await c.query(
          `INSERT INTO ${table} (couple_id, name, sort_order) VALUES ($1,$2,$3)
           RETURNING id, name, sort_order AS "sortOrder", is_preset AS "isPreset"`,
          [coupleId, parsed.data.name, parsed.data.sortOrder ?? maxOrder.rows[0].n],
        );
        const evt = await emitInTx(c, {
          coupleId, actorId: u.userId, type: `${entity}.created`,
          entityType: entity, entityId: rows[0].id, payload: rows[0],
        });
        return [evt];
      });

      broadcast(coupleId, events);
      reply.code(201);
      return { data: { id: events[0]?.entityId } };
    });

    // 改名 / 排序
    app.patch(`${base}/:id`, { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
      const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
      const parsed = z.object({
        name: z.string().trim().min(1).max(12).optional(),
        sortOrder: z.number().int().min(0).max(999).optional(),
      }).safeParse(req.body);
      if (!parsed.success) throw new Validation(zodIssues(parsed.error));
      const coupleId = currentCoupleId(req);
      const u = me(req);
      await ensureCoupleEditable(coupleId);

      const owns = await pool.query(`SELECT name FROM ${table} WHERE id = $1 AND couple_id = $2`, [id, coupleId]);
      if (!owns.rowCount) throw new Conflict('分类不存在');

      if (parsed.data.name) {
        const dup = await pool.query(
          `SELECT 1 FROM ${table} WHERE couple_id = $1 AND name = $2 AND id <> $3`,
          [coupleId, parsed.data.name, id],
        );
        if (dup.rowCount) throw new Conflict('同名分类已存在');
      }

      const events = await withTx(async (c) => {
        await c.query(
          `UPDATE ${table} SET name = COALESCE($3, name), sort_order = COALESCE($4, sort_order) WHERE id = $1 AND couple_id = $2`,
          [id, coupleId, parsed.data.name ?? null, parsed.data.sortOrder ?? null],
        );
        const evt = await emitInTx(c, {
          coupleId, actorId: u.userId, type: `${entity}.updated`,
          entityType: entity, entityId: id, payload: parsed.data,
        });
        return [evt];
      });

      broadcast(coupleId, events);
      return { data: { id } };
    });

    // 删除：只解除关联，不删菜品
    app.delete(`${base}/:id`, { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
      const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
      const coupleId = currentCoupleId(req);
      const u = me(req);
      await ensureCoupleEditable(coupleId);

      const owns = await pool.query(`SELECT 1 FROM ${table} WHERE id = $1 AND couple_id = $2`, [id, coupleId]);
      if (!owns.rowCount) throw new Conflict('分类不存在');

      const affected = await withTx(async (c) => {
        const cnt = await c.query(
          `SELECT COUNT(*)::int AS n FROM ${linkTable} l
             JOIN dishes d ON d.id = l.dish_id AND d.deleted_at IS NULL
            WHERE l.${linkCol} = $1`,
          [id],
        );
        await c.query(`DELETE FROM ${table} WHERE id = $1 AND couple_id = $2`, [id, coupleId]);
        const evt = await emitInTx(c, {
          coupleId, actorId: u.userId, type: `${entity}.deleted`,
          entityType: entity, entityId: id, payload: { affectedDishes: cnt.rows[0]?.n ?? 0 },
        });
        return { count: cnt.rows[0]?.n ?? 0, events: [evt] as SyncEvent[] };
      });

      broadcast(coupleId, affected.events);
      // 返回受影响菜品数，供客户端提示「有 3 道菜变成了未分类」
      return { data: { id, affectedDishes: affected.count } };
    });
  };
}

export const dishTypeRoutes = makeRoutes('type');
export const dishFlavorRoutes = makeRoutes('flavor');
