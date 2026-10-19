import 'dart:async';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/problem.dart';
import 'local_db.dart';

/// 同步引擎
///
/// 循环：
///   1. 清空 outbox（本地待上传的写操作，按入队顺序重放）
///   2. GET /api/sync/events?since=cursor 拉增量
///   3. 应用到本地库，推进 cursor
///
/// 触发时机：定时 / 收到 WS 事件 / 手工下拉 / 网络恢复
class SyncEngine {
  SyncEngine({required this.api, required this.db});

  final ApiClient api;
  final LocalDb db;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  /// 构造完成即为 true
  bool get didInit => true;

  /// UI 监听：菜品/订单/分类任一变化都会触发
  final _changes = StreamController<SyncChange>.broadcast();
  Stream<SyncChange> get changes => _changes.stream;

  /// 同步状态（给顶栏显示"同步中/离线"）
  final _status = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get status => _status.stream;
  SyncStatus _current = const SyncStatus.idle();
  SyncStatus get current => _current;

  /// 必须让用户看见的提示（如离线操作重放时被对方抢先处理产生的冲突）
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;

  void _emit(SyncChange c) {
    if (!_disposed) _changes.add(c);
  }

  void _setStatus(SyncStatus s) {
    _current = s;
    if (!_disposed) _status.add(s);
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => syncNow());
    syncNow();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 全量同步：先推后拉
  Future<void> syncNow() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      final pushed = await _flushOutbox();
      final pulled = await _pullEvents();
      if (pushed > 0 || pulled > 0) {
        _emit(SyncChange.full);
      }
      _setStatus(SyncStatus.ok(DateTime.now(), pending: await db.outboxCount()));
    } on ApiProblem catch (e) {
      // 未登录/未绑定不算错误噪音
      if (e.status == 403 || e.status == 401) {
        _setStatus(const SyncStatus.idle());
      } else {
        _setStatus(SyncStatus.error(e.friendly));
      }
    } catch (e) {
      _setStatus(SyncStatus.error('$e'));
    } finally {
      _running = false;
    }
  }

  // ---------------- 推 ----------------

  Future<int> _flushOutbox() async {
    final ops = await db.pendingOps();
    if (ops.isEmpty) return 0;
    var done = 0;
    for (final op in ops) {
      final ok = await _applyOp(op['op'] as String, op['payload'] as Map<String, dynamic>);
      if (ok) {
        await db.removeOp(op['seq'] as int);
        done++;
      } else {
        await db.bumpAttempt(op['seq'] as int, 'failed');
        // 遇到失败就停，保持顺序语义（尤其建菜→改菜）
        break;
      }
    }
    return done;
  }

  Future<bool> _applyOp(String op, Map<String, dynamic> payload) async {
    try {
      switch (op) {
        case 'dish.create':
          final res = await api.post<Map<String, dynamic>>('/dishes', payload);
          await db.clearDishDirty(payload['id'] as String, (res['version'] as num?)?.toInt() ?? 1);
          return true;

        case 'dish.update':
          final res = await api.patch<Map<String, dynamic>>('/dishes/${payload['id']}', payload);
          await db.clearDishDirty(payload['id'] as String, (res['version'] as num?)?.toInt() ?? 1);
          return true;

        case 'dish.delete':
          await api.delete<void>('/dishes/${payload['id']}');
          await db.deleteDishLocal(payload['id'] as String);
          return true;

        case 'order.create':
          await api.post<Map<String, dynamic>>('/orders', payload);
          return true;

        case 'order.transition':
          await api.post<Map<String, dynamic>>('/orders/${payload['id']}/transition', payload);
          return true;

        case 'category.create':
          await api.post<Map<String, dynamic>>('/${payload['kind'] == 'type' ? 'dish-types' : 'dish-flavors'}',
              {'name': payload['name']});
          await refreshCategories();
          return true;

        default:
          return true; // 未知操作直接丢弃，避免卡死队列
      }
    } on ApiProblem catch (e) {
      // 409 冲突：操作已过时（常发生在离线期间两人对同一订单做了相反操作），
      // 重试没有意义 → 丢弃，但绝不能静默：必须提示用户并立刻重拉纠正本地状态。
      if (e.isConflict) {
        if (!_disposed) _notices.add(e.friendly);
        await _refreshAfterConflict(op);
        return true;
      }
      // 404 已被删：同样丢弃
      if (e.isNotFound) return true;
      // 422 参数错误：重试也没用
      if (e.status == 422) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 冲突后重拉，把本地状态纠正回服务端真实状态
  Future<void> _refreshAfterConflict(String op) async {
    try {
      if (op.startsWith('order.')) {
        await refreshOrders();
      } else {
        await refreshMenu();
      }
    } catch (_) {
      // 重拉失败不影响丢弃冲突操作，下一次定时同步会补上
    }
  }

  // ---------------- 拉 ----------------

  Future<int> _pullEvents() async {
    final since = await db.cursor;
    final res = await api.get<Map<String, dynamic>>('/sync/events', query: {'since': since});
    final events = (res['data'] as List? ?? [])
        .whereType<Map>()
        .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final cursor = (res['cursor'] ?? since).toString();

    if (events.isNotEmpty) {
      await _applyEvents(events);
    }
    await db.setCursor(cursor);
    return events.length;
  }

  Future<void> _applyEvents(List<SyncEvent> events) async {
    var needMenu = false;
    var needOrders = false;

    for (final e in events) {
      switch (e.type) {
        case 'dish.created':
        case 'dish.updated':
          needMenu = true;
          break;
        case 'dish.deleted':
          await db.deleteDishLocal(e.entityId);
          needMenu = true;
          break;
        case 'dish.type_changed':
        case 'dish.flavor_changed':
          needMenu = true;
          break;
        case 'order.created':
        case 'order.status_changed':
          needOrders = true;
          break;
        case 'couple.bound':
        case 'couple.dissolving':
        case 'couple.dissolve_rejected':
        case 'couple.dissolved':
          _emit(SyncChange.couple);
          break;
      }
    }

    // 事件只带最小 payload，实体状态一律重新拉，避免本地拼装出错
    if (needMenu) {
      await refreshMenu();
    }
    if (needOrders) {
      await refreshOrders();
      _emit(SyncChange.orders);
    }
  }

  // ---------------- 全量刷新 ----------------

  Future<void> refreshMenu() async {
    final dishes = await api.get<List<dynamic>>('/dishes', query: {'includeUnavailable': true});
    final list = dishes.whereType<Map>().map((e) => Dish.fromJson(Map<String, dynamic>.from(e))).toList();
    await db.upsertDishes(list);
    await refreshCategories();
    _emit(SyncChange.menu);
  }

  Future<void> refreshCategories() async {
    final types = await api.get<List<dynamic>>('/dish-types');
    final flavors = await api.get<List<dynamic>>('/dish-flavors');
    await db.replaceCategories(
        'type', types.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
    await db.replaceCategories(
        'flavor', flavors.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
    _emit(SyncChange.categories);
  }

  Future<void> refreshOrders() async {
    final res = await api.get<List<dynamic>>('/orders', query: {'limit': 50});
    final list = res.whereType<Map>().map((e) => Order.fromJson(Map<String, dynamic>.from(e))).toList();
    await db.upsertOrders(list);
  }

  // ---------------- 离线写入 ----------------

  /// 建菜：先写本地 + 入队，联网后自动重放
  Future<void> createDishOffline(Dish dish, Map<String, dynamic> serverPayload) async {
    await db.insertLocalDish(dish);
    await db.enqueue('dish.create', serverPayload);
    _emit(SyncChange.menu);
    await syncNow();
  }

  Future<void> updateDishOffline(Dish dish, Map<String, dynamic> serverPayload) async {
    await db.markDishDirty(dish);
    await db.enqueue('dish.update', serverPayload);
    _emit(SyncChange.menu);
    await syncNow();
  }

  Future<void> deleteDishOffline(String id) async {
    await db.deleteDishLocal(id);
    await db.enqueue('dish.delete', {'id': id});
    _emit(SyncChange.menu);
    await syncNow();
  }

  Future<void> createOrderOffline(Map<String, dynamic> serverPayload) async {
    await db.enqueue('order.create', serverPayload);
    _emit(SyncChange.orders);
    await syncNow();
  }

  Future<void> transitionOrder(String orderId, String to, int version, {String? replyNote}) async {
    await db.enqueue('order.transition', {
      'id': orderId,
      'to': to,
      'version': version,
      if (replyNote != null) 'replyNote': replyNote,
    });
    await syncNow();
  }

  Future<void> createCategory(String kind, String name) async {
    await db.enqueue('category.create', {'kind': kind, 'name': name});
    await syncNow();
  }

  // ---------------- 图片压缩上传 ----------------

  /// 客户端压缩：长边 1280 / JPEG q80，通常 200–500KB
  ///
  /// 4G 弱网下原图（3–5MB）必然超时，压缩是必须的而不是优化。
  /// 压缩不可用时（Windows 桌面端没有该插件实现）回退上传原图，见 [_tryCompress]。
  Future<Map<String, dynamic>> compressAndUpload(String srcPath) async {
    final tmpDir = await getTemporaryDirectory();
    final target = p.join(tmpDir.path, 'up_${DateTime.now().millisecondsSinceEpoch}.jpg');

    final compressedPath = await _tryCompress(srcPath, target);

    final path = compressedPath ?? srcPath;
    try {
      return await api.uploadImage(path);
    } finally {
      // 临时文件用完即删
      try {
        if (compressedPath != null) await File(compressedPath).delete();
      } catch (_) {}
    }
  }

  /// 尝试压缩，失败则回退「上传原图」
  ///
  /// flutter_image_compress 没有 Windows / Linux 实现，桌面调试时该调用会抛
  /// MissingPluginException。桌面端只是本地调试通道，压缩失败不应该阻断上传，
  /// 因此这里吞掉异常并返回 null —— 上层会直接用原图路径继续上传。
  /// Android / iOS / macOS 行为完全不变。
  ///
  /// 返回压缩后的临时文件路径；压缩不可用（或失败）时返回 null。
  Future<String?> _tryCompress(String srcPath, String target) async {
    try {
      final compressed = await FlutterImageCompress.compressAndGetFile(
        srcPath,
        target,
        quality: 80,
        minWidth: 1280,
        minHeight: 1280,
        format: CompressFormat.jpeg,
      );
      return compressed?.path;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _disposed = true;
    stop();
    _changes.close();
    _status.close();
    _notices.close();
  }
}

enum SyncKind { menu, categories, orders, couple, full }

class SyncChange {
  final SyncKind kind;
  SyncChange(this.kind);
  static final full = SyncChange(SyncKind.full);
  static final menu = SyncChange(SyncKind.menu);
  static final categories = SyncChange(SyncKind.categories);
  static final orders = SyncChange(SyncKind.orders);
  static final couple = SyncChange(SyncKind.couple);
}

class SyncStatus {
  final bool inProgress;
  final String? error;
  final DateTime? lastOkAt;
  final int pending;

  const SyncStatus({this.inProgress = false, this.error, this.lastOkAt, this.pending = 0});

  const SyncStatus.idle() : this();

  const SyncStatus.ok(DateTime t, {int pending = 0})
      : inProgress = false,
        error = null,
        lastOkAt = t,
        pending = pending;

  const SyncStatus.error(String msg)
      : inProgress = false,
        error = msg,
        lastOkAt = null,
        pending = 0;

  bool get isOnline => error == null;
  String get label {
    // 别再只说「离线」——那会把网络正常、代码出错的情况也伪装成断网，
    // 直接把真实原因显示出来（过长则截断，避免顶栏溢出）。
    if (error != null) {
      final msg = error!;
      return msg.length <= 14 ? msg : '${msg.substring(0, 14)}…';
    }
    if (pending > 0) return '待同步 $pending';
    return '已同步';
  }
}
