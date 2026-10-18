import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/config.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'category_manager.dart';
import 'dissolve_sheet.dart';

/// 我的：个人信息、称呼、分类管理、同步、解散、退出
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final partner = s.couple?.partner;
    final frozen = s.isFrozen;

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的'),
        actions: [
          const Center(
              child: Padding(padding: EdgeInsets.only(right: 12), child: SyncBadge())),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          // ---- 我 ----
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                _Avatar(
                  name: s.session.nickname,
                  size: 54,
                  tint: scheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.session.nickname.isEmpty ? '我' : s.session.nickname,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text(s.session.phone,
                              style: TextStyle(
                                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
                          if ((s.couple?.myRoleLabel ?? '').isNotEmpty) ...[
                            const SizedBox(width: 8),
                            TagChip(s.couple!.myRoleLabel!),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 19),
                  tooltip: '修改昵称',
                  onPressed: () async {
                    final name = await promptText(context,
                        title: '修改昵称', initial: s.session.nickname, maxLength: 20);
                    if (name == null || !context.mounted) return;
                    await runGuarded(context, () async {
                      await s.api.patch<Map<String, dynamic>>('/auth/me', {'nickname': name});
                      s.session.nickname = name;
                      await s.refreshCouple();
                      s.notifyNow();
                    }, success: '已更新昵称');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ---- 另一半 ----
          if (partner != null)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  _Avatar(name: partner.nickname, size: 46, tint: scheme.tertiary),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(partner.nickname,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                            if ((partner.roleLabel ?? '').isNotEmpty) ...[
                              const SizedBox(width: 7),
                              TagChip(partner.roleLabel!, color: scheme.tertiary),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _sinceText(s.couple?.boundAt),
                          style:
                              TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final label = await promptText(
                        context,
                        title: '在关系里的称呼',
                        hint: '比如 老婆 / 老公 / 大厨',
                        initial: s.couple?.myRoleLabel,
                        maxLength: 12,
                      );
                      if (!context.mounted) return;
                      await runGuarded(
                        context,
                        () => s.setRoleLabel(label),
                        success: '已设置',
                      );
                    },
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 34),
                    ),
                    child: const Text('我的称呼', style: TextStyle(fontSize: 12.5)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),

          // ---- 菜单设置 ----
          _Group(title: '菜单', children: [
            _Row(
              icon: Icons.category_outlined,
              label: '种类管理',
              trailing: '${s.types.length} 个',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CategoryManager(kind: 'type')),
              ),
            ),
            _Row(
              icon: Icons.local_fire_department_outlined,
              label: '口味管理',
              trailing: '${s.flavors.length} 个',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CategoryManager(kind: 'flavor')),
              ),
            ),
            _Row(
              icon: Icons.sync,
              label: '立即同步',
              trailing: s.sync.current.label,
              onTap: () async {
                await runGuarded(context, () async {
                  await s.sync.syncNow();
                  await s.sync.refreshMenu();
                  await s.sync.refreshOrders();
                }, success: '同步完成');
              },
            ),
          ]),
          const SizedBox(height: 18),

          // ---- 账号 ----
          _Group(title: '账号', children: [
            _Row(
              icon: Icons.lock_outline,
              label: '修改密码',
              onTap: () => _changePassword(context),
            ),
            _Row(
              icon: Icons.dns_outlined,
              label: '服务器地址',
              trailing: _hostOf(s),
              onTap: () => _showServerInfo(context),
            ),
            _Row(
              icon: Icons.info_outline,
              label: '版本',
              trailing: AppConfig.appVersion,
              onTap: null,
            ),
          ]),
          const SizedBox(height: 18),

          // ---- 危险区 ----
          _Group(title: '关系', children: [
            if (frozen)
              _Row(
                icon: Icons.pause_circle_outline,
                label: '解散申请处理中',
                trailing: '查看',
                color: scheme.tertiary,
                onTap: () => showDissolveSheet(context),
              )
            else
              _Row(
                icon: Icons.heart_broken_outlined,
                label: '解除关系',
                trailing: '需对方同意',
                color: scheme.error,
                onTap: () => showDissolveSheet(context),
              ),
            _Row(
              icon: Icons.logout,
              label: '退出登录',
              onTap: () async {
                final ok = await confirm(context,
                    title: '退出登录', body: '退出后本地缓存会清空，重新登录可见。', okText: '退出');
                if (ok && context.mounted) await s.logout();
              },
            ),
          ]),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '数据存在你自己的服务器上\n两个人一份菜单，别人看不到',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, height: 1.7, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  static String _sinceText(DateTime? t) {
    if (t == null) return '已绑定';
    final days = DateTime.now().difference(t).inDays;
    if (days <= 0) return '今天刚绑定';
    if (days < 30) return '已在一起 $days 天';
    return '已在一起 ${(days / 30).floor()} 个月';
  }

  static String _hostOf(AppState s) {
    final b = s.session.baseUrl.isNotEmpty ? s.session.baseUrl : AppConfig.defaultBaseUrl;
    return b.replaceFirst(RegExp(r'^https?://'), '');
  }

  static Future<void> _showServerInfo(BuildContext context) async {
    final s = context.read<AppState>();
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_hostOf(s), style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 10),
            Text(
              'App 里写死的是域名，换服务器时只要改 DNS 解析到新 IP，'
              '已安装的 App 不用重装。',
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: Theme.of(c).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了')),
        ],
      ),
    );
  }

  static Future<void> _changePassword(BuildContext context) async {
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('修改密码'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: oldCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '原密码', isDense: true),
                validator: (v) => (v ?? '').isEmpty ? '请输入原密码' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: newCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码（至少 8 位）', isDense: true),
                validator: (v) =>
                    (v ?? '').length < 8 ? '新密码至少 8 位' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(c, true);
            },
            style: FilledButton.styleFrom(minimumSize: const Size(88, 42)),
            child: const Text('修改'),
          ),
        ],
      ),
    );

    if (ok != true || !context.mounted) {
      oldCtrl.dispose();
      newCtrl.dispose();
      return;
    }

    final s = context.read<AppState>();
    final done = await runGuarded(context, () async {
      await s.api.post<Map<String, dynamic>>('/auth/change-password', {
        'oldPassword': oldCtrl.text,
        'newPassword': newCtrl.text,
      });
    }, success: '密码已修改，请重新登录');

    oldCtrl.dispose();
    newCtrl.dispose();

    // 改密后所有刷新令牌作废，必须重新登录
    if (done && context.mounted) await s.logout();
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size, required this.tint});
  final String name;
  final double size;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final initial = name.isEmpty ? '?' : name.substring(0, 1);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [tint.withValues(alpha: 0.85), tint.withValues(alpha: 0.55)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Text(
        initial,
        style: TextStyle(
            fontSize: size * 0.42, fontWeight: FontWeight.w600, color: Colors.white),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(title,
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                children[i],
                if (i != children.length - 1)
                  Divider(
                    height: 1,
                    indent: 50,
                    color: scheme.outlineVariant.withValues(alpha: 0.45),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final String? trailing;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 19, color: color ?? scheme.onSurfaceVariant),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontSize: 14.5, color: c)),
            const Spacer(),
            if (trailing != null)
              Text(trailing!,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.chevron_right, size: 17, color: scheme.outline),
              ),
          ],
        ),
      ),
    );
  }
}
