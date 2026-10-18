import type { FastifyReply, FastifyRequest } from 'fastify';
import type { Db } from '../db.js';
import { verifyAccessToken } from '../auth.js';
import { Forbidden, NotFound, Unauthorized } from '../errors.js';

export interface RequestUser {
  userId: string;
  coupleId: string | null;
  isAdmin: boolean;
}

declare module 'fastify' {
  interface FastifyRequest {
    auth?: RequestUser;
  }
}

export async function authenticate(req: FastifyRequest, _reply: FastifyReply) {
  const header = req.headers.authorization;
  if (!header?.startsWith('Bearer ')) throw new Unauthorized('缺少访问令牌');
  const claims = await verifyAccessToken(header.slice(7));
  req.auth = { userId: claims.sub, coupleId: claims.coupleId, isAdmin: claims.adm };
}

export function me(req: FastifyRequest): RequestUser {
  if (!req.auth) throw new Unauthorized();
  return req.auth;
}

/**
 * 拿到当前 coupleId。
 * 这是全系统唯一的关系入口——所有业务查询都必须从这里取 coupleId。
 */
export function currentCoupleId(req: FastifyRequest): string {
  const u = me(req);
  if (!u.coupleId) throw new Forbidden('还没有绑定关系，请先完成配对');
  return u.coupleId;
}

/**
 * 超管不可参与情侣业务。
 * 注意：钩子必须声明为 async —— Fastify 的 hook 链只在钩子返回 Promise/thenable 时才继续推进，
 * 同步钩子会让请求在 preHandler 阶段静默挂起（不报错、不超时）。
 */
export async function requireNotAdmin(req: FastifyRequest) {
  if (me(req).isAdmin) throw new Forbidden('管理员账号不能参与情侣空间操作');
}

/** 超管专用守卫；同时把动作写审计日志 */
export async function requireAdmin(req: FastifyRequest, _reply: FastifyReply) {
  const u = me(req);
  if (!u.isAdmin) throw new Forbidden('需要管理员权限');
}

/**
 * 二次校验：某实体是否属于当前 couple。
 * 不属于 → 抛 404（不泄露存在性）。
 */
export async function assertOwned(
  db: Db,
  table: 'dishes' | 'orders' | 'dish_types' | 'dish_flavors',
  id: string,
  coupleId: string,
): Promise<void> {
  const { rowCount } = await db.query(`SELECT 1 FROM ${table} WHERE id = $1 AND couple_id = $2`, [id, coupleId]);
  if (!rowCount) throw new NotFound();
}
