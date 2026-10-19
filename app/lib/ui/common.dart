import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_updater.dart';
import '../core/problem.dart';
import '../state/app_state.dart';

extension BuildContextX on BuildContext {
  /// 取 AppState（不订阅）
  AppState get state => read<AppState>();

  void snack(String msg, {bool error = false}) => showSnack(this, msg, error: error);
}

void showSnack(BuildContext c, String msg, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(c);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(c).colorScheme.error : null,
      duration: Duration(seconds: error ? 4 : 2),
    ));
}

/// 统一异常提示：所有 async 操作都套一层
Future<bool> runGuarded(BuildContext c, Future<void> Function() action,
    {String? success, bool showAuthError = false}) async {
  try {
    await action();
    if (success != null && c.mounted) showSnack(c, success);
    return true;
  } on ApiProblem catch (e) {
    // 401 默认静默（避免后台 token 过期时到处弹提示），
    // 但登录/注册这类"就是要靠 401 报账号密码错"的场景要显式放行，见 showAuthError。
    if (c.mounted && (showAuthError || !e.isUnauthorized)) {
      showSnack(c, e.friendly, error: true);
    }
    return false;
  } catch (e) {
    if (c.mounted) showSnack(c, '$e', error: true);
    return false;
  }
}

/// 检查更新（发现新版就下载并拉起系统安装器）
///
/// [manual] = true 是用户主动点「检查更新」，要有明确反馈（检查中 / 已是最新）；
/// false 是启动时的静默检查，没有新版就当无事发生。
/// Windows 端 [AppUpdater.check] 恒返回 null，所以桌面版这里是空操作。
Future<void> checkForUpdate(BuildContext context, {bool manual = false}) async {
  final updater = AppUpdater();
  try {
    if (manual) showSnack(context, '正在检查更新…');
    final info = await updater.check();
    if (!context.mounted) return;
    if (info == null) {
      if (manual) showSnack(context, '已是最新版本');
      return;
    }
    final go = await _askUpdate(context, info);
    if (!go || !context.mounted) return;
    await _downloadAndInstall(context, updater, info);
  } finally {
    updater.dispose();
  }
}

/// 更新提示弹窗。force 时不给「稍后」的出口。
Future<bool> _askUpdate(BuildContext context, UpdateInfo info) async {
  final body = (info.notes ?? '').trim();
  if (!info.force) {
    return confirm(context,
        title: '发现新版本 ${info.versionName}',
        body: body.isEmpty ? '建议更新到最新版本。' : body,
        okText: '立即更新');
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: Text('发现新版本 ${info.versionName}'),
      content: Text(body.isEmpty ? '需要更新后才能继续使用。' : body),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          style: FilledButton.styleFrom(minimumSize: const Size(88, 42)),
          child: const Text('立即更新'),
        ),
      ],
    ),
  );
  return true;
}

/// 带进度的下载 → 拉起安装器。下载中不给关闭对话框（半包没法用）。
Future<void> _downloadAndInstall(
    BuildContext context, AppUpdater updater, UpdateInfo info) async {
  final progress = ValueNotifier<double>(0);
  // 用 NavigatorState 而不是弹窗的 BuildContext：跨 await 后 pop 不会踩
  // use_build_context_synchronously；PopScope 挡住返回键，保证「谁开谁关」。
  final nav = Navigator.of(context, rootNavigator: true);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在下载更新'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: v <= 0 ? null : v),
              ),
              const SizedBox(height: 12),
              Text(v <= 0 ? '正在连接…' : '已下载 ${(v * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    ),
  ));

  try {
    final file = await updater.download(info, onProgress: (v) => progress.value = v);
    nav.pop();
    await updater.installApk(file);
  } catch (e) {
    nav.pop();
    if (context.mounted) showSnack(context, '更新失败：$e', error: true);
  } finally {
    progress.dispose();
  }
}

/// 空状态占位
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 36, color: scheme.primary),
            ),
            const SizedBox(height: 18),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant, height: 1.5)),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// 加载态
class Loading extends StatelessWidget {
  const Loading({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.4)),
            if (label != null) ...[
              const SizedBox(height: 12),
              Text(label!, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ],
        ),
      );
}

/// 同步状态小徽标（顶栏右上）
class SyncBadge extends StatefulWidget {
  const SyncBadge({super.key});

  @override
  State<SyncBadge> createState() => _SyncBadgeState();
}

class _SyncBadgeState extends State<SyncBadge> {
  StreamSubscription? _sub;
  bool _online = false;
  String _label = '';

  @override
  void initState() {
    super.initState();
    final st = context.read<AppState>();
    _sub = st.sync.status.listen((s) {
      if (!mounted) return;
      setState(() {
        _online = s.isOnline;
        _label = s.label;
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_label.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final color = _online ? scheme.primary : scheme.error;
    return GestureDetector(
      onTap: () => context.state.sync.syncNow(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(_label, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

/// 通用确认弹窗
Future<bool> confirm(BuildContext context,
    {required String title, String? body, String okText = '确定', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(c).colorScheme.error,
                  minimumSize: const Size(88, 42),
                )
              : FilledButton.styleFrom(minimumSize: const Size(88, 42)),
          child: Text(okText),
        ),
      ],
    ),
  );
  return r == true;
}

/// 单行文本输入弹窗
Future<String?> promptText(BuildContext context,
    {required String title, String? hint, String? initial, int maxLength = 40}) async {
  final ctrl = TextEditingController(text: initial ?? '');
  final r = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: maxLength,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(c, ctrl.text.trim()),
          style: FilledButton.styleFrom(minimumSize: const Size(88, 42)),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return (r == null || r.isEmpty) ? null : r;
}

/// 分类小标签
class TagChip extends StatelessWidget {
  const TagChip(this.text, {super.key, this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = color ?? scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: base), const SizedBox(width: 3)],
          Text(text, style: TextStyle(fontSize: 11.5, color: base, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
