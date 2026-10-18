import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_editor.dart';
import 'dish_photo.dart';

/// 菜单页
///
/// 双维度筛选：种类单选 + 口味多选。
/// 口味是"全部命中"（选了「辣」+「重口」只剩两个标签都有的菜），
/// 与后端 `HAVING COUNT(DISTINCT flavor_id) = N` 保持一致。
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

  Future<void> _openEditor([Dish? dish]) async {
    if (context.read<AppState>().isFrozen) {
      context.snack('解散申请处理中，暂时不能修改菜单', error: true);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DishEditor(dish: dish)),
    );
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
      floatingActionButton: s.isFrozen
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('加菜'),
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
                      // 必须可滚动，否则下拉刷新失效
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
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 100),
                      physics: const AlwaysScrollableScrollPhysics(),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.78,
                      ),
                      itemCount: dishes.length,
                      itemBuilder: (c, i) => _DishCard(
                        dish: dishes[i],
                        onTap: () => _openEditor(dishes[i]),
                      ),
                    ),
            ),
          ),
        ],
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
  const _DishCard({required this.dish, required this.onTap});

  final Dish dish;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final url = s.imageUrlOf(dish);

    return GestureDetector(
      onTap: onTap,
      child: Container(
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
                  if (!dish.isAvailable)
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
                                  child: TagChip(f,
                                      color: scheme.tertiary),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
