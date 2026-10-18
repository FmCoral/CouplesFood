import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    {String? success}) async {
  try {
    await action();
    if (success != null && c.mounted) showSnack(c, success);
    return true;
  } on ApiProblem catch (e) {
    if (c.mounted && !e.isUnauthorized) showSnack(c, e.friendly, error: true);
    return false;
  } catch (e) {
    if (c.mounted) showSnack(c, '$e', error: true);
    return false;
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
