import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

  /// 当前客户端版本，启动时从 pubspec（打包进安装包的版本信息）读取，
  /// 例：1.0.4+5。避免像以前那样在代码里再写一份、忘记同步。
  String appVersion = '';

  List<Dish> dishes = [];
  List<Map<String, dynamic>> types = [];
  List<Map<String, dynamic>> flavors = [];
  List<Order> orders = [];

  StreamSubscription? _wsSub;
  StreamSubscription? _changeSub;

  /// 未绑定期间的轮询：生成邀请码的一方在绑定前 WS 会被服务端拒绝，
  /// 收不到 couple.bound，只能靠它主动发现绑定
  Timer? _couplePoll;
  bool _polling = false;
  bool _tokenSwapping = false;

  /// 本地缓存归属的关系 id。换关系后必须整库清空：菜品/订单在刷新时只做
  /// upsert、从不删除本地多出的行，两张表也没有 couple_id 可用于过滤，
  /// 若不清就会残留上一段关系的菜，且两端残留不同 → 菜单不同步。
  static const _cacheOwnerKey = 'cache_couple_id';

  /// 需要弹给用户看的提示（如同步冲突），由 UI 层订阅后统一 SnackBar
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;
  StreamSubscription? _noticeSub;

  bool get isLoggedIn => session.isLoggedIn;
  bool get hasCouple => couple != null && couple!.status == 'active';
  bool get isFrozen => couple?.isFrozen ?? false;

  Future<void> bootstrap() async {
    loading = true;
    notifyListeners();

    session = Session();
    await session.load();

    // 版本号唯一真相源是 pubspec：运行时读取，UI 只展示、不再硬编码
    try {
      final info = await PackageInfo.fromPlatform();
      // 只展示 versionName（如 2.0.0）；versionCode（+11）是 Android
      // 覆盖更新用的内部整数，不展示。
      appVersion = info.version;
    } catch (_) {
      // 读不到就留空，UI 兜底显示 —
    }

    api = ApiClient(session);
    db = LocalDb();
    await db.open();

    sync = SyncEngine(api: api, db: db);
    ws = WsClient(api: api, session: session);

    // 同步引擎里需要让用户看见的提示（如离线冲突）转发给 UI
    _noticeSub = sync.notices.listen(_notices.add);

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

    // 关系变过（含从无到有、从旧到新）就清掉上一段关系的本地残留
    await _ensureCacheOwner();

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
          // 启动时拉取失败也必须连 WS：否则离线启动的用户网络恢复后收不到实时推送；
          // 未绑定用户更是收不到 couple.bound，绑定流程会静默断掉。
          if (!session.isAdmin) ws.connect();
        }
      }
    }

    booted = true;
    loading = false;
    _syncCoupleWatch();
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
    _syncCoupleWatch();
    notifyListeners();
  }

  Future<void> logout({bool keepBaseUrl = false}) async {
    try {
      await api.post<void>('/auth/logout');
    } catch (_) {}
    sync.stop();
    ws.disconnect();
    _stopCoupleWatch();
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
    _syncCoupleWatch();
    notifyListeners();
  }

  /// 未绑定（或服务端还没把 coupleId 写进 token）时才需要盯着关系变化
  bool get _needsCoupleWatch => couple == null || _tokenCoupleId == null;

  /// 当前 access token 里的 coupleId（null = 还没有关系）
  String? get _tokenCoupleId {
    final t = session.accessToken;
    if (t == null || t.isEmpty) return null;
    final c = Session.claimsOf(t)['coupleId'];
    return c is String && c.isNotEmpty ? c : null;
  }

  /// 保证本地缓存与当前关系一致：关系变了就整库清空并重记归属。
  ///
  /// 为什么必须在这里清：`SyncEngine.refreshMenu/refreshOrders` 只 upsert，
  /// 从不删除本地多出的行；本地 dishes/orders 表也没有 couple_id 可过滤。
  /// 不清的后果就是上一段关系的菜/订单一直残留，且两台设备残留不同 →
  /// 表现为「双方菜单不同步」。
  Future<void> _ensureCacheOwner() async {
    final owner = _tokenCoupleId ?? '';
    final cached = await db.kvGet(_cacheOwnerKey) ?? '';
    if (cached == owner) return;

    await db.clearAll(); // 连 outbox / cursor 一并归零，避免旧事件游标串到新关系
    if (owner.isNotEmpty) await db.kvSet(_cacheOwnerKey, owner);
    dishes = [];
    types = [];
    flavors = [];
    orders = [];
  }

  void _syncCoupleWatch() {
    if (!session.isLoggedIn || session.isAdmin) {
      _stopCoupleWatch();
      return;
    }
    if (_needsCoupleWatch) {
      _startCoupleWatch();
    } else {
      _stopCoupleWatch();
    }
  }

  void _startCoupleWatch() {
    if (_couplePoll != null) return;
    _couplePoll = Timer.periodic(const Duration(seconds: 4), (_) => _pollCoupleOnce());
  }

  void _stopCoupleWatch() {
    _couplePoll?.cancel();
    _couplePoll = null;
  }

  /// 轮询一次关系：一旦服务端出现关系，立刻换 token 并刷新数据。
  ///
  /// 为什么必须轮询：生成邀请码的一方此时 token 里 coupleId 还是 null，
  /// WS 连上就被服务端以 4003 关掉，收不到 couple.bound；若只依赖实时推送，
  /// 就必须重进软件（等 token 过期触发 401 刷新）才生效。
  Future<void> _pollCoupleOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      final res = await api.get<Map<String, dynamic>?>('/couples/me');
      if (res == null) return; // 还没被绑定，下一轮再看
      await _silentRefreshTokens(); // 换出带 coupleId 的 token，并刷新菜单/订单
    } catch (_) {
      // 离线或未绑定：下一轮继续
    } finally {
      _polling = false;
    }
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
    // 换成了新关系：先清掉上一段关系的本地残留，再拉新菜单
    await _ensureCacheOwner();
    await refreshCouple();
    await sync.refreshMenu();
    await sync.refreshOrders();
    _reloadFromLocal();
    sync.start();
    ws.connect();
    _syncCoupleWatch();
    notifyListeners();
  }

  /// A 侧：收到 couple.bound 后必须换发 token，否则 coupleId 仍是 null
  Future<void> _silentRefreshTokens() async {
    if (_tokenSwapping) return;
    final rt = session.refreshToken;
    if (rt == null) return;
    _tokenSwapping = true;
    try {
      final res = await api.post<Map<String, dynamic>>('/auth/refresh', {'refreshToken': rt});
      session.applyTokens(
        access: res['accessToken'] as String,
        refresh: res['refreshToken'] as String,
      );
      ws.reconnect();
      // 新 token 带上了 coupleId（刚被绑定时）：同样要先清旧关系残留
      await _ensureCacheOwner();
      await refreshCouple();
      await sync.refreshMenu();
      await sync.refreshOrders();
      _reloadFromLocal();
    } catch (_) {
      // 失败无妨，下次请求 401 时会自动再试
    } finally {
      _tokenSwapping = false;
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

  /// 从后台回到前台：挂起期间 WS 的定时器会被掐断，立刻重连而不是干等退避
  void onAppResumed() {
    if (!session.isLoggedIn || session.isAdmin) return;
    ws.reconnect();
    _pollCoupleOnce();
  }

  @override
  void dispose() {
    _stopCoupleWatch();
    _wsSub?.cancel();
    _changeSub?.cancel();
    _noticeSub?.cancel();
    _notices.close();
    sync.dispose();
    ws.dispose();
    api.dispose();
    super.dispose();
  }
}
