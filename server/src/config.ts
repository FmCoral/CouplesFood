import { z } from 'zod';
import { existsSync, readFileSync } from 'node:fs';

/** 极简 .env 读取（不引依赖）；真实环境变量优先 */
function readDotEnv(file = '.env'): Record<string, string> {
  if (!existsSync(file)) return {};
  return Object.fromEntries(
    readFileSync(file, 'utf8')
      .split('\n')
      .filter((l) => l.trim() && !l.trim().startsWith('#') && l.includes('='))
      .map((l) => {
        const i = l.indexOf('=');
        return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')];
      }),
  );
}

const schema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: z.coerce.number().default(3000),
  HOST: z.string().default('127.0.0.1'),

  DATABASE_URL: z.string().min(1),

  JWT_SECRET: z.string().min(32, 'JWT_SECRET 至少 32 位'),
  JWT_ISSUER: z.string().default('couple-menu'),
  ACCESS_TTL_SEC: z.coerce.number().default(900),
  REFRESH_TTL_DAYS: z.coerce.number().default(30),

  ADMIN_PHONE: z.string().regex(/^1[3-9]\d{9}$/),
  ADMIN_PASSWORD: z.string().min(8),
  ADMIN_NICKNAME: z.string().default('管理员'),

  MEDIA_ROOT: z.string().default('/data/couple/images'),
  MEDIA_BASE_PATH: z.string().default('/media'),
  // 只填域名，如 https://food.fmcoral.com；留空则返回相对路径。
  // 填成 https://xxx.com/media 会和 MEDIA_BASE_PATH 拼成 /media/media/ 导致图片 404。
  MEDIA_BASE_URL: z
    .string()
    .default('')
    .refine((v) => !v.endsWith('/media') && !v.endsWith('/media/'), {
      message: 'MEDIA_BASE_URL 只填域名（如 https://food.fmcoral.com），不要带 /media —— 路径前缀由 MEDIA_BASE_PATH 负责',
    }),
  MAX_UPLOAD_MB: z.coerce.number().default(5),

  BACKUP_DIR: z.string().default('/data/couple/backup'),
  BACKUP_KEEP: z.coerce.number().default(3),

  CORS_ORIGINS: z.string().default(''),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  TRUST_PROXY: z.string().default('true'),
});

function load() {
  const merged = { ...readDotEnv(), ...process.env };
  const parsed = schema.safeParse(merged);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `  · ${i.path.join('.')}: ${i.message}`).join('\n');
    // fail fast：配置不全不要带病启动
    throw new Error(`配置校验失败：\n${issues}`);
  }
  const env = parsed.data;
  return {
    ...env,
    isProd: env.NODE_ENV === 'production',
    corsOrigins: env.CORS_ORIGINS.split(',').map((s) => s.trim()).filter(Boolean),
    trustProxy: env.TRUST_PROXY !== 'false',
    maxUploadBytes: env.MAX_UPLOAD_MB * 1024 * 1024,
  } as const;
}

export const config = load();
export type Config = typeof config;
