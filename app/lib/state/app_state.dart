import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/problem.dart';
import '../core/session.dart';
import '../data/local_db.dart';
import '../data/sync_engine.dart';
import '../data/ws_client.dart';

/// 全局应用状态
///
/// 把 session / api / db / sync / ws 串起来，并负责：
/// - 启动时的引导（读本地 token → 校验 → 拉数据）
/// - 绑定关系后的**静默换 token**（这是最容易漏的一步）
class AppState extends ChangeNotifier {
  late final Session session;
  late final ApiClient api;
  late final LocalDb db;
  late final SyncEngine sync;
  late final WsClient ws;

  bool booted = false;
  bool loading = false;
  String? bootError;

  /// 同步引擎是否已就绪（bootstrap 完成后才可用）
  bool get syncReady => booted && sync.didInit;

  CoupleInfo? couple;

  List<Dish> dishes = [];
  List<Map<String, dynamic>> types = [];
  List<Map<String, dynamic>> flavors = [];
  List<Order> orders = [];

  StreamSubscription? _wsSub;
  StreamSubscription? _changeSub;

  bool get isLoggedIn => session.isLoggedIn;
  bool get hasCouple => couple != null && couple!.status == 'active';
  bool get isFrozen => couple?.isFrozen ?? false;

  Future<void> bootstrap() async {
    loading = true;
    notifyListeners();

    session = Session();
    await session.load();

    api = ApiClient(session);
    db = LocalDb();
    await db.open();

    sync = SyncEngine(api: api, db: db);
    ws = WsClient(api: api, session: session);

    api.onSessionExpired = () async {
      await logout(keepBaseUrl: true);
    };
    api.onSessionRefreshed = () => ws.reconnect();

    _changeSub = sync.changes.listen((_) => _reloadFromLocal());
    _wsSub = ws.events.listen((e) {
      final type = e['type']?.toString() ?? '';
      if (type.startsWith('dish.')) {
        sync.refreshMenu();
      } else if (type.startsWith('order.')) {
        sync.refreshOrders().then((_) => _reloadFromLocal());
      } else if (type.startsWith('couple.')) {
        // 绑定成功 / 解散进度：重新拉关系，必要时换 token
        refreshCouple().then((_) {
          if (type == 'couple.bound') _silentRefreshTokens();
        });
      }
    });

    if (session.isLoggedIn) {
      try {
        await refreshCouple();
        await sync.refreshMenu();
        await sync.refreshOrders();
        _reloadFromLocal();
        sync.start();
        ws.connect();
      } on ApiProblem catch (e) {
        if (e.isUnauthorized) {
          await logout(keepBaseUrl: true);
        } else {
          bootError = e.friendly;
          // 离线也能进主界面看本地缓存
          _reloadFromLocal();
          sync.start();
        }
      }
    }

    booted = true;
    loading = false;
    notifyListeners();
  }

  // ---------------- 认证 ----------------

  Future<void> login({required String phone, required String password, required String nickname}) async {
    final res = await api.post<Map<String, dynamic>>('/auth/login', {
      'phone': phone,
      'password': password,
      'deviceId': session.deviceId,
    });
    session.applyTokens(
      access: res['accessToken'] as String,
      refresh: res['refreshToken'] as String,
      newUserId: res['userId'] as String?,
      newNickname: nickname.isEmpty ? null : nickname,
      newPhone: phone,
      newIsAdmin: _isAdminToken(res['accessToken'] as String),
    );
    await _afterLogin();
  }

  Future<void> register({required String phone, required String password, required String nickname}) async {
    final res = await api.post<Map<String, dynamic>>('/auth/register', {
      'phone': phone,
      'password': password,
      'nickname': nickname,
      'deviceId': session.deviceId,
    });
    session.applyTokens(
      access: res['accessToken'] as String,
      refresh: res['refreshToken'] as String,
      newUserId: res['userId'] as String?,
      newNickname: nickname,
      newPhone: phone,
      newIsAdmin: _isAdminToken(res['accessToken'] as String),
    );
    await _afterLogin();
  }

  bool _isAdminToken(String jwt) => Session.claimsOf(jwt)['adm'] == true;

  Future<void> _afterLogin() async {
    await refreshCouple();
    if (hasCouple) {
      await sync.refreshMenu();
      await sync.refreshOrders();
      _reloadFromLocal();
    }
    if (!session.isAdmin) {
      sync.start();
      ws.connect();
    }
    notifyListeners();
  }

  Future<void> logout({bool keepBaseUrl = false}) async {
    try {
      await api.post<void>('/auth/logout');
    } catch (_) {}
    sync.stop();
    ws.disconnect();
    await session.clear();
    await db.clearAll();
    couple = null;
    dishes = [];
    types = [];
    flavors = [];
    orders = [];
    notifyListeners();
  }

  // ---------------- 关系 ----------------

  Future<void> refreshCouple() async {
    try {
      final res = await api.get<Map<String, dynamic>?>('/couples/me');
      couple = res == null ? null : CoupleInfo.fromJson(res, session.userId);
    } on ApiProblem catch (e) {
      if (e.isForbidden || e.isNotFound) {
        couple = null;
      } else {
        rethrow;
      }
    }
    notifyListeners();
  }

  /// 生成邀请码，返回 { code, expiresAt }
  Future<Map<String, dynamic>> createInvite() async {
    final res = await api.post<Map<String, dynamic>>('/couples/invite');
    return res;
  }

  /// 输入邀请码绑定。**B 的 token 会被换发**（这里会自动应用）
  Future<void> joinCouple(String code) async {
    final res = await api.post<Map<String, dynamic>>('/couples/join', {
      'inviteCode': code,
      'deviceId': session.deviceId,
    });
    session.applyTokens(
      access: res['accessToken'] as String,
      refresh: res['refreshToken'] as String,
    );
    await refreshCouple();
    await sync.refreshMenu();
    await sync.refreshOrders();
    _reloadFromLocal();
    sync.start();
    ws.connect();
    notifyListeners();
  }

  /// A 侧：收到 couple.bound 后必须换发 token，否则 coupleId 仍是 null
  Future<void> _silentRefreshTokens() async {
    final rt = session.refreshToken;
    if (rt == null) return;
    try {
      final res = await api.post<Map<String, dynamic>>('/auth/refresh', {'refreshToken': rt});
      session.applyTokens(
        access: res['accessToken'] as String,
        refresh: res['refreshToken'] as String,
      );
      ws.reconnect();
      await refreshCouple();
      await sync.refreshMenu();
    } catch (_) {
      // 失败无妨，下次请求 401 时会自动再试
    }
  }

  Future<void> requestDissolve({String? reason}) async {
    await api.post<Map<String, dynamic>>('/couples/dissolve/request', {
      if (reason != null && reason.isNotEmpty) 'reason': reason,
    });
    await refreshCouple();
  }

  Future<void> approveDissolve(String requestId) async {
    await api.post<Map<String, dynamic>>('/couples/dissolve/$requestId/approve');
    await refreshCouple();
  }

  Future<void> rejectDissolve(String requestId) async {
    await api.post<Map<String, dynamic>>('/couples/dissolve/$requestId/reject');
    await refreshCouple();
  }

  Future<void> withdrawDissolve(String requestId) async {
    await api.post<Map<String, dynamic>>('/couples/dissolve/$requestId/withdraw');
    await refreshCouple();
  }

  Future<void> setRoleLabel(String? label) async {
    await api.patch<Map<String, dynamic>>('/couples/role', {'roleLabel': label});
    await refreshCouple();
  }

  // ---------------- 菜单 ----------------

  void _reloadFromLocal() {
    db.allDishes().then((v) {
      dishes = v;
      notifyListeners();
    });
    db.allOrders().then((v) {
      orders = v;
      notifyListeners();
    });
    db.categories('type').then((v) {
      types = v;
      notifyListeners();
    });
    db.categories('flavor').then((v) {
      flavors = v;
      notifyListeners();
    });
  }

  Dish? dishOf(String id) {
    for (final d in dishes) {
      if (d.id == id) return d;
    }
    return null;
  }

  Order? orderOf(String id) {
    for (final o in orders) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// 昵称等只在本地改的字段，改完手动通知一次
  void notifyNow() => notifyListeners();

  List<Order> get activeOrders => orders.where((o) => o.isOpen).toList();

  // ---------------- 图片 ----------------

  Future<String> uploadImage(String path) async {
    final res = await sync.compressAndUpload(path);
    return (res['imageKey'] ?? '').toString();
  }

  String imageUrlOf(Dish d) {
    if (d.imageUrl != null && d.imageUrl!.isNotEmpty) return api.mediaUrl(d.imageKey, directUrl: d.imageUrl);
    return api.mediaUrl(d.imageKey);
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _changeSub?.cancel();
    sync.dispose();
    ws.dispose();
    api.dispose();
    super.dispose();
  }
}
