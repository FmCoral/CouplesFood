import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { readdir, stat, statfs } from 'node:fs/promises';
import { join } from 'node:path';
import { pool, withTx } from '../../db.js';
import { config } from '../../config.js';
import { hashPassword } from '../../auth.js';
import { Conflict, NotFound, Validation, zodIssues } from '../../errors.js';
import { authenticate, requireAdmin, me } from '../../middleware/auth.js';
import { broadcast, emitInTx } from '../../events.js';

async function audit(
  adminId: string,
  action: string,
  targetType: string | null,
  targetId: string | null,
  detail: Record<string, unknown>,
  ip: string,
) {
  await pool.query(
    `INSERT INTO admin_audit_log (admin_id, action, target_type, target_id, detail, ip)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [adminId, action, targetType, targetId, JSON.stringify(detail), ip],
  );
}

const maskPhone = (p: string) => p.replace(/^(\d{3})\d{4}(\d{4})$/, '$1****$2');

export default async function adminRoutes(app: FastifyInstance) {
  const guard = { preHandler: [authenticate, requireAdmin] };

  // ---------------- 情侣列表 ----------------
  app.get('/api/admin/couples', guard, async (req) => {
    const q = z.object({
      status: z.enum(['active', 'dissolving', 'dissolved', 'all']).default('active'),
      limit: z.coerce.number().min(1).max(100).default(50),
      offset: z.coerce.number().min(0).default(0),
    }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));
    const u = me(req);
    await audit(u.userId, 'view.couples', null, null, { status: q.data.status }, req.ip);

    const { rows } = await pool.query(
      `SELECT c.id, c.status, c.bound_at, c.dissolved_at, c.dissolved_reason,
              (SELECT COUNT(*)::int FROM dishes d WHERE d.couple_id = c.id AND d.deleted_at IS NULL) AS dish_count,
              (SELECT COUNT(*)::int FROM orders o WHERE o.couple_id = c.id) AS order_count,
              (SELECT MAX(created_at) FROM sync_events e WHERE e.couple_id = c.id) AS last_event_at,
              (SELECT json_agg(json_build_object(
                  'id', u.id, 'nickname', u.nickname, 'phone', u.phone, 'roleLabel', cm.role_label))
                 FROM couple_members cm JOIN users u ON u.id = cm.user_id
                WHERE cm.couple_id = c.id) AS members
         FROM couples c
        WHERE c.status <> 'pending'
          AND ($1 = 'all' OR c.status = $1)
        ORDER BY c.updated_at DESC
        LIMIT $2 OFFSET $3`,
      [q.data.status, q.data.limit, q.data.offset],
    );

    return {
      data: rows.map((r) => ({
        id: r.id,
        status: r.status,
        boundAt: r.bound_at,
        dissolvedAt: r.dissolved_at,
        dissolvedReason: r.dissolved_reason,
        dishCount: r.dish_count,
        orderCount: r.order_count,
        lastEventAt: r.last_event_at,
        members: (r.members ?? []).map((m: any) => ({ ...m, phone: maskPhone(m.phone) })),
      })),
    };
  });

  // ---------------- 只读查看某对情侣的菜单 ----------------
  app.get('/api/admin/couples/:id/menu', guard, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const u = me(req);
    const exists = await pool.query('SELECT 1 FROM couples WHERE id = $1', [id]);
    if (!exists.rowCount) throw new NotFound();
    await audit(u.userId, 'view.menu', 'couple', id, {}, req.ip);

    const { rows } = await pool.query(
      `SELECT d.id, d.name, d.image_key, d.note, d.tags, d.is_available, d.version,
              d.created_at, d.updated_at, d.deleted_at,
              (SELECT t.name FROM dish_type_links l JOIN dish_types t ON t.id = l.type_id WHERE l.dish_id = d.id) AS type_name,
              (SELECT json_agg(f.name ORDER BY f.sort_order) FROM dish_flavor_links fl
                 JOIN dish_flavors f ON f.id = fl.flavor_id WHERE fl.dish_id = d.id) AS flavors
         FROM dishes d WHERE d.couple_id = $1
        ORDER BY d.created_at DESC LIMIT 500`,
      [id],
    );
    return {
      data: rows.map((r) => ({
        id: r.id,
        name: r.name,
        imageUrl: r.image_key ? `${config.MEDIA_BASE_URL || ''}${config.MEDIA_BASE_PATH}/${r.image_key}` : null,
        note: r.note,
        tags: r.tags,
        typeName: r.type_name,
        flavors: r.flavors ?? [],
        isAvailable: r.is_available,
        version: r.version,
        deletedAt: r.deleted_at,
        createdAt: r.created_at,
        updatedAt: r.updated_at,
      })),
    };
  });

  // ---------------- 只读查看订单 ----------------
  app.get('/api/admin/couples/:id/orders', guard, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const u = me(req);
    const exists = await pool.query('SELECT 1 FROM couples WHERE id = $1', [id]);
    if (!exists.rowCount) throw new NotFound();
    await audit(u.userId, 'view.orders', 'couple', id, {}, req.ip);

    const { rows } = await pool.query(
      `SELECT o.id, o.status, o.meal_type, o.request_note, o.reply_note,
              o.created_at, o.accepted_at, o.served_at, o.completed_at,
              COALESCE(json_agg(json_build_object('name', i.dish_name, 'quantity', i.quantity, 'note', i.note)
                ORDER BY i.id) FILTER (WHERE i.id IS NOT NULL), '[]') AS items
         FROM orders o LEFT JOIN order_items i ON i.order_id = o.id
        WHERE o.couple_id = $1 GROUP BY o.id ORDER BY o.created_at DESC LIMIT 200`,
      [id],
    );
    return { data: rows };
  });

  // ---------------- 强制解散 ----------------
  app.post('/api/admin/couples/:id/dissolve', guard, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const parsed = z.object({ reason: z.string().min(1).max(200) }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const u = me(req);

    const result = await withTx(async (c) => {
      const cur = await c.query('SELECT status FROM couples WHERE id = $1 FOR UPDATE', [id]);
      if (!cur.rowCount) throw new NotFound();
      if (cur.rows[0].status === 'dissolved') throw new Conflict('该关系已解散');

      await c.query(
        `UPDATE dissolution_requests SET status = 'forced_by_admin', resolved_by = $1, resolved_at = now()
          WHERE couple_id = $2 AND status = 'pending'`,
        [u.userId, id],
      );
      await c.query(
        `UPDATE couples SET status = 'dissolved', dissolved_at = now(), dissolved_by = $1,
                dissolved_reason = 'admin', version = version + 1 WHERE id = $2`,
        [u.userId, id],
      );
      const evt = await emitInTx(c, {
        coupleId: id, actorId: u.userId, type: 'couple.dissolved',
        entityType: 'couple', entityId: id, payload: { reason: 'admin', note: parsed.data.reason },
      });
      return { events: [evt] };
    });

    await audit(u.userId, 'dissolve.couple', 'couple', id, { reason: parsed.data.reason }, req.ip);
    broadcast(id, result.events);
    return { data: { status: 'dissolved', dissolvedAt: new Date().toISOString() } };
  });

  // ---------------- 重置密码 ----------------
  app.post('/api/admin/users/:id/reset-password', guard, async (req) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const parsed = z.object({ newPassword: z.string().min(8).max(64) }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const u = me(req);

    const target = await pool.query('SELECT id, phone FROM users WHERE id = $1', [id]);
    if (!target.rowCount) throw new NotFound();

    await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [
      await hashPassword(parsed.data.newPassword), id,
    ]);
    // 踢掉该用户全部会话
    await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [id]);

    await audit(u.userId, 'reset.password', 'user', id, {}, req.ip);
    return { data: { ok: true } };
  });

  // ---------------- 用户列表 ----------------
  app.get('/api/admin/users', guard, async (req) => {
    const q = z.object({
      limit: z.coerce.number().min(1).max(100).default(50),
      offset: z.coerce.number().min(0).default(0),
    }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));
    const u = me(req);
    await audit(u.userId, 'view.users', null, null, {}, req.ip);

    const { rows } = await pool.query(
      `SELECT u.id, u.phone, u.nickname, u.is_admin, u.is_active, u.last_seen_at, u.created_at,
              c.id AS couple_id, c.status AS couple_status
         FROM users u
         LEFT JOIN couples c ON c.status <> 'dissolved' AND (c.member_a = u.id OR c.member_b = u.id)
        ORDER BY u.created_at DESC LIMIT $1 OFFSET $2`,
      [q.data.limit, q.data.offset],
    );
    return {
      data: rows.map((r) => ({
        id: r.id, phone: maskPhone(r.phone), nickname: r.nickname,
        isAdmin: r.is_admin, isActive: r.is_active,
        lastSeenAt: r.last_seen_at, createdAt: r.created_at,
        coupleId: r.couple_id, coupleStatus: r.couple_status,
      })),
    };
  });

  // ---------------- 系统状态 ----------------
  app.get('/api/admin/status', guard, async (req) => {
    const [counts, events, _online, disk, backup] = await Promise.all([
      pool.query(`SELECT
          (SELECT COUNT(*)::int FROM couples WHERE status = 'active') AS active,
          (SELECT COUNT(*)::int FROM couples WHERE status = 'dissolving') AS dissolving,
          (SELECT COUNT(*)::int FROM couples WHERE status = 'dissolved') AS archived,
          (SELECT COUNT(*)::int FROM users WHERE is_admin = false) AS users`),
      pool.query(`SELECT COUNT(*)::int AS n FROM sync_events WHERE created_at > now() - interval '24 hours'`),
      pool.query(`SELECT COUNT(*)::int AS n FROM users WHERE is_admin = false AND last_seen_at > now() - interval '5 minutes'`),
      statfs(config.MEDIA_ROOT).catch(() => null),
      (async () => {
        try {
          const files = (await readdir(config.BACKUP_DIR)).filter((f) => f.endsWith('.tar.gz')).sort().reverse();
          if (!files[0]) return { lastAt: null, lastSizeMb: 0, count: 0, ok: false };
          const s = await stat(join(config.BACKUP_DIR, files[0]!));
          return { lastAt: s.mtime.toISOString(), lastSizeMb: Math.round(s.size / 1048576 * 10) / 10, count: files.length, ok: true };
        } catch {
          return { lastAt: null, lastSizeMb: 0, count: 0, ok: false };
        }
      })(),
    ]);

    const totalGb = disk ? Math.round((disk.blocks * disk.bsize) / 1073741824) : 0;
    const freeGb = disk ? Math.round((disk.bavail * disk.bsize) / 1073741824) : 0;

    // 在线人数从 WS 统计拿（装饰在 fastify 上）
    const ws = (app as any).wsStats?.() ?? { connections: 0, couples: 0 };

    return {
      data: {
        onlineUsers: ws.connections,
        onlineCouples: ws.couples,
        recentlyActiveUsers: _online.rows[0]?.n ?? 0,
        activeCouples: counts.rows[0]?.active ?? 0,
        dissolvingCouples: counts.rows[0]?.dissolving ?? 0,
        archivedCouples: counts.rows[0]?.archived ?? 0,
        totalUsers: counts.rows[0]?.users ?? 0,
        eventsToday: events.rows[0]?.n ?? 0,
        // 容器/受限环境拿不到 statfs 时返回 null，前端据此隐藏磁盘卡片
        disk: disk ? { totalGb, freeGb, usedPercent: totalGb ? Math.round((1 - freeGb / totalGb) * 100) : 0 } : null,
        backup,
      },
    };
  });

  // ---------------- 审计日志 ----------------
  app.get('/api/admin/audit', guard, async (req) => {
    const q = z.object({ limit: z.coerce.number().min(1).max(200).default(50) }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));
    const { rows } = await pool.query(
      `SELECT a.id, a.action, a.target_type, a.target_id, a.detail, a.ip, a.created_at,
              u.nickname AS admin_nickname
         FROM admin_audit_log a LEFT JOIN users u ON u.id = a.admin_id
        ORDER BY a.created_at DESC LIMIT $1`,
      [q.data.limit],
    );
    return { data: rows };
  });
}
