import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_editor.dart';
import 'dish_photo.dart';

/// 菜单页：浏览 + 加菜进购物车 → 底部「立即下单」
///
/// 菜品编辑（增删改）已迁移到「我的 → 菜单管理」，这里只负责点菜。
class MenuPage extends StatefulWidget {
  const MenuPage({super.key});

  @override
  State<MenuPage> createState() => _MenuPageState();
}

class _MenuPageState extends State<MenuPage> {
  String? _typeId; // null = 全部
  final Set<String> _flavorIds = {};
  String _keyword = '';
  bool _searching = false;
  final _searchCtrl = TextEditingController();

  /// 购物车：dishId -> 份数
  final Map<String, int> _cart = {};
  final Map<String, String> _itemNotes = {};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Dish> _filter(List<Dish> all) {
    final kw = _keyword.trim().toLowerCase();
    return all.where((d) {
      if (_typeId != null && d.typeId != _typeId) return false;
      if (_flavorIds.isNotEmpty && !_flavorIds.every(d.flavorIds.contains)) return false;
      if (kw.isNotEmpty) {
        final hit = d.name.toLowerCase().contains(kw) ||
            (d.note ?? '').toLowerCase().contains(kw) ||
            d.tags.any((t) => t.toLowerCase().contains(kw));
        if (!hit) return false;
      }
      return true;
    }).toList();
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

  Future<void> _openEditor([Dish? dish]) async {
    if (context.read<AppState>().isFrozen) {
      context.snack('解散申请处理中，暂时不能修改菜单', error: true);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DishEditor(dish: dish)),
    );
  }

  /// 底部「立即下单」弹层：选餐次 + 留言 + 确认
  Future<void> _showCheckout() async {
    if (_cart.isEmpty) return;
    final s = context.read<AppState>();
    if (s.isFrozen) {
      context.snack('解散申请处理中，暂时不能下单', error: true);
      return;
    }

    // 根据当前时间自动推测餐次：5-10 早餐，10-14 午餐，14-21 晚餐，其余夜宵
    final h = DateTime.now().hour;
    String mealType = h >= 5 && h < 10
        ? 'breakfast'
        : h >= 10 && h < 14
            ? 'lunch'
            : h >= 14 && h < 21
                ? 'dinner'
                : 'night_snack';
    final noteCtrl = TextEditingController();
    bool submitting = false;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) {
        return StatefulBuilder(
          builder: (c, setSheet) => Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 8,
              bottom: MediaQuery.of(c).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('确认下单',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(c, false),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // 已选菜品
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    children: [
                      for (final e in _cart.entries)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  s.dishOf(e.key)?.name ?? '',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                              Text('×${e.value}',
                                  style: TextStyle(
                                      fontSize: 13.5,
                                      color: Theme.of(c).colorScheme.onSurfaceVariant)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // 餐次
                Text('餐次',
                    style: TextStyle(
                        fontSize: 12.5, color: Theme.of(c).colorScheme.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in const [
                      ['breakfast', '早餐'],
                      ['lunch', '午餐'],
                      ['dinner', '晚餐'],
                      ['night_snack', '夜宵'],
                      ['other', '其他'],
                    ])
                      _MiniPill(
                        label: m[1],
                        selected: mealType == m[0],
                        onTap: () => setSheet(() => mealType = m[0]),
                      ),
                  ],
                ),
                const SizedBox(height: 14),

                // 留言
                TextField(
                  controller: noteCtrl,
                  maxLength: 200,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    hintText: '想说的话（选填）',
                    counterText: '',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),

                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: submitting
                        ? null
                        : () async {
                            setSheet(() => submitting = true);
                            final done = await createOrder(
                              c,
                              s,
                              cart: Map.of(_cart),
                              itemNotes: Map.of(_itemNotes),
                              mealType: mealType,
                              note: noteCtrl.text.trim(),
                            );
                            if (done && c.mounted) {
                              Navigator.pop(c, true);
                            } else if (c.mounted) {
                              setSheet(() => submitting = false);
                            }
                          },
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                    child: submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text('下单 · $_totalQty 份'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    noteCtrl.dispose();
    if (ok == true && mounted) {
      setState(() {
        _cart.clear();
        _itemNotes.clear();
      });
      context.snack('已下单，等对方接单');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final dishes = _filter(s.dishes);
    final filtered = _typeId != null || _flavorIds.isNotEmpty || _keyword.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜菜名、备注、标签',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _keyword = v),
              )
            : Row(
                children: [
                  const Text('菜单'),
                  if (s.dishes.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text('${s.dishes.length}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: scheme.onSurfaceVariant)),
                  ],
                ],
              ),
        actions: [
          const Center(
              child: Padding(padding: EdgeInsets.only(right: 4), child: SyncBadge())),
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search, size: 21),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _keyword = '';
                  _searchCtrl.clear();
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            typeId: _typeId,
            flavorIds: _flavorIds,
            onTypeChanged: (v) => setState(() => _typeId = v == _typeId ? null : v),
            onFlavorToggled: (id) => setState(() {
              if (!_flavorIds.remove(id)) _flavorIds.add(id);
            }),
            onClear: () => setState(() {
              _typeId = null;
              _flavorIds.clear();
            }),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await s.sync.refreshMenu().catchError((_) {});
                await s.sync.refreshOrders().catchError((_) {});
              },
              child: dishes.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(
                          height: MediaQuery.of(context).size.height * 0.55,
                          child: s.dishes.isEmpty
                              ? EmptyState(
                                  icon: Icons.ramen_dining_outlined,
                                  title: '菜单还是空的',
                                  subtitle: '把你俩会做的菜加进来，\n另一半点菜时就能看到。',
                                  action: s.isFrozen
                                      ? null
                                      : FilledButton(
                                          onPressed: () => _openEditor(),
                                          style: FilledButton.styleFrom(
                                              minimumSize: const Size(150, 46)),
                                          child: const Text('加第一道菜'),
                                        ),
                                )
                              : EmptyState(
                                  icon: Icons.filter_alt_off_outlined,
                                  title: '没有符合条件的菜',
                                  subtitle: '换个筛选条件试试',
                                  action: filtered
                                      ? TextButton(
                                          onPressed: () => setState(() {
                                            _typeId = null;
                                            _flavorIds.clear();
                                            _keyword = '';
                                            _searchCtrl.clear();
                                          }),
                                          child: const Text('清除筛选'),
                                        )
                                      : null,
                                ),
                        ),
                      ],
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.68,
                      ),
                      itemCount: dishes.length,
                      itemBuilder: (c, i) => _DishCard(
                        dish: dishes[i],
                        qty: _cart[dishes[i].id] ?? 0,
                        onAdd: () => _bump(dishes[i], 1),
                        onRemove: () => _bump(dishes[i], -1),
                      ),
                    ),
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
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -3),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.shopping_basket_outlined, size: 28, color: scheme.primary),
                  if (_totalQty > 0)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.error,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$_totalQty',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('已选 $_totalQty 份',
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    Text('${_cart.length} 种菜',
                        style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              FilledButton(
                onPressed: _showCheckout,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(120, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: const Text('立即下单'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 筛选条 ----------------

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.typeId,
    required this.flavorIds,
    required this.onTypeChanged,
    required this.onFlavorToggled,
    required this.onClear,
  });

  final String? typeId;
  final Set<String> flavorIds;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onFlavorToggled;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;

    if (s.types.isEmpty && s.flavors.isEmpty) return const SizedBox(height: 6);

    String nameOf(Map<String, dynamic> m) => (m['name'] ?? '').toString();
    String idOf(Map<String, dynamic> m) => (m['id'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 种类：单选
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                _Pill(
                  label: '全部',
                  selected: typeId == null,
                  onTap: () {
                    if (typeId != null) onTypeChanged(typeId!);
                  },
                ),
                for (final t in s.types)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _Pill(
                      label: nameOf(t),
                      selected: typeId == idOf(t),
                      onTap: () => onTypeChanged(idOf(t)),
                    ),
                  ),
              ],
            ),
          ),
          // 口味：多选
          if (s.flavors.isNotEmpty)
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: Text('口味',
                          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                    ),
                  ),
                  for (final f in s.flavors)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Pill(
                        label: nameOf(f),
                        selected: flavorIds.contains(idOf(f)),
                        compact: true,
                        onTap: () => onFlavorToggled(idOf(f)),
                      ),
                    ),
                  if (typeId != null || flavorIds.isNotEmpty)
                    TextButton(
                      onPressed: onClear,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      child: const Text('清除', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: EdgeInsets.symmetric(horizontal: compact ? 11 : 14, vertical: 0),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.7),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: compact ? 12 : 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? Colors.white : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

// ---------------- 菜品卡片 ----------------

class _DishCard extends StatelessWidget {
  const _DishCard({
    required this.dish,
    required this.qty,
    required this.onAdd,
    required this.onRemove,
  });

  final Dish dish;
  final int qty;
  final VoidCallback onAdd;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final url = s.imageUrlOf(dish);
    final disabled = !dish.isAvailable;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1.32,
            child: Stack(
              fit: StackFit.expand,
              children: [
                DishPhoto(url: url, name: dish.name),
                if (disabled)
                  Container(
                    color: Colors.black.withValues(alpha: 0.42),
                    alignment: Alignment.center,
                    child: const Text('已下架',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dish.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                SizedBox(
                  height: 20,
                  child: (dish.typeName == null && dish.flavorNames.isEmpty)
                      ? Text(
                          dish.note?.isNotEmpty == true ? dish.note! : '未分类',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5, color: scheme.onSurfaceVariant),
                        )
                      : ListView(
                          scrollDirection: Axis.horizontal,
                          children: [
                            if (dish.typeName != null)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: TagChip(dish.typeName!),
                              ),
                            for (final f in dish.flavorNames.take(2))
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: TagChip(f, color: scheme.tertiary),
                              ),
                          ],
                        ),
                ),
                const SizedBox(height: 8),
                // 加减号控件
                if (disabled)
                  const SizedBox(height: 28)
                else if (qty == 0)
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: onAdd,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.add, size: 16, color: Colors.white),
                      ),
                    ),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      _RoundBtn(icon: Icons.remove, onTap: onRemove),
                      SizedBox(
                        width: 28,
                        child: Text('$qty',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                      _RoundBtn(icon: Icons.add, onTap: onAdd, filled: true),
                    ],
                  ),
              ],
            ),
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
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: filled ? scheme.primary : scheme.primary.withValues(alpha: 0.10),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 15, color: filled ? Colors.white : scheme.primary),
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? scheme.primary : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant.withValues(alpha: 0.7)),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 13,
              color: selected ? Colors.white : scheme.onSurface,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            )),
      ),
    );
  }
}
