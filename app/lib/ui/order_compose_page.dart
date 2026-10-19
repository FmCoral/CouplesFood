import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_photo.dart';

/// 点菜页：从菜单里挑菜 → 下单
///
/// 购物车状态放在页面内，不落库；下单才入 outbox。
/// 断网也能下单，队列会在联网后自动重放。
class OrderComposePage extends StatefulWidget {
  const OrderComposePage({super.key});

  @override
  State<OrderComposePage> createState() => _OrderComposePageState();
}

class _OrderComposePageState extends State<OrderComposePage> {
  /// dishId -> 份数
  final Map<String, int> _cart = {};
  final Map<String, String> _itemNotes = {};
  final _noteCtrl = TextEditingController();

  String _mealType = (() {
    final h = DateTime.now().hour;
    return h >= 5 && h < 10
        ? 'breakfast'
        : h >= 10 && h < 14
            ? 'lunch'
            : h >= 14 && h < 21
                ? 'dinner'
                : 'night_snack';
  })();
  String? _typeId;
  bool _submitting = false;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  int get _totalQty => _cart.values.fold(0, (a, b) => a + b);

  void _bump(Dish d, int delta) {
    setState(() {
      final cur = _cart[d.id] ?? 0;
      final next = cur + delta;
      if (next <= 0) {
        _cart.remove(d.id);
        _itemNotes.remove(d.id);
      } else {
        _cart[d.id] = next.clamp(1, 20);
      }
    });
  }

  Future<void> _submit() async {
    if (_cart.isEmpty) return;
    final s = context.read<AppState>();
    if (s.isFrozen) {
      context.snack('解散申请处理中，暂时不能下单', error: true);
      return;
    }

    setState(() => _submitting = true);

    // 订单 id 在客户端生成：断网重放时后端用它做幂等键
    final orderId = const Uuid().v4();
    final payload = <String, dynamic>{
      'id': orderId,
      'mealType': _mealType,
      'items': [
        for (final e in _cart.entries)
          {
            'dishId': e.key,
            'quantity': e.value,
            if ((_itemNotes[e.key] ?? '').isNotEmpty) 'note': _itemNotes[e.key],
          }
      ],
      if (_noteCtrl.text.trim().isNotEmpty) 'note': _noteCtrl.text.trim(),
    };

    try {
      await s.sync.createOrderOffline(payload);

      // 本地立刻显示一条"待同步"的订单，不让用户干等
      await _writeLocalPending(s, orderId, payload);

      if (!mounted) return;
      Navigator.of(context).pop(true);
      context.snack('已下单，等对方接单');
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 乐观写入：网络失败时用户也能在订单页看到自己刚点的东西
  Future<void> _writeLocalPending(
      AppState s, String orderId, Map<String, dynamic> payload) async {
    String nameOf(String id) => s.dishOf(id)?.name ?? '';
    final order = Order(
      id: orderId,
      status: 'pending',
      mealType: _mealType,
      requestNote: payload['note'] as String?,
      requesterId: s.session.userId,
      version: 1,
      items: [
        for (final it in (payload['items'] as List).cast<Map<String, dynamic>>())
          OrderItem(
            dishId: it['dishId'] as String,
            name: nameOf(it['dishId'] as String),
            imageKey: s.dishOf(it['dishId'] as String)?.imageKey,
            quantity: it['quantity'] as int,
            note: it['note'] as String?,
          )
      ],
      createdAt: DateTime.now(),
    );
    await s.db.upsertOrders([order]);
    s.sync.refreshOrders().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final dishes = s.dishes.where((d) {
      if (!d.isAvailable) return false;
      if (_typeId != null && d.typeId != _typeId) return false;
      return true;
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('点菜'),
        actions: [
          if (_cart.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _cart.clear();
                _itemNotes.clear();
              }),
              child: const Text('清空'),
            ),
        ],
      ),
      body: Column(
        children: [
          // 种类快捷筛选
          if (s.types.isNotEmpty)
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                children: [
                  _MiniPill(
                    label: '全部',
                    selected: _typeId == null,
                    onTap: () => setState(() => _typeId = null),
                  ),
                  for (final t in s.types)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: _MiniPill(
                        label: (t['name'] ?? '').toString(),
                        selected: _typeId == (t['id'] ?? '').toString(),
                        onTap: () {
                          final id = (t['id'] ?? '').toString();
                          setState(() => _typeId = _typeId == id ? null : id);
                        },
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: dishes.isEmpty
                ? const EmptyState(
                    icon: Icons.no_meals_outlined,
                    title: '没有可点的菜',
                    subtitle: '菜单里还没加菜，或者都被下架了',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                    itemCount: dishes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (c, i) {
                      final d = dishes[i];
                      final qty = _cart[d.id] ?? 0;
                      return _DishRow(
                        dish: d,
                        qty: qty,
                        onAdd: () => _bump(d, 1),
                        onRemove: () => _bump(d, -1),
                        onNote: () async {
                          final n = await promptText(
                            context,
                            title: '「${d.name}」的要求',
                            hint: '比如 少放辣',
                            initial: _itemNotes[d.id],
                            maxLength: 100,
                          );
                          if (n != null) setState(() => _itemNotes[d.id] = n);
                        },
                        hasNote: (_itemNotes[d.id] ?? '').isNotEmpty,
                      );
                    },
                  ),
          ),

          // 底部结算条
          if (_cart.isNotEmpty) _checkoutBar(scheme),
        ],
      ),
    );
  }

  Widget _checkoutBar(ColorScheme scheme) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, -3),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 餐次
              Row(
                children: [
                  Text('餐次',
                      style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final m in const [
                            ['breakfast', '早餐'],
                            ['lunch', '午餐'],
                            ['dinner', '晚餐'],
                            ['night_snack', '夜宵'],
                            ['other', '其他'],
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _MiniPill(
                                label: m[1],
                                selected: _mealType == m[0],
                                onTap: () => setState(() => _mealType = m[0]),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _noteCtrl,
                      maxLength: 200,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        hintText: '想说的话（选填）',
                        counterText: '',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(112, 46),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Text('下单 · $_totalQty'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({
    required this.dish,
    required this.qty,
    required this.onAdd,
    required this.onRemove,
    required this.onNote,
    required this.hasNote,
  });

  final Dish dish;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;
  final VoidCallback onNote;
  final bool hasNote;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final url = s.imageUrlOf(dish);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            height: 58,
            child: DishPhoto(url: url, name: dish.name, radius: 10),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dish.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    if (dish.typeName != null) ...[
                      TagChip(dish.typeName!),
                      const SizedBox(width: 5),
                    ],
                    for (final f in dish.flavorNames.take(2)) ...[
                      TagChip(f, color: scheme.tertiary),
                      const SizedBox(width: 4),
                    ],
                    if (hasNote)
                      GestureDetector(
                        onTap: onNote,
                        child: Icon(Icons.sticky_note_2_outlined,
                            size: 14, color: scheme.primary),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (qty == 0)
            IconButton.filledTonal(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 19),
              visualDensity: VisualDensity.compact,
            )
          else
            Row(
              children: [
                _RoundBtn(icon: Icons.remove, onTap: onRemove),
                SizedBox(
                  width: 30,
                  child: Text('$qty',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                _RoundBtn(icon: Icons.add, onTap: onAdd, filled: true),
              ],
            ),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap, this.filled = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: filled ? scheme.primary : scheme.primary.withValues(alpha: 0.10),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: filled ? Colors.white : scheme.primary),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12.5,
              color: selected ? Colors.white : scheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            )),
      ),
    );
  }
}
