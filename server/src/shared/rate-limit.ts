/**
 * 极简内存限流 + 按设备/手机号的失败锁定。
 * 单机、5 个用户 —— Redis 是纯负债。多实例时再换。
 */

interface Window { count: number; resetAt: number }
const buckets = new Map<string, Window>();

export function hit(key: string, limit: number, windowMs: number): { ok: boolean; retryAfter: number } {
  const now = Date.now();
  const cur = buckets.get(key);
  if (!cur || cur.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowMs });
    return { ok: true, retryAfter: 0 };
  }
  cur.count += 1;
  if (cur.count > limit) return { ok: false, retryAfter: Math.ceil((cur.resetAt - now) / 1000) };
  return { ok: true, retryAfter: 0 };
}

// 周期性清理，避免 Map 无限增长（1 小时清一次，5 个用户根本不会有大 Map）
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of buckets) if (v.resetAt <= now) buckets.delete(k);
}, 3_600_000).unref();

/** 滑动失败计数（用于邀请码锁定） */
const failures = new Map<string, { count: number; lockedUntil: number }>();

export function recordFailure(key: string, threshold: number, lockMs: number) {
  const cur = failures.get(key) ?? { count: 0, lockedUntil: 0 };
  cur.count += 1;
  if (cur.count >= threshold) {
    cur.lockedUntil = Date.now() + lockMs;
    cur.count = 0;
  }
  failures.set(key, cur);
}

export function isLocked(key: string): { locked: boolean; remainingMs: number } {
  const cur = failures.get(key);
  if (!cur || cur.lockedUntil <= Date.now()) return { locked: false, remainingMs: 0 };
  return { locked: true, remainingMs: cur.lockedUntil - Date.now() };
}

export function clearFailures(key: string) {
  failures.delete(key);
}
