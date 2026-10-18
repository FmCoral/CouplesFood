import { pool } from '../db.js';
import { newRefreshToken } from '../auth.js';
import { signAccessToken } from '../auth.js';
import { config } from '../config.js';

/**
 * 统一的 token 签发入口。
 * 为什么单独一个文件：绑定成功后需要给双方换发（coupleId 变了），
 * 而 auth/routes 与 couple/routes 都要用，抽出避免循环依赖。
 */
export async function issueTokensFor(
  userId: string,
  coupleId: string | null,
  isAdmin: boolean,
  deviceId: string,
) {
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
  };
}
