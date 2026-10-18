/// 编译期常量配置
///
/// 服务器地址在这里写死，App 内**不提供**修改入口。
/// 理由：
/// 1. 用域名而不是 IP，换服务器只改 DNS 解析，已装 App 无感；
/// 2. 用户可改的地址框是个假逃生门——真出问题时用户也不知道该填什么，
///    反而给自己留了一个「被引导到仿冒服务器」的入口；
/// 3. 少一个入口就少一类「填错后登录不上又改不回来」的售后。
class AppConfig {
  /// 服务器地址（唯一来源）
  static const defaultBaseUrl = 'https://food.fmcoral.com';

  /// 后端 API 前缀
  static const apiPrefix = '/api';

  /// WS 路径（与 HTTP 接口统一在 /api 下，Nginx 只需代理一个前缀）
  static const wsPath = '/api/ws';

  /// 客户端版本（展示用）
  static const appVersion = '1.0.1';

  /// 轮询兜底间隔：WS 正常时几乎不触发，断线时保证最终一致
  static const syncInterval = Duration(seconds: 20);

  /// WS 心跳
  static const wsPingInterval = Duration(seconds: 25);
}
