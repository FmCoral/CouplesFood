import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_editor.dart';
import 'dish_photo.dart';

/// 菜单管理：菜品的增删改查入口
///
/// 从「我的 → 菜单 → 菜单管理」进入。点菜在「菜单」Tab 完成，这里只管维护。
class MenuManagerPage extends StatefulWidget {
  const MenuManagerPage({super.key});

  @override
  State<MenuManagerPage> createState() => _MenuManagerPageState();
}

class _MenuManagerPageState extends State<MenuManagerPage> {
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
    final dishes = s.dishes;

    return Scaffold(
      appBar: AppBar(
        title: const Text('菜单管理'),
        actions: [
          const Center(
              child: Padding(padding: EdgeInsets.only(right: 4), child: SyncBadge())),
        ],
      ),
      floatingActionButton: s.isFrozen
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('加菜'),
            ),
      body: RefreshIndicator(
        onRefresh: () async {
          await s.sync.refreshMenu().catchError((_) {});
        },
        child: dishes.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: EmptyState(
                      icon: Icons.ramen_dining_outlined,
                      title: '还没有菜',
                      subtitle: '点右下角加一道，\n对方点菜时就能看到。',
                      action: s.isFrozen
                          ? null
                          : FilledButton(
                              onPressed: () => _openEditor(),
                              style:
                                  FilledButton.styleFrom(minimumSize: const Size(150, 46)),
                              child: const Text('加第一道菜'),
                            ),
                    ),
                  ),
                ],
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 100),
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: dishes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (c, i) {
                  final d = dishes[i];
                  return _DishRow(
                    dish: d,
                    onTap: () => _openEditor(d),
                  );
                },
              ),
      ),
    );
  }
}

class _DishRow extends StatelessWidget {
  const _DishRow({required this.dish, required this.onTap});

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
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: DishPhoto(url: url, name: dish.name, radius: 10),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(dish.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w600)),
                      ),
                      if (!dish.isAvailable)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: scheme.outlineVariant.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('已下架',
                              style: TextStyle(fontSize: 10.5, color: Colors.white)),
                        ),
                    ],
                  ),
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
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          ],
        ),
      ),
    );
  }
}
