/// 编译期/运行期可改的全局配置
class AppConfig {
  /// 默认服务器地址。
  ///
  /// 用**域名**而不是 IP：换服务器时只改 DNS，已装的 App 不用重装。
  /// 用户也可在登录页「服务器设置」里改成任意自建地址。
  static const defaultBaseUrl = 'https://food.fmcoral.com';

  /// 后端 API 前缀
  static const apiPrefix = '/api';

  /// WS 路径（与 HTTP 接口统一在 /api 下，Nginx 只需代理一个前缀）
  static const wsPath = '/api/ws';

  /// 客户端版本（展示用）
  static const appVersion = '1.0.0';

  /// 轮询兜底间隔：WS 正常时几乎不触发，断线时保证最终一致
  static const syncInterval = Duration(seconds: 20);

  /// WS 心跳
  static const wsPingInterval = Duration(seconds: 25);
}
