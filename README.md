# 食在有你 App（Android）

一对情侣共用私有空间：双方都能加菜、点菜、接单做饭，数据实时互见；服务器在国外偶尔连不上时仍可用。

- **仅 Android**（Flutter，出 apk）
- **≤ 5 人内部测试，不上线**
- 部署在单台 2C2G 服务器，域名 `https://food.fmcoral.com`

---

## 文档（按阅读顺序）

| # | 文件 | 内容 |
|---|---|---|
| 1 | **[docs/需求基线.md](docs/需求基线.md)** | **需求真相源**：所有决策、变更、否决理由 |
| 2 | [docs/架构与开发方案.md](docs/架构与开发方案.md) | 技术选型、三大核心设计、排期 |
| 3 | [docs/接口契约.md](docs/接口契约.md) | 逐接口定义、错误码、状态机 |
| 4 | [docs/schema.sql](docs/schema.sql) | 建表脚本（PG16 已验证，16 张表） |
| 5 | [docs/部署手册.md](docs/部署手册.md) | 从零到 HTTPS，含备份与恢复 |
| 6 | [server/README.md](server/README.md) | 服务端目录约定、资源限制、常见故障 |
| 7 | [app/README.md](app/README.md) | 客户端环境、构建 apk、签名 |

---

## 三条设计主线

```
① 强隔离    所有业务表带 couple_id，越权统一 404
② 离线可用  本地 SQLite 是「副本」不是缓存，可读可写
③ 不丢改动  version 检测冲突 + 字段级合并 + 事件日志 cursor 补漏
```

---

## 快速开始（本地从零跑起来）

### 0. 前置

| 依赖 | 版本 | 说明 |
|---|---|---|
| Node.js | **≥ 22** | 服务端用原生 `node --test`，低版本跑不了测试 |
| Docker + Compose v2 | 任意较新版本 | 跑 PostgreSQL 16；不用 Docker 的话自己装 PG 也行 |
| Flutter | **3.47.x / Dart 3.13.x** | 只在要改客户端时才需要 |
| Android SDK | compileSdk 36 + JDK 17+ | 只在要打 apk 时才需要 |

### 1. 起服务端

```bash
git clone https://github.com/FmCoral/CouplesFood.git
cd CouplesFood/server

# 1) 配置
cp .env.example .env
sed -i "s/CHANGE_ME_DB_PASSWORD/$(openssl rand -hex 16)/" .env
sed -i "s/CHANGE_ME_64_HEX_CHARS/$(openssl rand -hex 32)/" .env
sed -i "s/CHANGE_ME_ADMIN_PASSWORD/$(openssl rand -hex 8)/" .env

# 2) 数据目录（compose 里挂的是绝对路径）
sudo mkdir -p /data/couple/{images,backup,pgdata}

# 3) 起
docker compose up -d --build
docker compose logs -f api        # 看到 listening 就好了
```

> `docker compose` 必须在 **`server/` 目录**下执行。compose 的 build context 是仓库根目录
> （`context: ..`），因为 Dockerfile 要 `COPY docs/schema.sql` —— 建表脚本只保留一份真相源。

**自检**：

```bash
curl -s http://127.0.0.1:3000/api/health
# {"status":"ok","ts":...}

cd server && ADMIN_PHONE=你的超管手机号 ADMIN_PASSWORD=你的超管密码 npm run smoke
# 全部通过：114 项
```

`npm run smoke` 会**造数据**（注册两个账号 → 绑定 → 点菜 → 解散归档），
别对着有真实数据的库跑。不传 `ADMIN_PHONE` / `ADMIN_PASSWORD` 时，
第 13 节（超管）会明确跳过并提示，其余 92 项照常跑。

### 2. 打客户端 apk

```bash
cd app
flutter pub get
flutter analyze                   # 期望 0 error / 0 warning
flutter build apk --release --target-platform android-arm64
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

**客户端里的服务器地址是编译期常量**，在 `app/lib/core/config.dart`：

```dart
static const defaultBaseUrl = 'https://food.fmcoral.com';
```

换域名就改这一行重打包；换 IP 不用动它——改 DNS 解析即可，已装的 App 无感。

**签名**：仓库里**不含**私钥。`app/android/key.properties` 缺失时，release 会自动
退回 debug 签名（能装能跑，但不能覆盖升级已装的正式版）。要用正式签名，自己生成一套：

```bash
cd app/android/app
keytool -genkeypair -v -keystore my-release.keystore -alias my-key \
  -keyalg RSA -keysize 2048 -validity 10000
```

然后写 `app/android/key.properties`：

```properties
storeFile=app/keystore/my-release.keystore
storePassword=你的口令
keyAlias=my-key
keyPassword=你的口令
```

> ⚠️ 生成新密钥 = 新签名 = **和线上已装的 App 不是同一个 App**，只能卸载重装，不能覆盖升级。
> 想接着升级线上版本，必须用原来那把密钥（见 `app/README.md`）。

### 3. 不用 Docker 的话

只需要一个 PostgreSQL 16，库名 / 用户都叫 `couple`：

```bash
createdb -U couple couple
psql -U couple -d couple -f docs/schema.sql
psql -U couple -d couple -c "\dt"          # 应看到 16 张表

cd server && npm ci && npm run build
DATABASE_URL=postgres://couple:密码@127.0.0.1:5432/couple \
HOST=127.0.0.1 npm start
```

`src/shared/migrate.ts` 启动时会自己执行 `docs/schema.sql`（幂等：`users` 表已存在就整体跳过），所以手动导 schema 是可选的。

---

## 关键提醒

1. **部署后第一件事：改 `.env` 里的 `ADMIN_PASSWORD`** —— 超管能解散所有关系、看所有内容
2. **2G 内存必须开 2G swap** —— 否则 OOM Killer 会杀进程
3. **备份只留本地 3 天** —— 能防误删，不能防磁盘损坏（这是已接受的边界）
4. **别把 3000 / 5433 开到公网** —— api 和 db 都只绑 `127.0.0.1`，对外只走 Nginx 443
