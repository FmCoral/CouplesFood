import { createHash, randomBytes, randomInt, scrypt as _scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { SignJWT, jwtVerify } from 'jose';
import { config } from './config.js';
import { Unauthorized } from './errors.js';

const scrypt = promisify(_scrypt) as (p: string, s: string, k: number) => Promise<Buffer>;
const secret = new TextEncoder().encode(config.JWT_SECRET);

export interface AccessClaims {
  sub: string;              // userId
  coupleId: string | null;  // 当前关系；null = 未绑定
  adm: boolean;             // 是否超管
}

// ---------- 密码 ----------
export async function hashPassword(plain: string): Promise<string> {
  const salt = randomBytes(16).toString('hex');
  const hash = await scrypt(plain, salt, 64);
  return `scrypt$${salt}$${hash.toString('hex')}`;
}

export async function verifyPassword(plain: string, stored: string): Promise<boolean> {
  const [scheme, salt, hex] = stored.split('$');
  if (scheme !== 'scrypt' || !salt || !hex) return false;
  const got = await scrypt(plain, salt, 64);
  const want = Buffer.from(hex, 'hex');
  return got.length === want.length && timingSafeEqual(got, want);
}

// ---------- Access Token ----------
export async function signAccessToken(claims: AccessClaims): Promise<string> {
  return new SignJWT({ coupleId: claims.coupleId, adm: claims.adm })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(claims.sub)
    .setIssuer(config.JWT_ISSUER)
    .setIssuedAt()
    .setExpirationTime(`${config.ACCESS_TTL_SEC}s`)
    .sign(secret);
}

export async function verifyAccessToken(token: string): Promise<AccessClaims> {
  try {
    const { payload } = await jwtVerify(token, secret, { issuer: config.JWT_ISSUER });
    return {
      sub: String(payload.sub),
      coupleId: (payload.coupleId as string | null) ?? null,
      adm: payload.adm === true,
    };
  } catch {
    throw new Unauthorized();
  }
}

// ---------- Refresh Token ----------
/** 明文给客户端；库里只存 sha256，泄露也只是密文 */
export function newRefreshToken(): { plain: string; hash: string } {
  const id = randomBytes(9).toString('base64url');
  const sec = randomBytes(32).toString('base64url');
  const plain = `${id}.${sec}`;
  return { plain, hash: sha256(plain) };
}

export const sha256 = (s: string) => createHash('sha256').update(s).digest('hex');

/** 6 位邀请码（避开 0/1 这种读错的数字） */
export function newInviteCode(): string {
  const alphabet = '23456789';
  let out = '';
  for (let i = 0; i < 6; i++) out += alphabet[randomInt(0, alphabet.length)];
  return out;
}
