import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api_client.dart';
import '../core/config.dart';
import '../core/session.dart';

/// WebSocket 长连接
///
/// - 连上后 10s 内必须发 auth，否则服务端断（4001/4003）
/// - 每 25s 发一次业务 ping，服务端同时还有 30s 的协议级 ping
/// - 断开后指数退避重连（1s → 30s 上限）
class WsClient {
  WsClient({required this.api, required this.session});

  final ApiClient api;
  final Session session;

  WebSocketChannel? _ch;
  StreamSubscription? _sub;
  Timer? _ping;
  Timer? _reconnect;
  int _backoff = 1;
  bool _closed = false;
  bool _authed = false;

  /// 收到服务端事件
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// 连接状态变化（UI 显示小圆点）
  final _conn = StreamController<bool>.broadcast();
  Stream<bool> get connected => _conn.stream;

  bool get isConnected => _authed;

  void connect() {
    if (_closed) return;
    _reconnect?.cancel();
    disconnect();

    final wsBase =
        AppConfig.defaultBaseUrl.replaceFirst(RegExp(r'^http'), 'ws');
    final uri = Uri.parse('$wsBase${AppConfig.wsPath}');

    try {
      final ch = IOWebSocketChannel.connect(
        uri,
        pingInterval: const Duration(seconds: 30),
        connectTimeout: const Duration(seconds: 12),
      );
      _ch = ch;

      _sub = ch.stream.listen(
        _onMessage,
        onDone: _onDone,
        onError: (_) => _onDone(),
        cancelOnError: true,
      );

      // 连上立刻认证（服务端 10s 超时会断）
      final token = session.accessToken;
      if (token != null && token.isNotEmpty) {
        ch.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      }

      _ping = Timer.periodic(AppConfig.wsPingInterval, (_) {
        try {
          _ch?.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is Map<String, dynamic>) msg = decoded;
    } catch (_) {
      return;
    }
    if (msg == null) return;

    switch (msg['type']) {
      case 'ready':
        _authed = true;
        _backoff = 1;
        _conn.add(true);
        break;
      case 'pong':
        break;
      default:
        // 业务事件：{ id, type: 'dish.created', payload, version }
        if (msg.containsKey('entityId') || msg['type'].toString().contains('.')) {
          _events.add(msg);
        }
    }
  }

  void _onDone() {
    _authed = false;
    _conn.add(false);
    _cleanup();
    _scheduleReconnect();
  }

  void _cleanup() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    _ch?.sink.close();
    _ch = null;
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _reconnect?.cancel();
    final delay = Duration(seconds: _backoff);
    _backoff = (_backoff * 2).clamp(1, 30);
    _reconnect = Timer(delay, () {
      // token 可能已刷新，重连会用最新的
      connect();
    });
  }

  /// token 刷新后调用：重连以带上新 token
  void reconnect() {
    if (_closed) return;
    _backoff = 1;
    connect();
  }

  void disconnect() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _authed = false;
  }

  void dispose() {
    _closed = true;
    _reconnect?.cancel();
    disconnect();
    _events.close();
    _conn.close();
  }
}
