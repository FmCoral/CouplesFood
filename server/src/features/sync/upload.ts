import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { mkdir, writeFile, stat } from 'node:fs/promises';
import { join, extname } from 'node:path';
import { config } from '../../config.js';
import { BadRequest, Validation, zodIssues } from '../../errors.js';
import { authenticate, me } from '../../middleware/auth.js';
import { hit } from '../../shared/rate-limit.js';

const ALLOWED = new Set(['.jpg', '.jpeg', '.png', '.webp']);

/** 魔数校验：不信任 Content-Type 和扩展名 */
function sniff(buf: Buffer): string | null {
  if (buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return '.jpg';
  if (buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return '.png';
  if (buf.subarray(0, 4).toString('ascii') === 'RIFF' && buf.subarray(8, 12).toString('ascii') === 'WEBP') return '.webp';
  return null;
}

/** 两级目录分摊 inode：images/ab/cd/<uuid>.jpg */
function shardPath(id: string, ext: string) {
  return { rel: `${id.slice(0, 2)}/${id.slice(2, 4)}/${id}${ext}` };
}

export default async function uploadRoutes(app: FastifyInstance) {
  app.post('/api/uploads', { preHandler: authenticate }, async (req, reply) => {
    const u = me(req);
    const rl = hit(`upload:${u.userId}`, 30, 60_000);
    if (!rl.ok) throw new (await import('../../errors.js')).RateLimited('上传太频繁');

    const file = await req.file({ limits: { fileSize: config.maxUploadBytes, files: 1 } });
    if (!file) throw new BadRequest('缺少文件字段 file');

    const buf = await file.toBuffer();
    if (buf.length === 0) throw new BadRequest('文件为空');
    if (buf.length > config.maxUploadBytes) throw new BadRequest(`文件超过 ${config.MAX_UPLOAD_MB}MB`);

    const sniffed = sniff(buf);
    if (!sniffed) throw new BadRequest('只支持 JPG / PNG / WebP');

    // 客户端扩展名只用于日志参考，实际用嗅探结果
    const clientExt = extname(file.filename ?? '').toLowerCase();
    if (clientExt && !ALLOWED.has(clientExt)) {
      req.log.warn({ clientExt, sniffed }, '客户端扩展名与内容不一致，按内容处理');
    }

    const id = randomUUID();
    const { rel } = shardPath(id, sniffed);
    const abs = join(config.MEDIA_ROOT, rel);
    await mkdir(join(abs, '..'), { recursive: true });
    await writeFile(abs, buf);

    const imageKey = rel;
    const imageUrl = `${config.MEDIA_BASE_URL || ''}${config.MEDIA_BASE_PATH}/${rel}`;
    reply.code(200);
    return { data: { imageKey, imageUrl, size: buf.length } };
  });

  // 图片信息（超管排查用）
  app.get('/api/uploads/:key/info', { preHandler: authenticate }, async (req) => {
    const { key } = z.object({ key: z.string().min(1) }).parse(req.params);
    if (key.includes('..')) throw new BadRequest('非法路径');
    try {
      const s = await stat(join(config.MEDIA_ROOT, key));
      return { data: { key, size: s.size, mtime: s.mtime.toISOString() } };
    } catch {
      return { data: null };
    }
  });
}
