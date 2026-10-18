/** 类型化错误：可预期 → 结构化响应；其余 → 500 + 日志 */
export class AppError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly statusCode: number,
    readonly detail?: unknown,
  ) {
    super(message);
    this.name = new.target.name;
  }
}

export class BadRequest extends AppError {
  constructor(msg = '请求格式错误') { super('BAD_REQUEST', msg, 400); }
}
export class Unauthorized extends AppError {
  constructor(msg = '登录已过期，请重新登录') { super('UNAUTHORIZED', msg, 401); }
}
export class Forbidden extends AppError {
  constructor(msg = '无权执行此操作') { super('FORBIDDEN', msg, 403); }
}
/** 注意：资源存在但不属于当前 couple 时，对外一律用 404（不泄露存在性） */
export class NotFound extends AppError {
  constructor(resource = '资源', id?: string) {
    super('NOT_FOUND', id ? `${resource}不存在` : `${resource}不存在`, 404);
  }
}
export class Conflict extends AppError {
  constructor(msg: string, detail?: unknown) { super('CONFLICT', msg, 409, detail); }
}
export class Validation extends AppError {
  constructor(detail: unknown) { super('VALIDATION_ERROR', '参数校验失败', 422, detail); }
}
export class RateLimited extends AppError {
  constructor(msg = '操作太频繁，请稍后再试') { super('RATE_LIMITED', msg, 429); }
}

/** RFC 9457 Problem Details */
export function problemBody(err: AppError, requestId: string) {
  return {
    type: `https://couple-menu/errors/${err.code.toLowerCase()}`,
    title: err.code,
    status: err.statusCode,
    detail: err.message,
    ...(err.detail !== undefined ? { errors: err.detail } : {}),
    request_id: requestId,
  };
}

export function zodIssues(err: import('zod').ZodError) {
  return err.issues.map((i) => ({ path: i.path, message: i.message, code: i.code }));
}
