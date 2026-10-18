import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'problem.dart';
import 'session.dart';

/// HTTP 封装
///
/// 三条约定：
/// 1. 后端统一信封 `{ "data": ... }`，这里只把 data 拆出来给上层
/// 2. 401 时自动用 refresh token 换新 token 并**重放原请求**，调用方无感
/// 3. 所有失败都转成 [ApiProblem]，不抛裸异常给 UI
class ApiClient {
  ApiClient(this.session);

  final Session session;

  final _http = http.Client();
  Future<bool>? _refreshing;

  /// 刷新成功后的回调（SyncEngine 需要重连 WS）
  void Function()? onSessionRefreshed;
  void Function()? onSessionExpired;

  String get _base {
    final b = session.baseUrl.isNotEmpty ? session.baseUrl : AppConfig.defaultBaseUrl;
    return b.replaceAll(RegExp(r'/+$'), '');
  }

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final q = query?.entries
        .where((e) => e.value != null)
        .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}')
        .join('&');
    return Uri.parse('$_base${AppConfig.apiPrefix}$path${(q == null || q.isEmpty) ? '' : '?$q'}');
  }

  // ---------------- 公共方法 ----------------

  Future<T> get<T>(String path, {Map<String, dynamic>? query}) async =>
      _send<T>('GET', path, query: query);

  Future<T> post<T>(String path, [Object? body]) async =>
      _send<T>('POST', path, body: body);

  Future<T> patch<T>(String path, [Object? body]) async =>
      _send<T>('PATCH', path, body: body);

  Future<T> delete<T>(String path) async => _send<T>('DELETE', path);

  // ---------------- 核心 ----------------

  Future<T> _send<T>(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    bool isRetry = false,
  }) async {
    final uri = _uri(path, query);
    final headers = <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      if (session.accessToken != null) 'Authorization': 'Bearer ${session.accessToken}',
    };

    http.Response resp;
    try {
      final req = http.Request(method, uri)..headers.addAll(headers);
      if (body != null) req.body = jsonEncode(body);
      final streamed = await _http.send(req).timeout(const Duration(seconds: 20));
      resp = await http.Response.fromStream(streamed);
    } on TimeoutException {
      throw ApiProblem.network('网络超时，请检查连接');
    } on SocketException {
      throw ApiProblem.network('连不上服务器，请检查网络');
    } on HttpException catch (e) {
      throw ApiProblem.network('网络错误：${e.message}');
    }

    // 401 → 尝试静默刷新后重放一次
    if (resp.statusCode == 401 && !isRetry && session.refreshToken != null) {
      final ok = await _ensureRefreshed();
      if (ok) {
        return _send<T>(method, path, body: body, query: query, isRetry: true);
      }
      onSessionExpired?.call();
      throw _parseError(resp);
    }

    if (resp.statusCode >= 400) throw _parseError(resp);

    if (resp.body.isEmpty) return null as T;
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    if (decoded is Map && decoded.containsKey('data')) {
      return decoded['data'] as T;
    }
    // 同步接口返回 { data, cursor }，这里把整体给回去
    return decoded as T;
  }

  /// 并发请求同时 401 时，只发一次刷新
  Future<bool> _ensureRefreshed() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final rt = session.refreshToken;
    if (rt == null || rt.isEmpty) return false;
    try {
      final resp = await _http
          .post(
            _uri('/auth/refresh'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'refreshToken': rt}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return false;
      final data = jsonDecode(utf8.decode(resp.bodyBytes))['data'] as Map<String, dynamic>;
      session.applyTokens(
        access: data['accessToken'] as String,
        refresh: data['refreshToken'] as String?,
      );
      onSessionRefreshed?.call();
      return true;
    } catch (_) {
      return false;
    }
  }

  ApiProblem _parseError(http.Response resp) {
    try {
      final j = jsonDecode(utf8.decode(resp.bodyBytes));
      if (j is Map<String, dynamic>) return ApiProblem.fromJson(j);
      return ApiProblem(
        type: 'about:blank',
        title: 'HTTP_${resp.statusCode}',
        status: resp.statusCode,
        detail: j.toString(),
      );
    } catch (_) {
      return ApiProblem(
        type: 'about:blank',
        title: 'HTTP_${resp.statusCode}',
        status: resp.statusCode,
        detail: resp.body.isEmpty ? '服务器无响应' : resp.body.substring(0, resp.body.length.clamp(0, 200)),
      );
    }
  }

  // ---------------- 上传（multipart） ----------------

  /// 上传图片，返回 { imageKey, imageUrl }
  Future<Map<String, dynamic>> uploadImage(String filePath) async {
    final uri = _uri('/uploads');
    try {
      final req = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${session.accessToken}'
        ..files.add(await http.MultipartFile.fromPath('file', filePath));
      final streamed = await req.send().timeout(const Duration(seconds: 60));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode >= 400) {
        if (resp.statusCode == 401) {
          final ok = await _ensureRefreshed();
          if (ok) return await uploadImage(filePath);
        }
        throw _parseError(resp);
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      return (decoded['data'] ?? decoded) as Map<String, dynamic>;
    } on ApiProblem {
      rethrow;
    } on TimeoutException {
      throw ApiProblem.network('图片上传超时，请检查网络');
    } on SocketException {
      throw ApiProblem.network('连不上服务器，图片稍后自动重传');
    }
  }

  /// 拼接图片完整地址（后端可能给相对路径）
  String mediaUrl(String? key, {String? directUrl}) {
    if (directUrl != null && directUrl.isNotEmpty) {
      if (directUrl.startsWith('http')) return directUrl;
      return '$_base$directUrl';
    }
    if (key == null || key.isEmpty) return '';
    if (key.startsWith('http')) return key;
    return '$_base/media/$key';
  }

  void dispose() => _http.close();
}
