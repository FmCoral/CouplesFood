import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'common.dart';

/// 解散申请面板
///
/// 分三种视角：
///   1. 没有申请 → 发起（需二次确认，说明后果）
///   2. 对方发起 → 同意 / 拒绝
///   3. 我发起   → 撤回 / 等对方
Future<void> showDissolveSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
      child: _DissolveSheet(),
    ),
  );
}

class _DissolveSheet extends StatefulWidget {
  @override
  State<_DissolveSheet> createState() => _DissolveSheetState();
}

class _DissolveSheetState extends State<_DissolveSheet> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    final ok = await runGuarded(context, action, success: success);
    if (mounted) setState(() => _busy = false);
    if (ok && mounted && success != null) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final couple = s.couple;
    final d = couple?.dissolution;

    // 申请已经不存在了（对方撤回/同意），直接关掉
    if (couple != null && couple.status == 'active' && d == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---------- 无申请 ----------
            if (d == null) ...[
              Icon(Icons.heart_broken_outlined, size: 34, color: scheme.error),
              const SizedBox(height: 14),
              const Text('解除关系',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                '解除需要对方同意，你一个人发起不会立刻生效。\n\n'
                '申请发出后菜单会立刻变成只读，双方都不能再改。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, height: 1.65, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              ..._bullets(scheme),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: _busy ? null : () => _request(context, s),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('申请解除关系'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('再想想'),
              ),
            ]

            // ---------- 我发起，等对方 ----------
            else if (couple!.iInitiatedDissolution) ...[
              Icon(Icons.hourglass_top_rounded, size: 34, color: scheme.tertiary),
              const SizedBox(height: 14),
              const Text('等待对方回应',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                '你已发出解除关系的申请，'
                '${s.couple?.partner?.nickname ?? "对方"} 同意后才会正式解除。\n\n'
                '在对方回应之前，菜单保持只读。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, height: 1.65, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => s.withdrawDissolve(d.requestId),
                        success: '已撤回，菜单恢复可编辑'),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('撤回申请'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ]

            // ---------- 对方发起，等我 ----------
            else ...[
              Icon(Icons.warning_amber_rounded, size: 34, color: scheme.error),
              const SizedBox(height: 14),
              const Text('对方的解除申请',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text(
                '${s.couple?.partner?.nickname ?? "对方"} 想解除关系。\n\n'
                '同意后关系立即解除，双方的菜单和订单会被归档保存；'
                '之后你们各自都可以重新绑定。\n\n'
                '拒绝则恢复原样，菜单立刻可以继续编辑。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13, height: 1.65, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _approve(context, s, d.requestId),
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('同意解除'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() => s.rejectDissolve(d.requestId),
                        success: '已拒绝，关系继续'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46)),
                child: const Text('拒绝'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _bullets(ColorScheme scheme) {
    const items = [
      ('菜单变只读', '申请期间双方都不能加菜、改菜、下单'),
      ('同意后归档', '菜品和订单会保留归档，不会被删除'),
      ('可以重新绑定', '解除后你俩都能各自找新的或者重新绑'),
      ('对方不回应', '申请会一直挂着，你也可以随时撤回'),
    ];
    return [
      for (final it in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(Icons.circle, size: 6, color: scheme.outline),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(
                        fontSize: 12.8, height: 1.55, color: scheme.onSurface),
                    children: [
                      TextSpan(
                          text: '${it.$1}　',
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      TextSpan(
                          text: it.$2,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Future<void> _request(BuildContext context, AppState s) async {
    final ok = await confirm(
      context,
      title: '确认发起解除？',
      body: '发出后菜单立刻变成只读，需要对方同意才会真正解除。你也可以在对方回应前撤回。',
      okText: '确认发起',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _run(() => s.requestDissolve(), success: '已发起，等待对方回应');
  }

  Future<void> _approve(BuildContext context, AppState s, String requestId) async {
    final ok = await confirm(
      context,
      title: '确认解除关系？',
      body: '解除后菜单和订单会归档保存，你可以重新绑定。这个操作不能撤销。',
      okText: '解除',
      danger: true,
    );
    if (!ok || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await s.approveDissolve(requestId);
      if (!mounted) return;
      Navigator.of(context).maybePop();
      // 关系已解除，Gate 会把界面切回绑定页
      messenger.showSnackBar(const SnackBar(content: Text('关系已解除')));
    } catch (e) {
      if (mounted) showSnack(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
