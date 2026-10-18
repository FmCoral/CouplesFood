import Fastify from 'fastify';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import fastifyStatic from '@fastify/static';
import websocket from '@fastify/websocket';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { config } from './config.js';
import { AppError, BadRequest, problemBody } from './errors.js';
import { dbHealthy, pool } from './db.js';
import { ensureAdmin } from './shared/presets.js';
import { runMigrations } from './shared/migrate.js';
import authRoutes from './features/auth/routes.js';
import coupleRoutes from './features/couple/routes.js';
import dishRoutes from './features/dish/routes.js';
import { dishTypeRoutes, dishFlavorRoutes } from './features/dish/categories.js';
import orderRoutes from './features/order/routes.js';
import uploadRoutes from './features/sync/upload.js';
import wsRoutes, { syncRoutes } from './features/sync/ws.js';
import adminRoutes from './features/admin/routes.js';

mkdirSync(config.MEDIA_ROOT, { recursive: true });

const app = Fastify({
  logger: {
    level: config.LOG_LEVEL,
    formatters: { level: (label) => ({ level: label }) },
    // 敏感字段一律脱敏
    redact: {
      paths: [
        'req.headers.authorization',
        'req.headers.cookie',
        'req.body.password',
        'req.body.oldPassword',
        'req.body.newPassword',
        'req.body.refreshToken',
      ],
      censor: '[REDACTED]',
    },
    serializers: {
      req: (req) => ({ method: req.method, url: req.url, host: req.hostname }),
      res: (res) => ({ statusCode: res.statusCode }),
    },
  },
  genReqId: (req) => (req.headers['x-request-id'] as string) ?? randomUUID(),
  trustProxy: config.trustProxy,
  bodyLimit: 1_000_000,
  disableRequestLogging: false,
});

// ---------- 中间件顺序：requestId → 日志 → CORS → 限流 → 鉴权 → 校验 → 业务 ----------
await app.register(cors, {
  origin: config.corsOrigins.length ? config.corsOrigins : false,
  credentials: false,
  allowedHeaders: ['Content-Type', 'Authorization', 'X-Request-Id'],
});
await app.register(multipart, { limits: { fileSize: config.maxUploadBytes, files: 1, fields: 5 } });
await app.register(websocket, { options: { maxPayload: 64 * 1024 } });

// 兼容旧客户端（v1.0.1 及更早）：POST 声明了 application/json 却没带 body。
// Fastify 默认会抛 FST_ERR_CTP_EMPTY_JSON_BODY → 400「请求体格式错误」，
// 挡住所有无 body 的写接口：/couples/invite、/auth/logout、
// /couples/dissolve/:id/{approve,reject,withdraw}。
// 空 body 一律按 {} 处理；真正缺字段的接口交给 zod 返回 422，提示更明确。
app.removeContentTypeParser('application/json');
app.addContentTypeParser('application/json', { parseAs: 'string' }, (_req, body, done) => {
  const raw = body == null ? '' : String(body);
  if (raw.trim() === '') return done(null, {});
  try {
    done(null, JSON.parse(raw) as unknown);
  } catch {
    done(new BadRequest('请求体格式错误'), undefined);
  }
});

// 图片静态服务：文件名是 UUID，内容不变 → 长缓存
await app.register(fastifyStatic, {
  root: config.MEDIA_ROOT,
  prefix: `${config.MEDIA_BASE_PATH}/`,
  cacheControl: true,
  maxAge: '365d',
  immutable: true,
  index: false,
  list: false,
});

app.addHook('onRequest', async (req, reply) => {
  reply.header('X-Request-Id', String(req.id));
  reply.header('X-Content-Type-Options', 'nosniff');
  reply.header('Referrer-Policy', 'no-referrer');
});

// ---------- 错误处理 ----------
app.setErrorHandler((_err, req, reply) => {
  const err = _err as any;

  if (err instanceof AppError) {
    if (err.statusCode >= 500) req.log.error({ code: err.code, path: req.url }, err.message);
    else req.log.warn({ code: err.code, path: req.url }, err.message);
    return reply.code(err.statusCode).send(problemBody(err, String(req.id)));
  }

  // zod 的 .parse() 直接抛 ZodError：统一转成 422，避免落到 500
  if (err?.name === 'ZodError' || Array.isArray(err?.issues)) {
    return reply.code(422).send(
      problemBody(new AppError('VALIDATION_ERROR', '参数校验失败', 422, err.issues ?? err.message), String(req.id)),
    );
  }

  // Fastify 自带校验（当前未用 schema，但保留兜底）
  if (err.validation) {
    return reply.code(422).send(problemBody(new AppError('VALIDATION_ERROR', '参数校验失败', 422, err.validation), String(req.id)));
  }
  if (err.statusCode === 413) {
    return reply.code(413).send(problemBody(new AppError('BAD_REQUEST', `文件超过 ${config.MAX_UPLOAD_MB}MB`, 413), String(req.id)));
  }
  if (err.code === 'FST_REQ_FILE_TOO_LARGE') {
    return reply.code(413).send(problemBody(new AppError('BAD_REQUEST', `文件超过 ${config.MAX_UPLOAD_MB}MB`, 413), String(req.id)));
  }
  // 请求体解析失败（空 body + JSON header 等）
  if (err.code === 'FST_ERR_CTP_EMPTY_JSON_BODY' || err.code === 'FST_ERR_CTP_INVALID_MEDIA_TYPE' || err.code === 'FST_ERR_CTP_INVALID_JSON_BODY') {
    return reply.code(400).send(problemBody(new AppError('BAD_REQUEST', '请求体格式错误', 400), String(req.id)));
  }

  req.log.error({ err: err.message, stack: err.stack, path: req.url }, 'unhandled error');
  return reply.code(500).send(problemBody(new AppError('INTERNAL_ERROR', '服务开小差了，请稍后再试', 500), String(req.id)));
});

app.setNotFoundHandler((req, reply) => {
  reply.code(404).send(
    problemBody(new AppError('NOT_FOUND', `路由不存在: ${req.method} ${req.url}`, 404), String(req.id)),
  );
});

// ---------- 健康检查（无需认证） ----------
app.get('/api/health', async () => ({ status: 'ok', ts: Date.now() }));
app.get('/api/ready', async (_req, reply) => {
  const ok = await dbHealthy();
  reply.code(ok ? 200 : 503);
  return { status: ok ? 'ok' : 'degraded', checks: { database: ok ? 'ok' : 'down' } };
});

// ---------- 业务路由 ----------
await app.register(syncRoutes);
await app.register(authRoutes);
await app.register(coupleRoutes);
await app.register(dishTypeRoutes);
await app.register(dishFlavorRoutes);
await app.register(dishRoutes);
await app.register(orderRoutes);
await app.register(uploadRoutes);
await app.register(adminRoutes);
await app.register(wsRoutes);

// ---------- 启动 ----------
async function start() {
  // 建表 → 建超管 → 监听。顺序不能变：ensureAdmin 依赖 users 表。
  await runMigrations(app.log);

  // 超管必须在监听前就绪，否则前端首屏可能 401
  const admin = await ensureAdmin();
  app.log.info({ created: admin.created }, admin.created ? '超管账号已创建' : '超管账号已存在');

  await app.listen({ port: config.PORT, host: config.HOST });
  app.log.info({ port: config.PORT, host: config.HOST, env: config.NODE_ENV }, 'couple-menu api up');
}

// ---------- 优雅退出 ----------
let shuttingDown = false;
for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info({ sig }, 'shutting down');
    try {
      await app.close();
      await pool.end();
    } finally {
      process.exit(0);
    }
  });
}

process.on('unhandledRejection', (reason) => {
  app.log.error({ reason: String(reason) }, 'unhandledRejection');
});

start().catch((err) => {
  app.log.error({ err: err.message, stack: err.stack }, 'startup failed');
  process.exit(1);
});
