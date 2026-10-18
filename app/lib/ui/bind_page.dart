import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/problem.dart';
import '../state/app_state.dart';
import '../ui/common.dart';

/// 绑定页：生成邀请码（A）或输入邀请码（B）
///
/// 两条路都在这一个页面，靠 TabLayout 切换——比"先生成再等着"的引导式流程
/// 更适合两个人各自拿手机操作的场景。
class BindPage extends StatefulWidget {
  const BindPage({super.key});

  @override
  State<BindPage> createState() => _BindPageState();
}

class _BindPageState extends State<BindPage> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('连接另一半'),
        actions: [
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(child: SyncBadge()),
          ),
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout, size: 20),
            onPressed: () async {
              final ok = await confirm(context,
                  title: '退出登录', body: '退出后需要重新输入手机号和密码。', okText: '退出');
              if (ok && context.mounted) await s.logout();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '一个人生成邀请码，另一个人输入即可。绑定后双方共用一份菜单。',
                      style: TextStyle(fontSize: 12.8, height: 1.5, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          TabBar(
            controller: _tab,
            labelColor: scheme.primary,
            unselectedLabelColor: scheme.onSurfaceVariant,
            indicatorColor: scheme.primary,
            indicatorSize: TabBarIndicatorSize.label,
            tabs: const [
              Tab(text: '生成邀请码'),
              Tab(text: '输入邀请码'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                _CreateTab(),
                _JoinTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------- 生成 ----------------

class _CreateTab extends StatefulWidget {
  const _CreateTab();

  @override
  State<_CreateTab> createState() => _CreateTabState();
}

class _CreateTabState extends State<_CreateTab> {
  String? _code;
  DateTime? _expiresAt;
  bool _busy = false;

  Future<void> _generate() async {
    setState(() => _busy = true);
    final s = context.read<AppState>();
    try {
      final r = await s.createInvite();
      if (!mounted) return;
      setState(() {
        _code = r['inviteCode']?.toString();
        _expiresAt = DateTime.tryParse(r['expiresAt']?.toString() ?? '');
      });
    } on ApiProblem catch (e) {
      if (mounted) context.snack(e.friendly, error: true);
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _expireText {
    final t = _expiresAt;
    if (t == null) return '24 小时内有效';
    final d = t.difference(DateTime.now());
    if (d.isNegative) return '已过期，请重新生成';
    final h = d.inHours;
    final m = d.inMinutes % 60;
    return h > 0 ? '${h} 小时 ${m} 分钟后过期' : '${m} 分钟后过期';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_code == null) {
      return EmptyState(
        icon: Icons.qr_code_2,
        title: '生成一个邀请码',
        subtitle: '把它发给对方，对方在「输入邀请码」里填上就能绑定。\n24 小时内有效，随时可重新生成。',
        action: FilledButton(
          onPressed: _busy ? null : _generate,
          style: FilledButton.styleFrom(minimumSize: const Size(180, 48)),
          child: _busy
              ? const SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('生成邀请码'),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Text('把这 6 位数字告诉对方',
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: _code!));
              context.snack('已复制');
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 30),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: scheme.primary.withValues(alpha: 0.25), width: 1.4),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final ch in _code!.split(''))
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: 42,
                          height: 54,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(ch,
                              style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                  color: scheme.primary)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.schedule, size: 13, color: scheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(_expireText,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _code!));
                    context.snack('已复制邀请码');
                  },
                  icon: const Icon(Icons.copy, size: 17),
                  label: const Text('复制'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _generate,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('重新生成'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          _WaitingHint(),
        ],
      ),
    );
  }
}

/// 等待对方输入的提示
class _WaitingHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
              strokeWidth: 1.8, color: scheme.primary.withValues(alpha: 0.5)),
        ),
        const SizedBox(width: 9),
        Text('等待对方输入…绑定成功会自动进入',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

// ---------------- 加入 ----------------

class _JoinTab extends StatefulWidget {
  const _JoinTab();

  @override
  State<_JoinTab> createState() => _JoinTabState();
}

class _JoinTabState extends State<_JoinTab> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _ctrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = '邀请码是 6 位数字');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final s = context.read<AppState>();
    try {
      // 成功后 Gate 会自动切到主壳，这里不需要导航
      await s.joinCouple(code);
    } on ApiProblem catch (e) {
      if (mounted) setState(() => _error = e.friendly);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text('输入对方给你的邀请码',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 22),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: 12),
            decoration: InputDecoration(
              counterText: '',
              hintText: '••••••',
              hintStyle: TextStyle(
                  fontSize: 26,
                  letterSpacing: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.35)),
              errorText: _error,
              contentPadding: const EdgeInsets.symmetric(vertical: 20),
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _busy ? null : _join(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _join,
            child: _busy
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('绑定'),
          ),
          const SizedBox(height: 18),
          Text(
            '绑定后不能单方面解除。\n如需解除，需要在设置里发起申请，对方同意后才会生效。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.6, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
