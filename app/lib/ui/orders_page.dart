import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_photo.dart';
import 'order_compose_page.dart';

/// 订单页：进行中 / 历史
class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  bool _showDone = false;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();

    final list = _showDone
        ? s.orders.where((o) => o.isDone).toList()
        : s.orders.where((o) => o.isOpen).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('订单'),
        actions: [
          const Center(
              child: Padding(padding: EdgeInsets.only(right: 4), child: SyncBadge())),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(44),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(
              children: [
                _Seg(
                  label: '进行中',
                  count: s.orders.where((o) => o.isOpen).length,
                  selected: !_showDone,
                  onTap: () => setState(() => _showDone = false),
                ),
                const SizedBox(width: 8),
                _Seg(
                  label: '历史',
                  selected: _showDone,
                  onTap: () => setState(() => _showDone = true),
                ),
                const Spacer(),
                if (!s.isFrozen)
                  TextButton.icon(
                    onPressed: () async {
                      final created = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(builder: (_) => const OrderComposePage()),
                      );
                      if (created == true) setState(() => _showDone = false);
                    },
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('点菜', style: TextStyle(fontSize: 13)),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await s.sync.refreshOrders().catchError((_) {});
        },
        child: list.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: EmptyState(
                      icon: _showDone ? Icons.history : Icons.receipt_long_outlined,
                      title: _showDone ? '还没有完成的订单' : '没有进行中的订单',
                      subtitle: _showDone ? null : '想吃什么，从菜单里点几道吧',
                      action: _showDone || s.isFrozen
                          ? null
                          : FilledButton(
                              onPressed: () async {
                                final created = await Navigator.of(context).push<bool>(
                                  MaterialPageRoute(
                                      builder: (_) => const OrderComposePage()),
                                );
                                if (created == true) setState(() => _showDone = false);
                              },
                              style:
                                  FilledButton.styleFrom(minimumSize: const Size(150, 46)),
                              child: const Text('去点菜'),
                            ),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (c, i) => _OrderCard(
                  order: list[i],
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => OrderDetailPage(orderId: list[i].id)),
                  ),
                ),
              ),
      ),
      floatingActionButton: _showDone || s.isFrozen
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                final created = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(builder: (_) => const OrderComposePage()),
                );
                if (created == true) setState(() => _showDone = false);
              },
              icon: const Icon(Icons.restaurant),
              label: const Text('点菜'),
            ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count = 0,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          count > 0 ? '$label $count' : label,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 状态色：待接单最需要被看到
Color statusColor(ColorScheme scheme, String status) => switch (status) {
      'pending' => scheme.primary,
      'accepted' || 'cooking' => const Color(0xFFD98324),
      'served' => const Color(0xFF3F8C6E),
      'completed' => scheme.onSurfaceVariant,
      'rejected' || 'cancelled' => scheme.outline,
      _ => scheme.onSurfaceVariant,
    };

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order, required this.onTap});

  final Order order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final mine = order.requesterId == s.session.userId;
    final color = statusColor(scheme, order.status);

    // 待我处理：对方点的、还没接单
    final needsMe = !mine && order.status == 'pending';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: needsMe
              ? Border.all(color: scheme.primary.withValues(alpha: 0.45), width: 1.4)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(order.statusLabel,
                      style: TextStyle(
                          fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                Text(order.mealTypeLabel,
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const Spacer(),
                Text(
                  mine ? '我点的' : '${s.couple?.partner?.nickname ?? "对方"}点的',
                  style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              order.summary.isEmpty ? '（无明细）' : order.summary,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5, height: 1.4),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text('共 ${order.totalQuantity} 份',
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                const Spacer(),
                Text(_ago(order.createdAt),
                    style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 16, color: scheme.outline),
              ],
            ),
            if (needsMe) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _quickTransition(context, order, 'accepted'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                        textStyle: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                      ),
                      child: const Text('接单'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _quickTransition(context, order, 'rejected'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                        foregroundColor: scheme.error,
                        textStyle: const TextStyle(fontSize: 13.5),
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _ago(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays < 30) return '${d.inDays} 天前';
  return '${t.month}月${t.day}日';
}

Future<void> _quickTransition(BuildContext context, Order o, String to) async {
  final s = context.read<AppState>();
  if (to == 'rejected') {
    final note = await promptText(context,
        title: '拒绝这个订单', hint: '说一句原因（选填）', maxLength: 200);
    if (!context.mounted) return;
    await runGuarded(context, () => s.sync.transitionOrder(o.id, to, o.version, replyNote: note));
  } else {
    await runGuarded(
      context,
      () => s.sync.transitionOrder(o.id, to, o.version),
      success: '已接单',
    );
  }
  await s.sync.refreshOrders().catchError((_) {});
}

// ================= 订单详情 =================

class OrderDetailPage extends StatefulWidget {
  const OrderDetailPage({super.key, required this.orderId});
  final String orderId;

  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  bool _busy = false;

  Future<void> _transition(String to, {String? replyNote}) async {
    final s = context.read<AppState>();
    final o = s.orderOf(widget.orderId);
    if (o == null) return;

    setState(() => _busy = true);
    await runGuarded(context, () async {
      await s.sync.transitionOrder(o.id, to, o.version, replyNote: replyNote);
      await s.sync.refreshOrders();
    });
    if (mounted) setState(() => _busy = false);
  }

  /// 当前用户在这个订单上能做的动作
  List<_Action> _actionsFor(Order o, String myId) {
    final isRequester = o.requesterId == myId;
    final acts = <_Action>[];
    switch (o.status) {
      case 'pending':
        if (isRequester) {
          acts.add(_Action('取消订单', 'cancelled', danger: true));
        } else {
          acts.add(_Action('接单', 'accepted', primary: true));
          acts.add(_Action('拒绝', 'rejected', danger: true));
        }
        break;
      case 'accepted':
        if (isRequester) {
          acts.add(_Action('取消订单', 'cancelled', danger: true));
        } else {
          acts.add(_Action('开始做', 'cooking', primary: true));
          acts.add(_Action('做不了', 'rejected', danger: true));
        }
        break;
      case 'cooking':
        if (!isRequester) acts.add(_Action('做好了', 'served', primary: true));
        break;
      case 'served':
        if (isRequester) acts.add(_Action('确认收到', 'completed', primary: true));
        break;
    }
    return acts;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final o = s.orderOf(widget.orderId);

    if (o == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('订单')),
        body: const EmptyState(icon: Icons.search_off, title: '订单不存在或已被清空'),
      );
    }

    final mine = o.requesterId == s.session.userId;
    final partnerName = s.couple?.partner?.nickname ?? '对方';
    final actions = _actionsFor(o, s.session.userId);
    final color = statusColor(scheme, o.status);

    return Scaffold(
      appBar: AppBar(title: const Text('订单详情')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // ---- 状态头 ----
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(_statusIcon(o.status), color: color, size: 30),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(o.statusLabel,
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700, color: color)),
                      const SizedBox(height: 3),
                      Text(
                        _statusHint(o, mine, partnerName),
                        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ---- 菜品 ----
          Text('菜品', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final it in o.items)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: DishPhoto(
                            url: s.api.mediaUrl(it.imageKey),
                            name: it.name,
                            radius: 9,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(it.name,
                                  style: const TextStyle(
                                      fontSize: 14.5, fontWeight: FontWeight.w500)),
                              if ((it.note ?? '').isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text('「${it.note}」',
                                      style: TextStyle(
                                          fontSize: 11.5, color: scheme.primary)),
                                ),
                            ],
                          ),
                        ),
                        Text('×${it.quantity}',
                            style: TextStyle(
                                fontSize: 13.5, color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // ---- 备注 ----
          if ((o.requestNote ?? '').isNotEmpty) ...[
            Text('留言', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(o.requestNote!,
                  style: const TextStyle(fontSize: 14, height: 1.55)),
            ),
            const SizedBox(height: 18),
          ],
          if ((o.replyNote ?? '').isNotEmpty) ...[
            Text('对方回复', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(o.replyNote!,
                  style: const TextStyle(fontSize: 14, height: 1.55)),
            ),
            const SizedBox(height: 18),
          ],

          // ---- 时间线 ----
          _Timeline(order: o, partnerName: partnerName),
          const SizedBox(height: 24),

          // ---- 操作按钮 ----
          for (final a in actions) ...[
            if (a.primary)
              FilledButton(
                onPressed: _busy ? null : () => _do(a),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(a.label),
              )
            else
              OutlinedButton(
                onPressed: _busy ? null : () => _do(a),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  foregroundColor: a.danger ? scheme.error : null,
                  side: a.danger
                      ? BorderSide(color: scheme.error.withValues(alpha: 0.5))
                      : null,
                ),
                child: Text(a.label),
              ),
            const SizedBox(height: 10),
          ],
          if (s.isFrozen && actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('解散申请处理中，暂时不能操作订单',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
        ],
      ),
    );
  }

  Future<void> _do(_Action a) async {
    String? note;
    if (a.to == 'rejected' || a.to == 'cancelled') {
      final ok = await confirm(context,
          title: a.to == 'rejected' ? '确定拒绝？' : '确定取消？',
          body: a.to == 'rejected' ? '对方会收到通知。' : '取消后这个订单就结束了。',
          okText: a.to == 'rejected' ? '拒绝' : '取消订单',
          danger: true);
      if (!ok || !mounted) return;
      if (a.to == 'rejected') {
        note = await promptText(context, title: '说一句原因（选填）', maxLength: 200);
        if (!mounted) return;
      }
    }
    await _transition(a.to, replyNote: note);
  }

  IconData _statusIcon(String s) => switch (s) {
        'pending' => Icons.mark_email_unread_outlined,
        'accepted' => Icons.check_circle_outline,
        'cooking' => Icons.soup_kitchen_outlined,
        'served' => Icons.room_service_outlined,
        'completed' => Icons.task_alt,
        'rejected' => Icons.block,
        'cancelled' => Icons.cancel_outlined,
        _ => Icons.info_outline,
      };

  String _statusHint(Order o, bool mine, String partner) => switch (o.status) {
        'pending' => mine ? '等 $partner 接单' : '$partner 点了这些，看一下能不能做',
        'accepted' => mine ? '$partner 已接单' : '已接单，记得开始做',
        'cooking' => mine ? '$partner 正在做' : '做好了点「做好了」',
        'served' => mine ? '出餐啦，确认收到吧' : '等 $partner 确认',
        'completed' => '这一单完成了',
        'rejected' => mine ? '$partner 拒绝了这一单' : '你拒绝了这一单',
        'cancelled' => '订单已取消',
        _ => '',
      };
}

class _Action {
  const _Action(this.label, this.to, {this.primary = false, this.danger = false});
  final String label;
  final String to;
  final bool primary;
  final bool danger;
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.order, required this.partnerName});
  final Order order;
  final String partnerName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    String t(DateTime? d) => d == null
        ? ''
        : '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    final rows = <(String, DateTime?)>[
      ('下单', order.createdAt),
      ('接单', order.acceptedAt),
      ('出餐', order.servedAt),
      ('完成', order.completedAt),
    ].where((e) => e.$2 != null).toList();

    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('进度', style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration:
                            BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Text(r.$1, style: const TextStyle(fontSize: 13)),
                      const Spacer(),
                      Text(t(r.$2),
                          style:
                              TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
