import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/models.dart';

/// 本地 SQLite
///
/// 设计要点：
/// - 菜品/分类/订单在本地各存一份，断网时 UI 仍可用
/// - `dirty` 标记本地待上传；`server_version` 用于乐观锁
/// - `sync_state` 存 cursor，杀进程也不丢
/// - `outbox` 是待发送队列，按 id 自增顺序重放
class LocalDb {
  Database? _db;

  Database get db {
    final d = _db;
    if (d == null) throw StateError('LocalDb 未初始化');
    return d;
  }

  Future<void> open() async {
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'couple_menu.db'),
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE dishes (
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 1,
        updated_at TEXT,
        dirty INTEGER NOT NULL DEFAULT 0,
        deleted INTEGER NOT NULL DEFAULT 0
      )''');
    await db.execute('''
      CREATE TABLE categories (
        kind TEXT NOT NULL,          -- type | flavor
        id TEXT NOT NULL,
        json TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (kind, id)
      )''');
    await db.execute('''
      CREATE TABLE orders (
        id TEXT PRIMARY KEY,
        json TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT,
        version INTEGER NOT NULL DEFAULT 1
      )''');
    await db.execute('''
      CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)''');
    await db.execute('''
      CREATE TABLE outbox (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        op TEXT NOT NULL,            -- dish.create | dish.update | dish.delete | order.create | order.transition
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT
      )''');
    await db.execute('CREATE INDEX idx_orders_created ON orders(created_at DESC)');
  }

  // ---------------- kv ----------------

  Future<String?> kvGet(String k) async {
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [k], limit: 1);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  Future<void> kvSet(String k, String v) async {
    await db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> get cursor async => await kvGet('cursor') ?? '0';

  Future<void> setCursor(String c) => kvSet('cursor', c);

  // ---------------- 菜品 ----------------

  Future<void> upsertDishes(List<Dish> list) async {
    final batch = db.batch();
    for (final d in list) {
      batch.insert(
        'dishes',
        {
          'id': d.id,
          'json': jsonEncode(_dishToJson(d)),
          'version': d.version,
          'dirty': 0,
          'deleted': 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteDishLocal(String id) async {
    await db.delete('dishes', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Dish>> allDishes() async {
    final rows = await db.query('dishes', where: 'deleted = 0', orderBy: 'rowid DESC');
    return rows
        .map((r) => Dish.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<Dish?> dishById(String id) async {
    final rows = await db.query('dishes', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Dish.fromJson(jsonDecode(rows.first['json'] as String) as Map<String, dynamic>);
  }

  /// 本地新建（离线）：先落库并标记 dirty，联网后由 outbox 重放
  Future<void> insertLocalDish(Dish d, {bool dirty = true}) async {
    await db.insert(
      'dishes',
      {
        'id': d.id,
        'json': jsonEncode(_dishToJson(d)),
        'version': d.version,
        'dirty': dirty ? 1 : 0,
        'deleted': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 本地修改后标脏
  Future<void> markDishDirty(Dish d) async {
    await db.update(
      'dishes',
      {'json': jsonEncode(_dishToJson(d)), 'dirty': 1},
      where: 'id = ?',
      whereArgs: [d.id],
    );
  }

  Future<void> clearDishDirty(String id, int serverVersion) async {
    await db.update(
      'dishes',
      {'dirty': 0, 'version': serverVersion},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Map<String, dynamic> _dishToJson(Dish d) => {
        'id': d.id,
        'name': d.name,
        'imageKey': d.imageKey,
        'imageUrl': d.imageUrl,
        'note': d.note,
        'tags': d.tags,
        'type': d.typeId == null ? null : {'id': d.typeId, 'name': d.typeName},
        'flavors': [
          for (var i = 0; i < d.flavorIds.length; i++)
            {'id': d.flavorIds[i], 'name': i < d.flavorNames.length ? d.flavorNames[i] : ''}
        ],
        'isAvailable': d.isAvailable,
        'version': d.version,
        'createdBy': d.createdBy,
      };

  // ---------------- 分类 ----------------

  Future<void> replaceCategories(String kind, List<Map<String, dynamic>> rows) async {
    final batch = db.batch();
    batch.delete('categories', where: 'kind = ?', whereArgs: [kind]);
    for (final r in rows) {
      batch.insert('categories', {
        'kind': kind,
        'id': r['id'].toString(),
        'json': jsonEncode(r),
        'sort_order': (r['sortOrder'] as num?)?.toInt() ?? 0,
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> categories(String kind) async {
    final rows = await db.query('categories', where: 'kind = ?', whereArgs: [kind], orderBy: 'sort_order, id');
    return rows.map((r) => jsonDecode(r['json'] as String) as Map<String, dynamic>).toList();
  }

  // ---------------- 订单 ----------------

  Future<void> upsertOrders(List<Order> list) async {
    final batch = db.batch();
    for (final o in list) {
      batch.insert(
        'orders',
        {
          'id': o.id,
          'json': jsonEncode(_orderToJson(o)),
          'status': o.status,
          'created_at': o.createdAt?.toIso8601String(),
          'version': o.version,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Order>> allOrders({int limit = 50}) async {
    final rows = await db.query('orders', orderBy: 'created_at DESC', limit: limit);
    return rows
        .map((r) => Order.fromJson(jsonDecode(r['json'] as String) as Map<String, dynamic>))
        .toList();
  }

  Future<Order?> orderById(String id) async {
    final rows = await db.query('orders', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Order.fromJson(jsonDecode(rows.first['json'] as String) as Map<String, dynamic>);
  }

  Map<String, dynamic> _orderToJson(Order o) => {
        'id': o.id,
        'status': o.status,
        'mealType': o.mealType,
        'requestNote': o.requestNote,
        'replyNote': o.replyNote,
        'requesterId': o.requesterId,
        'chefId': o.chefId,
        'version': o.version,
        'items': [
          for (final i in o.items)
            {'dishId': i.dishId, 'name': i.name, 'imageKey': i.imageKey, 'imageUrl': i.imageUrl, 'quantity': i.quantity, 'note': i.note}
        ],
        'createdAt': o.createdAt?.toIso8601String(),
        'timeline': {
          'acceptedAt': o.acceptedAt?.toIso8601String(),
          'servedAt': o.servedAt?.toIso8601String(),
          'completedAt': o.completedAt?.toIso8601String(),
        },
      };

  // ---------------- outbox ----------------

  Future<int> enqueue(String op, Map<String, dynamic> payload) async {
    return db.insert('outbox', {
      'op': op,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<List<Map<String, dynamic>>> pendingOps({int limit = 20}) async {
    final rows = await db.query('outbox', orderBy: 'seq ASC', limit: limit);
    return rows
        .map((r) => {
              'seq': r['seq'] as int,
              'op': r['op'] as String,
              'payload': jsonDecode(r['payload'] as String) as Map<String, dynamic>,
              'attempts': r['attempts'] as int,
            })
        .toList();
  }

  Future<void> removeOp(int seq) async {
    await db.delete('outbox', where: 'seq = ?', whereArgs: [seq]);
  }

  Future<void> bumpAttempt(int seq, String error) async {
    await db.rawUpdate(
      'UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE seq = ?',
      [error, seq],
    );
  }

  Future<int> outboxCount() async {
    final r = await db.rawQuery('SELECT COUNT(*) AS c FROM outbox');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> clearAll() async {
    await db.delete('dishes');
    await db.delete('categories');
    await db.delete('orders');
    await db.delete('outbox');
    await db.delete('kv');
  }
}
