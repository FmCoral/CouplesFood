import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'problem.dart';

/// 会话与本地偏好
///
/// token 存 secure storage（Android Keystore 加密）；
/// 服务器地址存 SharedPreferences，因为登录前就要能读到。
class Session {
  static const _kAccess = 'access_token';
  static const _kRefresh = 'refresh_token';
  static const _kUserId = 'user_id';
  static const _kNickname = 'nickname';
  static const _kPhone = 'phone';
  static const _kIsAdmin = 'is_admin';
  static const _kBaseUrl = 'base_url';
  static const _kDeviceId = 'device_id';

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  SharedPreferences? _prefs;
  String? _access;
  String? _refresh;

  String userId = '';
  String nickname = '';
  String phone = '';
  bool isAdmin = false;

  /// 当前设备标识：注册/登录时上传，刷新令牌时绑定
  String deviceId = '';

  /// 服务器地址（可改）
  String baseUrl = '';

  bool get isLoggedIn => _access != null && _access!.isNotEmpty;
  String? get accessToken => _access;
  String? get refreshToken => _refresh;

  /// 登录/刷新成功后由 ApiClient 调用
  void applyTokens({
    required String access,
    String? refresh,
    String? newUserId,
    String? newNickname,
    String? newPhone,
    bool? newIsAdmin,
  }) {
    _access = access;
    if (refresh != null) _refresh = refresh;
    if (newUserId != null) userId = newUserId;
    if (newNickname != null) nickname = newNickname;
    if (newPhone != null) phone = newPhone;
    if (newIsAdmin != null) isAdmin = newIsAdmin;
    _persist();
  }

  Future<void> _persist() async {
    if (_access != null) await _secure.write(key: _kAccess, value: _access);
    if (_refresh != null) await _secure.write(key: _kRefresh, value: _refresh);
    final p = _prefs;
    if (p != null) {
      await p.setString(_kUserId, userId);
      await p.setString(_kNickname, nickname);
      await p.setString(_kPhone, phone);
      await p.setBool(_kIsAdmin, isAdmin);
    }
  }

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _access = await _secure.read(key: _kAccess);
    _refresh = await _secure.read(key: _kRefresh);
    userId = _prefs!.getString(_kUserId) ?? '';
    nickname = _prefs!.getString(_kNickname) ?? '';
    phone = _prefs!.getString(_kPhone) ?? '';
    isAdmin = _prefs!.getBool(_kIsAdmin) ?? false;
    baseUrl = _prefs!.getString(_kBaseUrl) ?? '';
    deviceId = _prefs!.getString(_kDeviceId) ?? '';

    // 设备标识只生成一次，重装才会变（后端用它做刷新令牌绑定）
    if (deviceId.isEmpty) {
      deviceId = _newDeviceId();
      await _prefs!.setString(_kDeviceId, deviceId);
    }
  }

  static String _newDeviceId() {
    // 不引额外依赖：时间戳 + 安全随机数足够区分设备
    final rnd = Random.secure();
    final suffix = List.generate(8, (_) => rnd.nextInt(36).toRadixString(36)).join();
    return 'and-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    await _prefs?.setString(_kBaseUrl, baseUrl);
  }

  Future<void> clear() async {
    _access = null;
    _refresh = null;
    userId = '';
    nickname = '';
    phone = '';
    isAdmin = false;
    await _secure.delete(key: _kAccess);
    await _secure.delete(key: _kRefresh);
    final p = _prefs;
    if (p != null) {
      await p.remove(_kUserId);
      await p.remove(_kNickname);
      await p.remove(_kPhone);
      await p.remove(_kIsAdmin);
    }
  }

  /// 便于调试时导出（不含 token）
  Map<String, dynamic> toDebugMap() => {
        'userId': userId,
        'nickname': nickname,
        'isAdmin': isAdmin,
        'baseUrl': baseUrl,
        'deviceId': deviceId,
      };

  static ApiProblem unauthorized() => ApiProblem(
        type: 'about:blank',
        title: 'UNAUTHORIZED',
        status: 401,
        detail: '登录已过期，请重新登录',
      );

  /// 从 JWT 里读 claims（不验签，仅用于本地判断）
  static Map<String, dynamic> claimsOf(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return {};
      final payload = base64Url.normalize(parts[1]);
      return jsonDecode(utf8.decode(base64Url.decode(payload))) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
