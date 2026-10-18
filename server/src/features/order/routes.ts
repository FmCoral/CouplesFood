import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, withTx } from '../../db.js';
import { config } from '../../config.js';
import { Conflict, NotFound, Validation, zodIssues } from '../../errors.js';
import { authenticate, currentCoupleId, me, requireNotAdmin } from '../../middleware/auth.js';
import { broadcast, emitInTx, type SyncEvent } from '../../events.js';

const UUID = z.string().uuid();

/** 状态机：后端是唯一裁决者，客户端状态只是 UI 提示 */
const TRANSITIONS: Record<string, readonly string[]> = {
  pending: ['accepted', 'rejected', 'cancelled'],
  accepted: ['cooking', 'cancelled', 'rejected'],
  cooking: ['served'],
  served: ['completed'],
  completed: [],
  rejected: [],
  cancelled: [],
};

const TS_COL: Record<string, string | undefined> = {
  accepted: 'accepted_at',
  served: 'served_at',
  completed: 'completed_at',
};

function mediaUrl(key: string | null): string | null {
  if (!key) return null;
  return `${config.MEDIA_BASE_URL || ''}${config.MEDIA_BASE_PATH}/${key}`;
}

async function ensureCoupleWritable(coupleId: string) {
  const { rows } = await pool.query('SELECT status FROM couples WHERE id = $1', [coupleId]);
  const status = rows[0]?.status;
  if (status !== 'active') {
    throw new Conflict(status === 'dissolving' ? '解散申请处理中，暂时只能查看' : '关系状态异常，无法操作');
  }
}

/** 冻结期（dissolving）连菜单都不允许改：解散申请已发起，双方只能查看 */
export async function ensureCoupleEditable(coupleId: string) {
  await ensureCoupleWritable(coupleId);
}

export default async function orderRoutes(app: FastifyInstance) {
  // ---------------- 下单 ----------------
  app.post('/api/orders', { preHandler: [authenticate, requireNotAdmin] }, async (req, reply) => {
    const parsed = z.object({
      items: z.array(z.object({
        dishId: UUID,
        quantity: z.number().int().min(1).max(20).default(1),
        note: z.string().max(100).optional(),
      })).min(1, '至少选一道菜').max(50, '一次最多 50 道'),
      mealType: z.enum(['breakfast', 'lunch', 'dinner', 'night_snack']).default('dinner'),
      note: z.string().max(200).optional(),
      etaAt: z.string().datetime().optional(),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const input = parsed.data;
    const coupleId = currentCoupleId(req);
    const u = me(req);

    await ensureCoupleWritable(coupleId);

    const result = await withTx(async (c) => {
      // 一次查全部菜品：防 N+1，同时校验归属与上架状态
      const ids = [...new Set(input.items.map((i) => i.dishId))];
      const { rows: dishes } = await c.query(
        `SELECT id, name, image_key, is_available, deleted_at
           FROM dishes WHERE couple_id = $1 AND id = ANY($2::uuid[])`,
        [coupleId, ids],
      );
      const map = new Map(dishes.map((d) => [d.id, d]));
      for (const item of input.items) {
        const d = map.get(item.dishId);
        if (!d || d.deleted_at) throw new Validation([{ path: ['items'], message: '菜品不存在' }]);
        if (!d.is_available) throw new Conflict(`「${d.name}」已下架，请重新选择`);
      }

      const partner = await c.query(
        `SELECT CASE WHEN member_a = $1 THEN member_b ELSE member_a END AS partner FROM couples WHERE id = $2`,
        [u.userId, coupleId],
      );

      const { rows } = await c.query(
        `INSERT INTO orders (couple_id, requester_id, chef_id, meal_type, request_note, eta_at)
         VALUES ($1,$2,$3,$4,$5,$6)
         RETURNING id, status, version, created_at`,
        [coupleId, u.userId, partner.rows[0]?.partner ?? null, input.mealType, input.note ?? null, input.etaAt ?? null],
      );
      const order = rows[0];

      for (const item of input.items) {
        const d = map.get(item.dishId)!;
        await c.query(
          `INSERT INTO order_items (order_id, dish_id, dish_name, dish_image_key, quantity, note)
           VALUES ($1,$2,$3,$4,$5,$6)
           ON CONFLICT (order_id, dish_id) DO UPDATE SET quantity = order_items.quantity + EXCLUDED.quantity`,
          [order.id, d.id, d.name, d.image_key, item.quantity, item.note ?? null],
        );
      }

      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'order.created', entityType: 'order', entityId: order.id,
        payload: { status: order.status, items: input.items.map((i) => ({ ...i, name: map.get(i.dishId)!.name })) },
        version: order.version,
      });
      return { order, events: [evt] as SyncEvent[] };
    });

    broadcast(coupleId, result.events);
    reply.code(201);
    return { data: { id: result.order.id, status: result.order.status, version: result.order.version, createdAt: result.order.created_at } };
  });

  // ---------------- 状态流转 ----------------
  app.post('/api/orders/:id/transition', { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
    const { id } = z.object({ id: UUID }).parse(req.params);
    const parsed = z.object({
      to: z.enum(['accepted', 'rejected', 'cooking', 'served', 'completed', 'cancelled']),
      version: z.number().int().positive(),
      replyNote: z.string().max(200).optional(),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const { to, version, replyNote } = parsed.data;
    const coupleId = currentCoupleId(req);
    const u = me(req);

    await ensureCoupleWritable(coupleId);

    const result = await withTx(async (c) => {
      const { rows } = await c.query(
        'SELECT id, status, requester_id, chef_id FROM orders WHERE id = $1 AND couple_id = $2 FOR UPDATE',
        [id, coupleId],
      );
      const o = rows[0];
      if (!o) throw new NotFound();

      // 权限分工：
      //   下单人：取消订单、确认收货（completed）
      //   厨师方：接单 / 拒单 / 开火 / 出餐
      const isRequester = o.requester_id === u.userId;
      const requesterOnly = to === 'cancelled' || to === 'completed';
      if (requesterOnly && !isRequester) {
        throw new Conflict(to === 'cancelled' ? '只有下单人可以取消' : '只有下单人可以确认收货');
      }
      if (!requesterOnly && isRequester) throw new Conflict('不能处理自己下的单');

      if (!TRANSITIONS[o.status]?.includes(to)) {
        throw new Conflict(`当前状态「${o.status}」不能变更为「${to}」`);
      }

      const tsCol = TS_COL[to];
      const { rows: upd } = await c.query(
        `UPDATE orders SET status = $1, reply_note = COALESCE($2, reply_note), version = version + 1
           ${tsCol ? `, ${tsCol} = now()` : ''}
         WHERE id = $3 AND couple_id = $4 AND version = $5
         RETURNING id, status, version, updated_at`,
        [to, replyNote ?? null, id, coupleId, version],
      );
      if (!upd[0]) throw new Conflict('订单已被对方更新，请刷新后重试');

      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'order.status_changed', entityType: 'order', entityId: id,
        payload: { from: o.status, to, replyNote: replyNote ?? null }, version: upd[0].version,
      });
      return { order: upd[0], events: [evt] as SyncEvent[] };
    });

    broadcast(coupleId, result.events);
    return { data: { id, status: result.order.status, version: result.order.version, updatedAt: result.order.updated_at } };
  });

  // ---------------- 列表 ----------------
  app.get('/api/orders', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    const q = z.object({
      status: z.string().optional(),
      limit: z.coerce.number().min(1).max(50).default(20),
      cursor: z.string().datetime().optional(),
    }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));

    const { rows } = await pool.query(
      `SELECT o.id, o.status, o.meal_type, o.request_note, o.reply_note,
              o.requester_id, o.chef_id, o.version, o.eta_at,
              o.created_at, o.accepted_at, o.served_at, o.completed_at,
              COALESCE(json_agg(json_build_object(
                 'dishId', i.dish_id, 'name', i.dish_name, 'imageKey', i.dish_image_key,
                 'quantity', i.quantity, 'note', i.note) ORDER BY i.id)
                 FILTER (WHERE i.id IS NOT NULL), '[]') AS items
         FROM orders o LEFT JOIN order_items i ON i.order_id = o.id
        WHERE o.couple_id = $1
          AND ($2::text IS NULL OR o.status = $2)
          AND ($3::timestamptz IS NULL OR o.created_at < $3)
        GROUP BY o.id
        ORDER BY o.created_at DESC
        LIMIT $4`,
      [coupleId, q.data.status ?? null, q.data.cursor ?? null, q.data.limit],
    );

    const data = rows.map((r) => ({
      id: r.id,
      status: r.status,
      mealType: r.meal_type,
      requestNote: r.request_note,
      replyNote: r.reply_note,
      requesterId: r.requester_id,
      chefId: r.chef_id,
      version: r.version,
      etaAt: r.eta_at,
      items: r.items.map((i: any) => ({ ...i, imageUrl: mediaUrl(i.imageKey) })),
      timeline: { createdAt: r.created_at, acceptedAt: r.accepted_at, servedAt: r.served_at, completedAt: r.completed_at },
      createdAt: r.created_at,
      updatedAt: r.updated_at,
    }));

    return { data, nextCursor: rows.at(-1)?.created_at ?? null };
  });

  // ---------------- 首页「进行中」 ----------------
  app.get('/api/orders/active', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    const { rows } = await pool.query(
      `SELECT o.id, o.status, o.requester_id, o.chef_id, o.version, o.request_note, o.created_at,
              COALESCE(json_agg(json_build_object('name', i.dish_name, 'quantity', i.quantity)
                 ORDER BY i.id) FILTER (WHERE i.id IS NOT NULL), '[]') AS items
         FROM orders o LEFT JOIN order_items i ON i.order_id = o.id
        WHERE o.couple_id = $1 AND o.status IN ('pending','accepted','cooking','served')
        GROUP BY o.id ORDER BY o.created_at DESC LIMIT 5`,
      [coupleId],
    );
    return { data: rows };
  });
}
