import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { verifyAccessToken } from '../../auth.js';
import { Validation, zodIssues } from '../../errors.js';
import { authenticate, currentCoupleId, me } from '../../middleware/auth.js';
import { recentEventsFor, subscribeEvents } from '../../events.js';
import { pool } from '../../db.js';

/**
 * WebSocket 实时通道
 * ① 连接后 10s 内必须 auth
 * ② 按 coupleId 进房间
 * ③ 30s 服务端 ping，客户端无 pong 视为半死连接
 */
export default async function wsRoutes(app: FastifyInstance) {
  const rooms = new Map<string, Set<any>>();
  const online = new Map<string, Set<string>>(); // coupleId -> userIds

  const unsubscribe = subscribeEvents((coupleId, event) => {
    const set = rooms.get(coupleId);
    if (!set) return;
    const msg = JSON.stringify(event);
    for (const socket of set) {
      if (socket.readyState === 1) socket.send(msg);
    }
  });
  app.addHook('onClose', async () => unsubscribe());

  app.get('/api/ws', { websocket: true }, (socket, req) => {
    let coupleId: string | null = null;
    let userId: string | null = null;
    let alive = true;

    const authTimer = setTimeout(() => {
      if (!coupleId) {
        try { socket.close(4001, 'auth timeout'); } catch { /* ignore */ }
      }
    }, 10_000);

    socket.on('message', async (raw: Buffer) => {
      let msg: any;
      try { msg = JSON.parse(raw.toString()); } catch { return; }

      if (msg.type === 'auth') {
        try {
          const claims = await verifyAccessToken(String(msg.token));
          if (!claims.coupleId) { socket.close(4003, 'not paired'); return; }
          coupleId = claims.coupleId;
          userId = claims.sub;
          clearTimeout(authTimer);

          const set = rooms.get(coupleId) ?? new Set();
          set.add(socket);
          rooms.set(coupleId, set);

          const users = online.get(coupleId) ?? new Set<string>();
          users.add(userId);
          online.set(coupleId, users);

          socket.send(JSON.stringify({ type: 'ready', coupleId, cursor: await currentCursor(coupleId) }));
          req.log.info({ coupleId, userId }, 'ws ready');
        } catch {
          try { socket.close(4001, 'unauthorized'); } catch { /* ignore */ }
        }
        return;
      }

      if (msg.type === 'ping') {
        alive = true;
        socket.send(JSON.stringify({ type: 'pong', t: Date.now() }));
        return;
      }
    });

    socket.on('pong', () => { alive = true; });

    const hb = setInterval(() => {
      if (!alive) {
        req.log.warn({ coupleId }, 'ws heartbeat lost, terminating');
        try { socket.terminate(); } catch { /* ignore */ }
        return;
      }
      alive = false;
      try { socket.ping(); } catch { /* ignore */ }
    }, 30_000);

    socket.on('close', () => {
      clearTimeout(authTimer);
      clearInterval(hb);
      if (coupleId) {
        rooms.get(coupleId)?.delete(socket);
        online.get(coupleId)?.delete(userId!);
      }
    });

    socket.on('error', () => {
      clearTimeout(authTimer);
      clearInterval(hb);
    });
  });

  // 供超管查看在线数
  app.decorate('wsStats', () => ({
    connections: [...rooms.values()].reduce((n, s) => n + s.size, 0),
    couples: rooms.size,
  }));
}

async function currentCursor(coupleId: string): Promise<string> {
  const { rows } = await pool.query(
    'SELECT COALESCE(MAX(id), 0) AS id FROM sync_events WHERE couple_id = $1',
    [coupleId],
  );
  return String(rows[0]?.id ?? 0);
}

/** HTTP 降级通道：按 cursor 拉增量事件 */
export async function syncRoutes(app: FastifyInstance) {
  app.get('/api/sync/events', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    const q = z.object({ since: z.coerce.number().int().min(0).default(0) }).safeParse(req.query);
    if (!q.success) throw new Validation(zodIssues(q.error));
    const events = await recentEventsFor(coupleId, q.data.since, 200);
    return { data: events, cursor: events.at(-1)?.id ?? String(q.data.since) };
  });

  app.get('/api/sync/cursor', { preHandler: authenticate }, async (req) => {
    const coupleId = currentCoupleId(req);
    return { data: { cursor: await currentCursor(coupleId) } };
  });
}
