import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'config.dart';

/// 服务端下发的更新清单（/dl/latest.json 里的 android 段）
class UpdateInfo {
  const UpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.url,
    this.notes,
    this.force = false,
  });

  /// 整数版本号，与安装包的 versionCode 一一对应，比较最可靠
  final int versionCode;
  final String versionName;
  final String url;
  final String? notes;
  final bool force;
}

/// 应用内更新：拉清单 → 比版本 → 流式下载 → 拉起系统安装器
///
/// 只在 Android 生效；Windows 端按平台短路（[check] 直接返回 null），
/// 不影响桌面调试与打包。
///
/// 清单是站点根下的**静态文件**，不走 /api 前缀，也不经过后端，
/// 所以这里自己持有一个 http.Client，不掺和 [ApiClient] 的 401 重放逻辑。
class AppUpdater {
  AppUpdater({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  static final _manifestUri =
      Uri.parse('${AppConfig.defaultBaseUrl}/dl/latest.json');

  /// 检查是否有新版本。
  ///
  /// 网络不通、超时、清单格式不对、字段缺失…… 一律当作「没有更新」，
  /// 静默返回 null —— 检查更新失败不该打扰用户，更不该拦住 App 启动。
  Future<UpdateInfo?> check() async {
    if (!Platform.isAndroid) return null;
    try {
      final res = await _http
          .get(_manifestUri, headers: const {'Cache-Control': 'no-cache'})
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;

      final map = jsonDecode(utf8.decode(res.bodyBytes));
      if (map is! Map) return null;
      final a = map['android'];
      if (a is! Map) return null;

      final info = UpdateInfo(
        versionCode: int.tryParse('${a['versionCode']}') ?? 0,
        versionName: '${a['versionName'] ?? ''}',
        url: '${a['url'] ?? ''}',
        notes: a['notes'] == null ? null : '${a['notes']}',
        force: a['force'] == true,
      );
      if (info.url.isEmpty) return null;

      final pkg = await PackageInfo.fromPlatform();
      final localCode = int.tryParse(pkg.buildNumber);

      // 首选 versionCode 比大小；万一安装包或清单里没写，退回比 versionName
      final bool newer = (localCode != null && info.versionCode > 0)
          ? info.versionCode > localCode
          : _compareVersion(info.versionName, pkg.version) > 0;
      return newer ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// 流式下载 APK 到应用内部 cache 目录，返回落盘文件。
  ///
  /// [onProgress] 回调 0~1；拿不到 Content-Length 时不回调（无法算比例）。
  Future<File> download(UpdateInfo info, {void Function(double)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/couple-menu-${info.versionName}.apk');
    if (await file.exists()) await file.delete();

    final res = await _http.send(http.Request('GET', Uri.parse(info.url)));
    if (res.statusCode != 200) {
      throw Exception('下载失败（HTTP ${res.statusCode}）');
    }

    final total = res.contentLength ?? 0;
    var got = 0;
    final sink = file.openWrite();
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress?.call(got / total);
      }
    } finally {
      await sink.close();
    }

    // 字节数对不上说明被截断，宁可报错也不把坏包丢给安装器
    if (total > 0 && got != total) {
      await file.delete();
      throw Exception('下载不完整（$got/$total 字节）');
    }
    return file;
  }

  /// 拉起系统安装器。
  ///
  /// 用户点「安装」后系统会覆盖安装并结束本进程；这里只负责把安装界面唤起来。
  Future<void> installApk(File file) async {
    final r = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    if (r.type != ResultType.done) {
      throw Exception(r.message.isEmpty ? '无法唤起安装器' : r.message);
    }
  }

  void dispose() => _http.close();
}

/// 逐段比较 x.y.z，返回 -1/0/1；非数字段按 0 处理
int _compareVersion(String a, String b) {
  List<int> parse(String v) => v
      .split('.')
      .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
  final x = parse(a), y = parse(b);
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final xi = i < x.length ? x[i] : 0;
    final yi = i < y.length ? y[i] : 0;
    if (xi != yi) return xi > yi ? 1 : -1;
  }
  return 0;
}
