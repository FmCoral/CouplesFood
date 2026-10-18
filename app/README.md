# 情侣点菜 · Android 客户端

仅 Android。Flutter + Drift（本地 SQLite）+ 自研 SyncEngine。

## 三层结构

```
lib/
├── main.dart
├── core/                 # 与业务无关的底座
│   ├── api_client.dart   # HTTP 封装：统一信封、401 静默刷新、错误映射
│   ├── problem.dart      # RFC 9457 错误模型
│   ├── session.dart      # token 存取 + 当前用户状态
│   └── result.dart       # 成功/失败二选一，不抛异常穿透
├── data/                 # 本地库 + 同步引擎
│   ├── db.dart           # Drift 表定义（与后端字段一一对应）
│   ├── dao/
│   └── sync/
│       ├── sync_engine.dart   # 推本地脏数据 → 拉远端事件 → 合并
│       ├── outbox.dart        # 待上传队列（离线新建/修改）
│       └── ws_client.dart     # WebSocket 长连接 + 断线重连
├── features/             # 按页面切分
│   ├── auth/             # 登录 / 注册
│   ├── couple/           # 邀请码 / 绑定 / 解散
│   ├── menu/             # 菜单列表、菜品编辑
│   ├── order/            # 点菜、订单详情、状态流转
│   ├── profile/          # 我的
│   └── admin/            # 超管（只读）
└── ui/                   # 全局组件与主题
```

## 四个必须做对的点

**1. 绑定后必须静默刷新 token**
`POST /api/couples/join` 只给 B 换发 token；A 手里的 access token 里 `coupleId` 仍是 null。
A 收到 `couple.bound` 事件后立刻 `POST /api/auth/refresh`，否则后续所有请求 403。

**2. 离线新建用客户端 UUID**
`POST /api/dishes` 接受 `id` 字段，同 id 重放返回 200 而非 409。这样断网时先写本地、联网后重放不会重复建菜。

**3. 冲突是字段级的，不是整条记录**
PATCH 撞 409 后，先 `GET /api/dishes/:id` 拿最新，再逐字段 diff：本地改过而远端没改的字段保留本地值，双方都改的弹窗让用户选。

**4. 图片先压缩再上传**
长边压到 1280、JPEG q=80，通常 200–500KB。原图在弱网下必然超时。

## 同步循环

```
每 5 秒 / 收到 WS 事件 / 网络恢复
   ├── 有 outbox 待发 → 按顺序 POST（失败保留，指数退避）
   └── GET /api/sync/events?since=<本地 cursor>
         ├── 按 type 分发：dish.* / order.* / couple.*
         ├── 写入本地表，更新 cursor
         └── 通知 UI（StreamController）
```

cursor 存在本地表 `sync_state` 里，杀掉 App 也不丢。
