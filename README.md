# 情侣点菜 App（Android）

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

---

## 三条设计主线

```
① 强隔离    所有业务表带 couple_id，越权统一 404
② 离线可用  本地 SQLite 是「副本」不是缓存，可读可写
③ 不丢改动  version 检测冲突 + 字段级合并 + 事件日志 cursor 补漏
```

---

## 本地验证 Schema

```bash
createdb couple_menu
psql -d couple_menu -f docs/schema.sql
psql -d couple_menu -c "\dt"      # 应看到 16 张表
```

---

## 关键提醒

1. **部署后第一件事：改 `.env` 里的 `ADMIN_PASSWORD`** —— 超管能解散所有关系、看所有内容
2. **2G 内存必须开 2G swap** —— 否则 OOM Killer 会杀进程
3. **备份只留本地 3 天** —— 能防误删，不能防磁盘损坏（这是已接受的边界）
