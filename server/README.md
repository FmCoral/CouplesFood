> 本目录是「情侣点菜」服务端。生产环境跑在 Docker 里，**只监听 127.0.0.1**，
> 外部流量一律经宿主机宝塔 Nginx 反代进来。

# 一句话部署

```bash
# 首次
cd /data/couple/app/server && cp .env.example .env && vi .env && docker compose up -d --build
# 更新
cd /data/couple/app/server && git pull && docker compose up -d --build api
```

> compose 必须在 **`server/`** 下执行：build context 是 `context: ..`（仓库根），
> 因为 Dockerfile 要 `COPY docs/schema.sql`。

# 目录约定（宿主机）

```
/data/couple/
├── pgdata/                 # PostgreSQL 数据目录（与代码目录解耦，重 clone 不丢数据）
├── images/                 # 菜品图片（挂给 api 容器，属主 uid 1000）
├── backup/                 # 备份包，保留 3 天
└── app/                    # git 仓库（本目录在 app/server/）
    ├── server/             # ← 你在这里
    └── app/                # Flutter 客户端（不部署到服务器，只产出 apk）
```

> 这里**没有** `web/` 静态目录：客户端是 Android apk，不走浏览器，Nginx 只做
> `/api` 和 `/media` 的反代。

# 容器资源限制（2C2G 机器必须设）

| 服务 | mem_limit | 说明 |
|------|-----------|------|
| api  | 320m      | Node + 连接池（max 8），`--max-old-space-size=256` |
| db   | 400m      | shared_buffers=96MB，effective_cache_size=256MB |
| backup | 96m     | 单次执行容器，跑完即退 |

合计约 720MB 上限，给宝塔上的 MySQL/Nginx 留足余量。

# 端口

| 端口 | 归属 | 对外 |
|------|------|------|
| 3000 | api  | 否，仅 127.0.0.1 |
| 5433 | db   | 否，仅 127.0.0.1（避开宿主机 MySQL 的 3306） |
| 80/443 | 宝塔 Nginx | 是 |

# 本地开发（不碰 Docker）

```bash
npm ci
npm run dev                  # tsx watch，热重载
npm run build && npm start   # 编译后跑
npm test                     # node --test（需要先 build）
npm run smoke                # 114 项端到端冒烟，会造数据！
```

`npm run smoke` 打的是 `BASE_URL` 指向的环境，默认 `http://127.0.0.1:3000`。
超管那节需要显式传入凭据（脚本不猜默认值，因为 `.env` 里的 `ADMIN_PASSWORD` 部署时必改）：

```bash
ADMIN_PHONE=1875xxxx ADMIN_PASSWORD=你的口令 npm run smoke
# 全部通过：114 项
```

不传就让第 13 节跳过，其余 92 项照常跑并输出汇总。

它会在库里注册账号、建情侣、下单、再解散归档——**别对着有真实数据的库跑**。

# 为什么不用 Caddy

宿主机 80/443 已被宝塔 Nginx 占用，且上面还有 7 个网站。
再装一个反代只会抢端口。直接用宝塔新建站点 + 反向代理，零冲突。

# 常见问题

**api 起来就退出** → `docker compose logs api`。九成是 `.env` 缺项（`config.ts` 是 fail-fast 的）。
另外常见的是 `relation "users" does not exist`——`src/shared/migrate.ts` 在启动时
自己导 `docs/schema.sql`（幂等：`users` 表已存在就整体跳过）。它探测不到文件时会
把尝试过的路径全打出来，按提示把 `docs/schema.sql` 放到对应位置即可。

**数据库连不上** → 先 `docker compose ps` 看 db 是否 healthy；健康检查用的是 `pg_isready`。

**`Connection reset by peer`，看起来服务没起** → 容器里绑成了 `127.0.0.1`。
compose 的 `ports: 127.0.0.1:3000:3000` 是**宿主机侧**的绑定，容器内必须 `HOST=0.0.0.0`，
否则 docker-proxy 从 bridge 网段转进来的包会被内核拒掉。

**图片 404 / Nginx `stat() failed (13: Permission denied)`** → `/data` 和 `/data/couple`
缺 `o+x`。Nginx 是 www 用户，要能穿过目录才能读到文件：

```bash
sudo chmod o+x /data /data/couple
sudo chown -R 1000:1000 /data/couple/images
```

**图片 URL 变成 `/media/media/xxx.jpg`** → `.env` 里 `MEDIA_BASE_URL` 填成了带 `/media` 的地址。
它只该填域名（`https://food.fmcoral.com`），代码会自己拼 `MEDIA_BASE_PATH`。

**备份一秒刷一个包把磁盘写满** → 备份调度放在了容器内循环。`postgres:16-alpine` 是 busybox，
`date -d 'tomorrow 03:00'` 不支持，算出的等待时间是负数，`sleep` 失败后死循环。
调度必须在宿主机 cron（GNU date 可靠），容器只保留单次执行。
