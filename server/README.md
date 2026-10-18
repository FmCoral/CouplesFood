> 本目录是「情侣点菜」服务端。生产环境跑在 Docker 里，**只监听 127.0.0.1**，
> 外部流量一律经宿主机宝塔 Nginx 反代进来。

# 一句话部署

```bash
# 首次
cd /data/couple && docker compose up -d
# 更新
cd /data/couple && git pull && docker compose up -d --build api
```

# 目录约定（宿主机）

```
/data/couple/
├── docker-compose.yml      # 编排文件
├── .env                    # 真实密钥，勿提交
├── images/                 # 菜品图片（挂给 api 容器）
├── backup/                 # 备份包，保留 3 天
├── pgdata/                 # PostgreSQL 数据目录
└── web/                    # 前端静态产物（Nginx 直接读）
```

# 容器资源限制（2C2G 机器必须设）

| 服务 | mem_limit | 说明 |
|------|-----------|------|
| api  | 320m      | Node + 连接池（max 8） |
| db   | 400m      | shared_buffers=96MB |

合计约 720MB 上限，给宝塔上的 MySQL/Nginx 留足余量。

# 端口

| 端口 | 归属 | 对外 |
|------|------|------|
| 3000 | api  | 否，仅 127.0.0.1 |
| 5433 | db   | 否，仅 127.0.0.1（避开宿主机 MySQL 的 3306） |
| 80/443 | 宝塔 Nginx | 是 |

# 为什么不用 Caddy

宿主机 80/443 已被宝塔 Nginx 占用，且上面还有 7 个网站。
再装一个反代只会抢端口。直接用宝塔新建站点 + 反向代理，零冲突。

# 常见问题

**api 起来就退出** → `docker compose logs api`，九成是 `.env` 缺项（config.ts 是 fail-fast 的）。

**数据库连不上** → 先 `docker compose ps` 看 db 是否 healthy；健康检查用的是 `pg_isready`。

**图片 404** → 确认 `/data/couple/images` 存在且 api 容器有写权限（uid 1000）。
