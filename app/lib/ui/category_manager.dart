import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/problem.dart';
import '../state/app_state.dart';
import 'common.dart';

/// 分类管理：种类 / 口味 两个维度共用（接口完全对称）
class CategoryManager extends StatefulWidget {
  const CategoryManager({super.key, required this.kind});

  /// type | flavor
  final String kind;

  @override
  State<CategoryManager> createState() => _CategoryManagerState();
}

class _CategoryManagerState extends State<CategoryManager> {
  bool _busy = false;

  bool get _isType => widget.kind == 'type';
  String get _title => _isType ? '种类' : '口味';

  List<Map<String, dynamic>> _list(AppState s) => _isType ? s.types : s.flavors;

  String get _base => _isType ? '/dish-types' : '/dish-flavors';

  Future<void> _add() async {
    final name = await promptText(
      context,
      title: '新增$_title',
      hint: '比如 ${_isType ? "家常菜" : "微辣"}',
      maxLength: 12,
    );
    if (name == null || !mounted) return;

    setState(() => _busy = true);
    final s = context.read<AppState>();
    final ok = await runGuarded(context, () async {
      await s.api.post<Map<String, dynamic>>(_base, {'name': name});
      await s.sync.refreshCategories();
    }, success: '已添加「$name」');
    if (mounted) setState(() => _busy = false);
    if (!ok) return;
  }

  Future<void> _rename(Map<String, dynamic> item) async {
    final id = (item['id'] ?? '').toString();
    final old = (item['name'] ?? '').toString();
    final name = await promptText(context, title: '重命名', initial: old, maxLength: 12);
    if (name == null || name == old || !mounted) return;

    setState(() => _busy = true);
    final s = context.read<AppState>();
    await runGuarded(context, () async {
      await s.api.patch<Map<String, dynamic>>('$_base/$id', {'name': name});
      await s.sync.refreshCategories();
      await s.sync.refreshMenu();
    }, success: '已改名');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final id = (item['id'] ?? '').toString();
    final name = (item['name'] ?? '').toString();
    final count = (item['dishCount'] as num?)?.toInt() ?? 0;

    final ok = await confirm(
      context,
      title: '删除「$name」？',
      body: count > 0
          ? '有 $count 道菜用了这个$_title，删除后它们会变成未分类，菜品本身不会丢。'
          : '没有菜品使用这个$_title，可以安全删除。',
      okText: '删除',
      danger: true,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    final s = context.read<AppState>();
    try {
      final r = await s.api.delete<Map<String, dynamic>>('$_base/$id');
      final affected = (r['affectedDishes'] as num?)?.toInt() ?? 0;
      await s.sync.refreshCategories();
      await s.sync.refreshMenu();
      if (mounted) {
        context.snack(affected > 0 ? '已删除，$affected 道菜变为未分类' : '已删除');
      }
    } on ApiProblem catch (e) {
      if (mounted) context.snack(e.friendly, error: true);
    } catch (e) {
      if (mounted) context.snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final scheme = Theme.of(context).colorScheme;
    final list = _list(s);

    return Scaffold(
      appBar: AppBar(
        title: Text('$_title管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            onPressed: _busy ? null : _add,
            tooltip: '新增',
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: list.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 18,
          endIndent: 18,
          color: scheme.outlineVariant.withValues(alpha: 0.4),
        ),
        itemBuilder: (c, i) {
          final item = list[i];
          final name = (item['name'] ?? '').toString();
          final count = (item['dishCount'] as num?)?.toInt() ?? 0;
          final preset = item['isPreset'] == true;

          return ListTile(
            title: Row(
              children: [
                Text(name, style: const TextStyle(fontSize: 14.5)),
                if (preset) ...[
                  const SizedBox(width: 7),
                  TagChip('预设', color: scheme.onSurfaceVariant),
                ],
              ],
            ),
            subtitle: Text('$count 道菜',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
            trailing: PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (v) {
                if (v == 'rename') _rename(item);
                if (v == 'delete') _delete(item);
              },
              itemBuilder: (c2) => [
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('删除', style: TextStyle(color: Colors.red)),
                ),
              ],
            ),
            onTap: () => _rename(item),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : _add,
            icon: const Icon(Icons.add, size: 18),
            label: Text('新增$_title'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
          ),
        ),
      ),
    );
  }

}
