import type pg from 'pg';
import { pool } from './db.js';

/**
 * 事件总线：写操作产生事件 → 推给 WS 房间 + 落库作 cursor
 * 单机用进程内 EventEmitter 语义即可；多实例时换成 Redis Pub/Sub，接口不变。
 */
export type SyncEvent = {
  id: string;          // bigint 以字符串传（避免 JS 精度问题）
  type: string;
  entityType: string;
  entityId: string;
  payload: Record<string, unknown>;
  version: number | null;
  createdAt: string;
};

type Listener = (coupleId: string, event: SyncEvent) => void;
const listeners = new Set<Listener>();

export function subscribeEvents(fn: Listener): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export interface EmitInput {
  coupleId: string;
  actorId: string | null;
  type: string;
  entityType: 'dish' | 'order' | 'couple' | 'dish_type' | 'dish_flavor';
  entityId: string;
  payload?: Record<string, unknown>;
  version?: number | null;
}

/** 在事务内追加事件，提交后推送。必须在 withTx 内部调用。 */
export async function emitInTx(client: pg.PoolClient, input: EmitInput): Promise<SyncEvent> {
  const { rows } = await client.query(
    `INSERT INTO sync_events (couple_id, actor_id, type, entity_type, entity_id, payload, version)
     VALUES ($1,$2,$3,$4,$5,$6,$7)
     RETURNING id, type, entity_type, entity_id, payload, version, created_at`,
    [
      input.coupleId,
      input.actorId,
      input.type,
      input.entityType,
      input.entityId,
      JSON.stringify(input.payload ?? {}),
      input.version ?? null,
    ],
  );
  const r = rows[0];
  return {
    id: String(r.id),
    type: r.type,
    entityType: r.entity_type,
    entityId: r.entity_id,
    payload: r.payload,
    version: r.version,
    createdAt: new Date(r.created_at).toISOString(),
  };
}

/** 事务提交之后再广播（避免回滚了还推给客户端） */
export function broadcast(coupleId: string, events: SyncEvent[]) {
  for (const evt of events) {
    for (const fn of listeners) fn(coupleId, evt);
  }
}

export async function recentEventsFor(coupleId: string, since: number, limit = 200) {
  const { rows } = await pool.query(
    `SELECT id, type, entity_type, entity_id, payload, version, created_at
       FROM sync_events WHERE couple_id = $1 AND id > $2 ORDER BY id ASC LIMIT $3`,
    [coupleId, since, limit],
  );
  return rows.map((r) => ({
    id: String(r.id),
    type: r.type,
    entityType: r.entity_type,
    entityId: r.entity_id,
    payload: r.payload,
    version: r.version,
    createdAt: new Date(r.created_at).toISOString(),
  })) satisfies SyncEvent[];
}
