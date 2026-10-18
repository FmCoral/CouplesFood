import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool, withTx } from '../../db.js';
import { newInviteCode } from '../../auth.js';
import { Conflict, Forbidden, NotFound, Validation, zodIssues } from '../../errors.js';
import { authenticate, currentCoupleId, me, requireNotAdmin } from '../../middleware/auth.js';
import { broadcast, emitInTx, type SyncEvent } from '../../events.js';
import { initCoupleCategories } from '../../shared/presets.js';
import { issueTokensFor } from '../../shared/tokens.js';
import { clearFailures, isLocked, recordFailure } from '../../shared/rate-limit.js';

const INVITE_TTL_HOURS = 24;
const MAX_INVITE_FAILS = 5;
const INVITE_LOCK_MS = 60 * 60 * 1000;

export default async function coupleRoutes(app: FastifyInstance) {
  // ---------------- 生成邀请码 ----------------
  app.post('/api/couples/invite', { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
    const u = me(req);

    // 一次事务里按顺序处理三种情况，简单直白、行为可预测：
    // 1) 已有 active/dissolving → 409
    // 2) 已有未过期的 pending → 复用
    // 3) 其余一律作废后新建（含过期 pending，否则 uq_couples_a_live 会挡住 INSERT）
    const out = await withTx(async (c) => {
      const live = await c.query(
        `SELECT id, status, invite_code, invite_expires FROM couples
          WHERE status <> 'dissolved' AND (member_a = $1 OR member_b = $1) LIMIT 1`,
        [u.userId],
      );
      const cur = live.rows[0];
      if (cur && cur.status !== 'pending') throw new Conflict('你已经在关系中');
      if (cur && new Date(cur.invite_expires) > new Date()) {
        return { inviteCode: cur.invite_code as string, expiresAt: cur.invite_expires, reused: true };
      }
      if (cur) {
        await c.query(
          `UPDATE couples SET status = 'dissolved', dissolved_at = now(), dissolved_reason = 'expired'
            WHERE id = $1`,
          [cur.id],
        );
      }

      // 邀请码唯一：极小概率撞码时重试
      for (let attempt = 0; attempt < 6; attempt++) {
        try {
          const { rows } = await c.query(
            `INSERT INTO couples (invite_code, invite_expires, member_a, status)
             VALUES ($1, now() + ($2 || ' hours')::interval, $3, 'pending')
             RETURNING invite_code, invite_expires`,
            [newInviteCode(), INVITE_TTL_HOURS, u.userId],
          );
          return { inviteCode: rows[0].invite_code as string, expiresAt: rows[0].invite_expires, reused: false };
        } catch (e: any) {
          if (e?.code !== '23505') throw e;
        }
      }
      throw new Conflict('邀请码生成失败，请重试');
    });

    return { data: out };
  });

  // ---------------- 加入 ----------------
  app.post('/api/couples/join', { preHandler: [authenticate, requireNotAdmin] }, async (req) => {
    const parsed = z.object({
      inviteCode: z.string().length(6, '邀请码是 6 位'),
      deviceId: z.string().min(4).max(80),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const u = me(req);
    const { inviteCode, deviceId } = parsed.data;

    // 设备维度锁定：连错 5 次锁 1 小时（防手滑 + 防扫号）
    const lock = isLocked(`join:${deviceId}`);
    if (lock.locked) {
      throw new Conflict(`输错次数过多，请 ${Math.ceil(lock.remainingMs / 60000)} 分钟后再试`);
    }

    const result = await withTx(async (c) => {
      const events: SyncEvent[] = [];

      const { rows } = await c.query(
        `SELECT * FROM couples
          WHERE invite_code = $1 AND status = 'pending' AND invite_expires > now()
          FOR UPDATE`,
        [inviteCode],
      );
      const cp = rows[0];
      if (!cp) {
        recordFailure(`join:${deviceId}`, MAX_INVITE_FAILS, INVITE_LOCK_MS);
        await c.query(`INSERT INTO invite_attempts (device_id, code_tried, success) VALUES ($1,$2,false)`, [deviceId, inviteCode]);
        throw new Conflict('邀请码无效或已过期');
      }
      if (cp.member_a === u.userId) throw new Conflict('不能和自己绑定');

      // B 自己不能已在别的关系里
      const other = await c.query(
        `SELECT 1 FROM couples WHERE status <> 'dissolved' AND (member_a = $1 OR member_b = $1) FOR UPDATE`,
        [u.userId],
      );
      if (other.rowCount) throw new Conflict('你已经在另一段关系中，请先处理');

      await c.query(
        `UPDATE couples
            SET member_b = $1, status = 'active', bound_at = now(), version = version + 1
          WHERE id = $2`,
        [u.userId, cp.id],
      );
      // A 若有其他 pending 的，作废
      await c.query(
        `UPDATE couples SET status = 'dissolved', dissolved_at = now(), dissolved_reason = 'superseded'
          WHERE member_a = $1 AND status = 'pending' AND id <> $2`,
        [cp.member_a, cp.id],
      );
      await c.query(
        `INSERT INTO couple_members (couple_id, user_id) VALUES ($1,$2), ($1,$3)
         ON CONFLICT DO NOTHING`,
        [cp.id, cp.member_a, u.userId],
      );
      await initCoupleCategories(c, cp.id);
      await c.query(`INSERT INTO invite_attempts (device_id, code_tried, success) VALUES ($1,$2,true)`, [deviceId, inviteCode]);

      events.push(await emitInTx(c, {
        coupleId: cp.id,
        actorId: u.userId,
        type: 'couple.bound',
        entityType: 'couple',
        entityId: cp.id,
        payload: { partnerId: cp.member_a },
      }));

      return { coupleId: cp.id as string, partnerId: cp.member_a as string, events };
    });

    clearFailures(`join:${deviceId}`);
    // 提交后再广播，避免回滚了还推
    broadcast(result.coupleId, result.events);

    // 关键：B 的 token 必须换发，否则 coupleId 仍是 null
    const tokens = await issueTokensFor(u.userId, result.coupleId, false, deviceId);
    return { data: { coupleId: result.coupleId, partnerId: result.partnerId, ...tokens } };
  });

  // ---------------- 我的关系 ----------------
  app.get('/api/couples/me', { preHandler: authenticate }, async (req) => {
    const u = me(req);
    const { rows } = await pool.query(
      `SELECT c.id, c.status, c.version, c.bound_at,
              cm_me.role_label AS my_role,
              cm_them.role_label AS partner_role,
              p.id AS partner_id, p.nickname AS partner_nickname, p.avatar_url AS partner_avatar,
              d.id AS dissolution_id, d.initiated_by AS dissolution_by, d.created_at AS dissolution_at
         FROM couples c
         JOIN couple_members cm_me   ON cm_me.couple_id = c.id AND cm_me.user_id = $1
         LEFT JOIN users p           ON p.id = CASE WHEN c.member_a = $1 THEN c.member_b ELSE c.member_a END
         LEFT JOIN couple_members cm_them ON cm_them.couple_id = c.id AND cm_them.user_id = p.id
         LEFT JOIN dissolution_requests d ON d.couple_id = c.id AND d.status = 'pending'
        WHERE c.status <> 'dissolved' AND (c.member_a = $1 OR c.member_b = $1)
        LIMIT 1`,
      [u.userId],
    );
    const r = rows[0];
    if (!r) return { data: null };

    return {
      data: {
        coupleId: r.id,
        status: r.status,
        version: r.version,
        boundAt: r.bound_at,
        partner: r.partner_id
          ? { id: r.partner_id, nickname: r.partner_nickname, avatarUrl: r.partner_avatar, roleLabel: r.partner_role }
          : null,
        myRoleLabel: r.my_role,
        dissolution: r.dissolution_id
          ? { requestId: r.dissolution_id, initiatedBy: r.dissolution_by, createdAt: r.dissolution_at }
          : null,
      },
    };
  });

  // ---------------- 修改关系内称呼 ----------------
  app.patch('/api/couples/role', { preHandler: authenticate }, async (req) => {
    const parsed = z.object({ roleLabel: z.string().max(12).nullable() }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const coupleId = currentCoupleId(req);
    const u = me(req);
    await pool.query(
      `UPDATE couple_members SET role_label = $1 WHERE couple_id = $2 AND user_id = $3`,
      [parsed.data.roleLabel, coupleId, u.userId],
    );
    return { data: { ok: true } };
  });

  // ================= 解散流程 =================

  /** A 发起解散 */
  app.post('/api/couples/dissolve/request', { preHandler: authenticate }, async (req) => {
    const parsed = z.object({ reason: z.string().max(200).optional() }).safeParse(req.body ?? {});
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const coupleId = currentCoupleId(req);
    const u = me(req);

    const result = await withTx(async (c) => {
      const cur = await c.query('SELECT status FROM couples WHERE id = $1 FOR UPDATE', [coupleId]);
      if (cur.rows[0]?.status !== 'active') throw new Conflict('当前状态不能申请解散');

      const dup = await c.query(`SELECT 1 FROM dissolution_requests WHERE couple_id = $1 AND status = 'pending'`, [coupleId]);
      if (dup.rowCount) throw new Conflict('已有待处理的解散申请');

      const { rows } = await c.query(
        `INSERT INTO dissolution_requests (couple_id, initiated_by, reason)
         VALUES ($1,$2,$3) RETURNING id, status, created_at`,
        [coupleId, u.userId, parsed.data.reason ?? null],
      );
      // 冻结为只读
      await c.query(`UPDATE couples SET status = 'dissolving', version = version + 1 WHERE id = $1`, [coupleId]);

      const evt = await emitInTx(c, {
        coupleId, actorId: u.userId, type: 'couple.dissolving',
        entityType: 'couple', entityId: coupleId,
        payload: { requestId: rows[0].id, initiatedBy: u.userId, reason: parsed.data.reason ?? null },
      });
      return { request: rows[0], events: [evt] };
    });

    broadcast(coupleId, result.events);
    return { data: { requestId: result.request.id, status: 'pending', coupleStatus: 'dissolving' } };
  });

  /** B 同意 → 立即解散 */
  app.post('/api/couples/dissolve/:requestId/approve', { preHandler: authenticate }, async (req) => {
    const { requestId } = z.object({ requestId: z.string().uuid() }).parse(req.params);
    const u = me(req);

    const result = await withTx(async (c) => {
      const q = await c.query(
        `SELECT d.*, c.member_a, c.member_b FROM dissolution_requests d
           JOIN couples c ON c.id = d.couple_id
          WHERE d.id = $1 AND d.status = 'pending' FOR UPDATE OF d`,
        [requestId],
      );
      const d = q.rows[0];
      if (!d) throw new NotFound();
      if (d.couple_id !== currentCoupleId(req)) throw new NotFound();
      if (d.initiated_by === u.userId) throw new Forbidden('发起人不能批准自己的申请');

      await c.query(
        `UPDATE dissolution_requests SET status = 'approved', resolved_by = $1, resolved_at = now() WHERE id = $2`,
        [u.userId, requestId],
      );
      await c.query(
        `UPDATE couples SET status = 'dissolved', dissolved_at = now(), dissolved_by = $1,
                dissolved_reason = 'mutual', version = version + 1 WHERE id = $2`,
        [u.userId, d.couple_id],
      );
      const evt = await emitInTx(c, {
        coupleId: d.couple_id, actorId: u.userId, type: 'couple.dissolved',
        entityType: 'couple', entityId: d.couple_id, payload: { reason: 'mutual' },
      });
      return { coupleId: d.couple_id as string, events: [evt] };
    });

    broadcast(result.coupleId, result.events);
    return { data: { coupleStatus: 'dissolved', dissolvedAt: new Date().toISOString() } };
  });

  /** B 拒绝 → 回到 active */
  app.post('/api/couples/dissolve/:requestId/reject', { preHandler: authenticate }, async (req) => {
    const { requestId } = z.object({ requestId: z.string().uuid() }).parse(req.params);
    const u = me(req);

    const result = await withTx(async (c) => {
      const q = await c.query(
        `SELECT * FROM dissolution_requests WHERE id = $1 AND status = 'pending' FOR UPDATE`,
        [requestId],
      );
      const d = q.rows[0];
      if (!d || d.couple_id !== currentCoupleId(req)) throw new NotFound();
      if (d.initiated_by === u.userId) throw new Forbidden('发起人不能拒绝自己的申请，请使用撤回');

      await c.query(
        `UPDATE dissolution_requests SET status = 'rejected', resolved_by = $1, resolved_at = now() WHERE id = $2`,
        [u.userId, requestId],
      );
      await c.query(`UPDATE couples SET status = 'active', version = version + 1 WHERE id = $1`, [d.couple_id]);
      const evt = await emitInTx(c, {
        coupleId: d.couple_id, actorId: u.userId, type: 'couple.dissolve_rejected',
        entityType: 'couple', entityId: d.couple_id, payload: { requestId },
      });
      return { coupleId: d.couple_id as string, events: [evt] };
    });

    broadcast(result.coupleId, result.events);
    return { data: { coupleStatus: 'active' } };
  });

  /** A 撤回 */
  app.post('/api/couples/dissolve/:requestId/withdraw', { preHandler: authenticate }, async (req) => {
    const { requestId } = z.object({ requestId: z.string().uuid() }).parse(req.params);
    const u = me(req);

    const result = await withTx(async (c) => {
      const q = await c.query(
        `SELECT * FROM dissolution_requests WHERE id = $1 AND status = 'pending' FOR UPDATE`,
        [requestId],
      );
      const d = q.rows[0];
      if (!d || d.couple_id !== currentCoupleId(req)) throw new NotFound();
      if (d.initiated_by !== u.userId) throw new Forbidden('只有发起人可以撤回');

      await c.query(
        `UPDATE dissolution_requests SET status = 'withdrawn', resolved_by = $1, resolved_at = now() WHERE id = $2`,
        [u.userId, requestId],
      );
      await c.query(`UPDATE couples SET status = 'active', version = version + 1 WHERE id = $1`, [d.couple_id]);
      const evt = await emitInTx(c, {
        coupleId: d.couple_id, actorId: u.userId, type: 'couple.dissolve_withdrawn',
        entityType: 'couple', entityId: d.couple_id, payload: { requestId },
      });
      return { coupleId: d.couple_id as string, events: [evt] };
    });

    broadcast(result.coupleId, result.events);
    return { data: { status: 'withdrawn', coupleStatus: 'active' } };
  });
}
