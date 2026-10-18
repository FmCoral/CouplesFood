import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { pool } from '../../db.js';
import {
  hashPassword, verifyPassword, signAccessToken, newRefreshToken, sha256,
} from '../../auth.js';
import { config } from '../../config.js';
import { Conflict, Unauthorized, Validation, zodIssues } from '../../errors.js';
import { authenticate, me } from '../../middleware/auth.js';
import { hit } from '../../shared/rate-limit.js';

const phoneSchema = z.string().regex(/^1[3-9]\d{9}$/, '手机号格式不正确');
const passwordSchema = z.string().min(8, '密码至少 8 位').max(64, '密码最多 64 位');

async function issueTokens(userId: string, coupleId: string | null, isAdmin: boolean, deviceId: string) {
  const { plain, hash } = newRefreshToken();
  const expiresAt = new Date(Date.now() + config.REFRESH_TTL_DAYS * 86_400_000);
  await pool.query(
    `INSERT INTO refresh_tokens (user_id, token_hash, device_id, expires_at) VALUES ($1,$2,$3,$4)`,
    [userId, hash, deviceId, expiresAt],
  );
  return {
    accessToken: await signAccessToken({ sub: userId, coupleId, adm: isAdmin }),
    refreshToken: plain,
    expiresIn: config.ACCESS_TTL_SEC,
    isAdmin,
  };
}

/** 查用户当前 active/dissolving 的关系（dissolved 不算） */
export async function liveCoupleOf(userId: string): Promise<{ coupleId: string | null; status: string | null }> {
  const { rows } = await pool.query(
    `SELECT id, status FROM couples
      WHERE status IN ('active','dissolving') AND (member_a = $1 OR member_b = $1)
      LIMIT 1`,
    [userId],
  );
  const r = rows[0];
  return { coupleId: r?.id ?? null, status: r?.status ?? null };
}

export default async function authRoutes(app: FastifyInstance) {
  // ---------------- 注册 ----------------
  app.post('/api/auth/register', async (req, reply) => {
    const ip = req.ip;
    const limit = hit(`reg:${ip}`, 10, 60_000);
    if (!limit.ok) return reply.code(429).send({ type: 'about:blank', title: 'RATE_LIMITED', status: 429, detail: '注册太频繁', request_id: req.id });

    const parsed = z.object({
      phone: phoneSchema,
      password: passwordSchema,
      nickname: z.string().min(1, '昵称不能为空').max(20, '昵称最多 20 字'),
      deviceId: z.string().min(4, 'deviceId 至少 4 位').max(80),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const { phone, password, nickname, deviceId } = parsed.data;

    const dup = await pool.query('SELECT 1 FROM users WHERE phone = $1', [phone]);
    if (dup.rowCount) throw new Conflict('该手机号已注册');

    const { rows } = await pool.query(
      `INSERT INTO users (phone, password_hash, nickname) VALUES ($1,$2,$3) RETURNING id, is_admin`,
      [phone, await hashPassword(password), nickname],
    );
    const user = rows[0];
    const tokens = await issueTokens(user.id, null, user.is_admin, deviceId);
    reply.code(200);
    return { data: { userId: user.id, ...tokens } };
  });

  // ---------------- 登录 ----------------
  app.post('/api/auth/login', async (req) => {
    const parsed = z.object({
      phone: phoneSchema,
      password: z.string().min(1),
      deviceId: z.string().min(4).max(80),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const { phone, password, deviceId } = parsed.data;

    const rl = hit(`login:${phone}`, phone === config.ADMIN_PHONE ? 5 : 8, 60_000);
    if (!rl.ok) throw new (await import('../../errors.js')).RateLimited('尝试次数过多，请稍后再试');

    const { rows } = await pool.query(
      `SELECT id, password_hash, is_admin, is_active FROM users WHERE phone = $1`,
      [phone],
    );
    const user = rows[0];
    // 统一文案，不区分「用户不存在」与「密码错」，防手机号枚举
    if (!user || !(await verifyPassword(password, user.password_hash))) {
      throw new Unauthorized('手机号或密码不正确');
    }
    if (!user.is_active) throw new Unauthorized('账号已被停用');

    await pool.query('UPDATE users SET last_seen_at = now() WHERE id = $1', [user.id]);

    const live = await liveCoupleOf(user.id);
    return { data: { userId: user.id, ...(await issueTokens(user.id, live.coupleId, user.is_admin, deviceId)) } };
  });

  // ---------------- 刷新 ----------------
  app.post('/api/auth/refresh', async (req) => {
    const parsed = z.object({ refreshToken: z.string().min(10) }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));

    const hash = sha256(parsed.data.refreshToken);
    const { rows } = await pool.query(
      `SELECT id, user_id, device_id FROM refresh_tokens
        WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > now()`,
      [hash],
    );
    const rec = rows[0];
    if (!rec) throw new Unauthorized('刷新令牌无效，请重新登录');

    // 轮换：旧的立刻作废，防重放
    await pool.query('UPDATE refresh_tokens SET revoked_at = now() WHERE id = $1', [rec.id]);

    const u = await pool.query('SELECT is_admin FROM users WHERE id = $1', [rec.user_id]);
    const live = await liveCoupleOf(rec.user_id);
    return {
      data: await issueTokens(rec.user_id, live.coupleId, u.rows[0]?.is_admin === true, rec.device_id),
    };
  });

  // ---------------- 登出 ----------------
  app.post('/api/auth/logout', { preHandler: authenticate }, async (req) => {
    const u = me(req);
    await pool.query(
      `UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`,
      [u.userId],
    );
    return { data: { ok: true } };
  });

  // ---------------- 修改密码 ----------------
  app.post('/api/auth/change-password', { preHandler: authenticate }, async (req) => {
    const parsed = z.object({
      oldPassword: z.string().min(1),
      newPassword: passwordSchema,
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const u = me(req);

    const { rows } = await pool.query('SELECT password_hash FROM users WHERE id = $1', [u.userId]);
    if (!rows[0] || !(await verifyPassword(parsed.data.oldPassword, rows[0].password_hash))) {
      throw new Unauthorized('原密码不正确');
    }
    await pool.query('UPDATE users SET password_hash = $1 WHERE id = $2', [
      await hashPassword(parsed.data.newPassword),
      u.userId,
    ]);
    // 改密后踢掉所有其他设备
    await pool.query(
      `UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL`,
      [u.userId],
    );
    return { data: { ok: true, reloginRequired: true } };
  });

  // ---------------- 修改昵称 ----------------
  // 不做短信验证，改昵称是低风险操作；但手机号不可改（它是登录凭据）
  app.patch('/api/auth/me', { preHandler: authenticate }, async (req) => {
    const parsed = z.object({
      nickname: z.string().trim().min(1, '昵称不能为空').max(20, '昵称最多 20 字'),
    }).safeParse(req.body);
    if (!parsed.success) throw new Validation(zodIssues(parsed.error));
    const u = me(req);
    await pool.query('UPDATE users SET nickname = $1 WHERE id = $2', [parsed.data.nickname, u.userId]);
    return { data: { nickname: parsed.data.nickname } };
  });

  // ---------------- 当前用户 ----------------
  app.get('/api/auth/me', { preHandler: authenticate }, async (req) => {
    const u = me(req);
    const { rows } = await pool.query(
      `SELECT id, phone, nickname, avatar_url, is_admin, created_at FROM users WHERE id = $1`,
      [u.userId],
    );
    const r = rows[0];
    if (!r) throw new Unauthorized();
    return {
      data: {
        id: r.id,
        phone: r.phone.replace(/^(\d{3})\d{4}(\d{4})$/, '$1****$2'),
        nickname: r.nickname,
        avatarUrl: r.avatar_url,
        isAdmin: r.is_admin,
        coupleId: u.coupleId,
        createdAt: r.created_at,
      },
    };
  });
}
