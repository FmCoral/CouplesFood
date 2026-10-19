-- ============================================================================
-- 情侣点菜 App — PostgreSQL Schema v2.0（定稿）
-- 依据：docs/需求基线.md v2.0
-- 环境：PostgreSQL 16+  |  时区一律 timestamptz  |  主键一律 uuid
-- 约定：枚举用 text + CHECK（改起来比 PG enum 轻）；所有业务表带 couple_id
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================ 用户与会话 ============================

CREATE TABLE users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone          text UNIQUE NOT NULL,
  password_hash  text NOT NULL,                    -- scrypt；生产可换 argon2id，接口不变
  nickname       text NOT NULL,
  avatar_url     text,
  is_admin       boolean NOT NULL DEFAULT false,   -- 超管：不可参与情侣绑定
  is_active      boolean NOT NULL DEFAULT true,
  last_seen_at   timestamptz,                      -- 供超管查看「最后活跃」
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT users_phone_fmt CHECK (phone ~ '^1[3-9][0-9]{9}$'),
  CONSTRAINT users_nickname_len CHECK (char_length(nickname) BETWEEN 1 AND 20)
);

-- 一个系统内至少留一条后路：不允许把最后一个超管降级/删号
CREATE INDEX idx_users_admin ON users(id) WHERE is_admin = true;

CREATE TABLE refresh_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,                -- sha256(明文)，不存明文
  device_id   text NOT NULL,
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_refresh_user_live ON refresh_tokens(user_id) WHERE revoked_at IS NULL;

CREATE TABLE device_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token        text NOT NULL UNIQUE,
  platform     text NOT NULL DEFAULT 'android',
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_device_tokens_user ON device_tokens(user_id);

-- ============================ 情侣关系 ============================
-- 状态机：pending → active → dissolving → dissolved（归档）
--                       ↑          │
--                       └── B拒绝 / A撤回
-- 归档：dissolved 记录永久保留（archived_at 不为空），不物理删除

CREATE TABLE couples (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invite_code     text UNIQUE NOT NULL,            -- 6 位，仅 pending 有效
  invite_expires  timestamptz NOT NULL DEFAULT now() + interval '24 hours',
  member_a        uuid REFERENCES users(id) ON DELETE RESTRICT,  -- 创建者
  member_b        uuid REFERENCES users(id) ON DELETE RESTRICT,  -- 加入者
  status          text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','active','dissolving','dissolved')),
  version         int NOT NULL DEFAULT 0,
  bound_at        timestamptz,
  dissolved_at    timestamptz,
  dissolved_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  dissolved_reason text,                            -- 'mutual' | 'admin'
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT couples_distinct_members CHECK (member_a IS NULL OR member_b IS NULL OR member_a <> member_b)
);

-- 一个人同时只能在一个「未结束」的关系里（pending/active/dissolving 都算占用）
CREATE UNIQUE INDEX uq_couples_a_live ON couples(member_a) WHERE status <> 'dissolved';
CREATE UNIQUE INDEX uq_couples_b_live ON couples(member_b) WHERE status <> 'dissolved';
CREATE INDEX idx_couples_status ON couples(status, updated_at DESC);
CREATE INDEX idx_couples_invite ON couples(invite_code) WHERE status = 'pending';

-- 关系内称呼（"饲养员 / 被饲养的"）
CREATE TABLE couple_members (
  couple_id   uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_label  text,
  joined_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (couple_id, user_id)
);

-- 解散申请：独立表，保留完整历史（发起/撤回/拒绝/同意/超管强制）
CREATE TABLE dissolution_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  couple_id     uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  initiated_by  uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  reason        text,
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','withdrawn','rejected','approved','forced_by_admin')),
  resolved_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  resolved_at   timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
-- 同一对情侣同时只能有一条待处理申请
CREATE UNIQUE INDEX uq_dissolution_pending ON dissolution_requests(couple_id) WHERE status = 'pending';
CREATE INDEX idx_dissolution_couple ON dissolution_requests(couple_id, created_at DESC);

-- 邀请码暴力尝试计数（错 5 次锁 1 小时，按设备维度）
CREATE TABLE invite_attempts (
  id          bigserial PRIMARY KEY,
  device_id   text NOT NULL,
  code_tried  text,
  success     boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_invite_attempts_device ON invite_attempts(device_id, created_at DESC);

-- ============================ 分类（双维度）============================
-- 种类：单选，1 道菜最多 1 个（靠 dish_type_links 的 UNIQUE(dish_id) 强制）
-- 口味：多选，0..n
-- 每对情侣各自一套，绑定成功时复制预设

CREATE TABLE dish_types (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  couple_id   uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  is_preset   boolean NOT NULL DEFAULT false,     -- 预设项不可改名，但可删除
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (couple_id, name)
);
CREATE INDEX idx_dish_types_couple ON dish_types(couple_id, sort_order);

CREATE TABLE dish_flavors (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  couple_id   uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  name        text NOT NULL,
  sort_order  int NOT NULL DEFAULT 0,
  is_preset   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (couple_id, name)
);
CREATE INDEX idx_dish_flavors_couple ON dish_flavors(couple_id, sort_order);

-- ============================ 菜品 ============================

CREATE TABLE dishes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),  -- 支持客户端生成 UUID（离线新建）
  couple_id     uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  name          text NOT NULL,
  image_key     text,                             -- 本地磁盘相对路径，如 images/ab/cd/uuid.jpg
  note          text,                             -- 备注："少放糖"
  tags          text[] NOT NULL DEFAULT '{}',     -- 自由标签（不受控词表）
  is_available  boolean NOT NULL DEFAULT true,
  created_by    uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  version       int NOT NULL DEFAULT 1,           -- 乐观锁
  deleted_at    timestamptz,                      -- 软删除，历史订单仍引用
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT dishes_name_len CHECK (char_length(name) BETWEEN 1 AND 40),
  CONSTRAINT dishes_note_len CHECK (note IS NULL OR char_length(note) <= 200)
);

-- 种类关联：每道菜最多 1 个种类（UNIQUE(dish_id) 是这条铁律的数据库级保证）
CREATE TABLE dish_type_links (
  dish_id   uuid PRIMARY KEY REFERENCES dishes(id) ON DELETE CASCADE,
  type_id   uuid NOT NULL REFERENCES dish_types(id) ON DELETE CASCADE
);
CREATE INDEX idx_dish_type_links_type ON dish_type_links(type_id);

-- 口味关联：每道菜 0..n 个口味
CREATE TABLE dish_flavor_links (
  dish_id    uuid NOT NULL REFERENCES dishes(id) ON DELETE CASCADE,
  flavor_id  uuid NOT NULL REFERENCES dish_flavors(id) ON DELETE CASCADE,
  PRIMARY KEY (dish_id, flavor_id)
);
CREATE INDEX idx_dish_flavor_links_flavor ON dish_flavor_links(flavor_id);

-- 列表页主查询：couple + 未删除 + 排序
CREATE INDEX idx_dishes_couple_live ON dishes(couple_id, updated_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX idx_dishes_couple_updated ON dishes(couple_id, updated_at);   -- 增量同步
CREATE INDEX idx_dishes_tags ON dishes USING GIN(tags);

-- ============================ 点菜订单 ============================

CREATE TABLE orders (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  couple_id     uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  requester_id  uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,   -- 谁点的
  chef_id       uuid REFERENCES users(id) ON DELETE SET NULL,            -- 谁做（默认对方）
  meal_type     text NOT NULL DEFAULT 'dinner'
                CHECK (meal_type IN ('breakfast','lunch','dinner','night_snack','other')),
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','accepted','cooking','served','completed','rejected','cancelled')),
  request_note  text,
  reply_note    text,                              -- "今天太累，明天做"
  eta_at        timestamptz,
  version       int NOT NULL DEFAULT 1,
  accepted_at   timestamptz,
  served_at     timestamptz,
  completed_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_couple_status ON orders(couple_id, status, created_at DESC);
CREATE INDEX idx_orders_couple_created ON orders(couple_id, created_at DESC);
-- 首页「进行中」只查这几种状态
CREATE INDEX idx_orders_active ON orders(couple_id, created_at DESC)
  WHERE status IN ('pending','accepted','cooking','served');

-- 快照冻结：菜改名/删除不影响历史订单
CREATE TABLE order_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  dish_id         uuid REFERENCES dishes(id) ON DELETE SET NULL,
  dish_name       text NOT NULL,                   -- 快照
  dish_image_key  text,                            -- 快照
  quantity        int NOT NULL DEFAULT 1 CHECK (quantity > 0 AND quantity <= 20),
  note            text,
  UNIQUE (order_id, dish_id)
);
CREATE INDEX idx_order_items_order ON order_items(order_id);

-- ============================ 同步事件 ============================
-- 所有写操作在同一事务内追加一条；id 单调递增 = 客户端游标

CREATE SEQUENCE sync_event_seq;

CREATE TABLE sync_events (
  id           bigint PRIMARY KEY DEFAULT nextval('sync_event_seq'),
  couple_id    uuid NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
  actor_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  type         text NOT NULL,      -- dish.created / order.status_changed / couple.dissolving / ...
  entity_type  text NOT NULL,      -- dish | order | couple
  entity_id    uuid NOT NULL,
  payload      jsonb NOT NULL DEFAULT '{}',
  version      int,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_events_couple_id ON sync_events(couple_id, id DESC);
CREATE INDEX idx_events_created ON sync_events(created_at);

-- ============================ 超管审计 ============================
-- 超管的每一个动作都要留痕：解散、重置密码、查看敏感数据

CREATE TABLE admin_audit_log (
  id          bigserial PRIMARY KEY,
  admin_id    uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  action      text NOT NULL,        -- dissolve.couple / reset.password / view.dishes / ...
  target_type text,                 -- couple | user | order
  target_id   uuid,
  detail      jsonb NOT NULL DEFAULT '{}',
  ip          text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_admin_audit_admin ON admin_audit_log(admin_id, created_at DESC);
CREATE INDEX idx_admin_audit_target ON admin_audit_log(target_type, target_id);

-- ============================ 触发器 ============================

CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_users_touch    BEFORE UPDATE ON users    FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_couples_touch  BEFORE UPDATE ON couples  FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_dishes_touch   BEFORE UPDATE ON dishes   FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
CREATE TRIGGER trg_orders_touch   BEFORE UPDATE ON orders   FOR EACH ROW EXECUTE FUNCTION touch_updated_at();

-- ============================ 预设数据（每对情侣复制）============================
-- 种类预设 6 项、口味预设 7 项。初始化在应用层做（COUPLE_INIT），不在此硬编码。

COMMENT ON TABLE dish_types   IS '种类维度：单选，每道菜最多 1 个';
COMMENT ON TABLE dish_flavors IS '口味维度：多选，每道菜 0..n 个';
COMMENT ON TABLE dishes       IS '菜品；image_key 指向 /data/images 下相对路径';
COMMENT ON TABLE sync_events  IS '同步事件流；id 即客户端 cursor';
COMMENT ON TABLE admin_audit_log IS '超管操作审计；超管所有写/敏感读都必须落一条';
