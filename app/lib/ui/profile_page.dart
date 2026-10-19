import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
          // ---- 我们：两人的头像分列左右，中间两条交织曲线 ----
          if (partner == null)
            _SoloCard(
              name: s.session.nickname,
              subtitle: s.session.phone,
              tint: scheme.primary,
              roleLabel: s.couple?.myRoleLabel,
              action: IconButton(
                icon: const Icon(Icons.edit_outlined, size: 19),
                tooltip: '修改昵称',
                onPressed: () => _editNickname(context, s),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.fromLTRB(12, 18, 12, 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _PersonColumn(
                      name: s.session.nickname.isEmpty ? '我' : s.session.nickname,
                      subtitle: s.session.phone,
                      tint: scheme.primary,
                      roleLabel: s.couple?.myRoleLabel,
                      action: IconButton(
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        tooltip: '修改昵称',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _editNickname(context, s),
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 74,
                    height: 56,
                    child: _InterwovenCurves(),
                  ),
                  Expanded(
                    child: _PersonColumn(
                      name: partner.nickname,
                      subtitle: _sinceText(s.couple?.boundAt),
                      tint: scheme.tertiary,
                      roleLabel: partner.roleLabel,
                      alignEnd: true,
                      action: TextButton(
                        onPressed: () => _editRoleLabel(context, s),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 30),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('我的称呼', style: TextStyle(fontSize: 12.5)),
                      ),
                    ),
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
              icon: Icons.system_update_outlined,
              label: '检查更新',
              trailing: s.appVersion.isEmpty ? '—' : s.appVersion,
              onTap: () => checkForUpdate(context, manual: true),
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
        ],
      ),
    );
  }

  static Future<void> _editNickname(BuildContext context, AppState s) async {
    final name = await promptText(context,
        title: '修改昵称', initial: s.session.nickname, maxLength: 20);
    if (name == null || !context.mounted) return;
    await runGuarded(context, () async {
      await s.api.patch<Map<String, dynamic>>('/auth/me', {'nickname': name});
      s.session.nickname = name;
      await s.refreshCouple();
      s.notifyNow();
    }, success: '已更新昵称');
  }

  static Future<void> _editRoleLabel(BuildContext context, AppState s) async {
    final label = await promptText(
      context,
      title: '在关系里的称呼',
      hint: '比如 老婆 / 老公 / 大厨',
      initial: s.couple?.myRoleLabel,
      maxLength: 12,
    );
    if (!context.mounted) return;
    await runGuarded(context, () => s.setRoleLabel(label), success: '已设置');
  }

  static String _sinceText(DateTime? t) {
    if (t == null) return '已绑定';
    final days = DateTime.now().difference(t).inDays;
    if (days <= 0) return '今天刚绑定';
    if (days < 30) return '已在一起 $days 天';
    return '已在一起 ${(days / 30).floor()} 个月';
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

/// 一侧的人：头像 + 昵称 + 副标题 +（可选）关系称呼 +（可选）操作。
/// [alignEnd] 为 true 时整体贴右（另一半），false 贴左（我）。
class _PersonColumn extends StatelessWidget {
  const _PersonColumn({
    required this.name,
    required this.subtitle,
    required this.tint,
    this.roleLabel,
    this.action,
    this.alignEnd = false,
  });

  final String name;
  final String subtitle;
  final Color tint;
  final String? roleLabel;
  final Widget? action;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final align = alignEnd ? Alignment.centerRight : Alignment.centerLeft;
    final textAlign = alignEnd ? TextAlign.right : TextAlign.left;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(alignment: align, child: _Avatar(name: name, size: 56, tint: tint)),
        const SizedBox(height: 9),
        Text(
          name,
          textAlign: textAlign,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
        ),
        if ((roleLabel ?? '').isNotEmpty) ...[
          const SizedBox(height: 5),
          Align(
            alignment: align,
            child: TagChip(roleLabel!, color: alignEnd ? scheme.tertiary : null),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          subtitle,
          textAlign: textAlign,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        if (action != null) ...[
          const SizedBox(height: 2),
          Align(alignment: align, child: action!),
        ],
      ],
    );
  }
}

/// 还没有另一半时的单人卡片（生成邀请码后的过渡态）
class _SoloCard extends StatelessWidget {
  const _SoloCard({
    required this.name,
    required this.subtitle,
    required this.tint,
    this.roleLabel,
    this.action,
  });

  final String name;
  final String subtitle;
  final Color tint;
  final String? roleLabel;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _Avatar(name: name, size: 54, tint: tint),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? '我' : name,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(subtitle,
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    if ((roleLabel ?? '').isNotEmpty) ...[
                      const SizedBox(width: 8),
                      TagChip(roleLabel!),
                    ],
                  ],
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// 两条交织的正弦曲线：纯装饰，两端不与头像相接。
class _InterwovenCurves extends StatelessWidget {
  const _InterwovenCurves();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CustomPaint(
      size: Size.infinite,
      painter: _CurvesPainter(
        colors: [
          scheme.primary.withValues(alpha: 0.7),
          scheme.tertiary.withValues(alpha: 0.7),
        ],
      ),
    );
  }
}

class _CurvesPainter extends CustomPainter {
  _CurvesPainter({required this.colors});

  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final mid = h / 2;
    final amp = h * 0.24;
    final left = w * 0.06; // 两端留空隙：曲线不碰到左右头像
    final right = w * 0.94;
    const steps = 48;

    for (var k = 0; k < 2; k++) {
      final sign = k == 0 ? -1.0 : 1.0;
      final paint = Paint()
        ..color = colors[k]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round;
      final path = Path();
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final x = left + (right - left) * t;
        // 两条相位相反的正弦曲线：中间交叉两次，形成交织感
        final y = mid + sign * amp * math.cos(2 * math.pi * t);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_CurvesPainter oldDelegate) => oldDelegate.colors != colors;
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
