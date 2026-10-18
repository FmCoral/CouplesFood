import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/problem.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'dish_photo.dart';

/// 超管独立界面
///
/// 设计约束（来自产品决策）：
/// - 只读：能看情侣的菜品和订单，但不能改、不能造数据
/// - 能强制解散
/// - 能重置密码
/// - 和情侣端完全隔离，登录后不会进入情侣主流程
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

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
        title: const Row(
          children: [
            Text('管理后台'),
            SizedBox(width: 8),
            TagChip('只读'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout, size: 20),
            onPressed: () async {
              final ok = await confirm(context, title: '退出登录', okText: '退出');
              if (ok && context.mounted) await s.logout();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          indicatorColor: scheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: const [
            Tab(text: '状态'),
            Tab(text: '情侣'),
            Tab(text: '用户'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: const [
          _StatusTab(),
          _CouplesTab(),
          _UsersTab(),
        ],
      ),
    );
  }
}

// ---------------- 状态 ----------------

class _StatusTab extends StatefulWidget {
  const _StatusTab();

  @override
  State<_StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<_StatusTab> {
  Map<String, dynamic>? _status;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    try {
      final r = await s.api.get<Map<String, dynamic>>('/admin/status');
      if (mounted) setState(() {
        _status = r;
        _error = null;
        _loading = false;
      });
    } on ApiProblem catch (e) {
      if (mounted) setState(() {
        _error = e.friendly;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Loading(label: '读取系统状态…');
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: '读取失败',
        subtitle: _error,
        action: FilledButton(onPressed: _load, style: FilledButton.styleFrom(minimumSize: const Size(120, 44)), child: const Text('重试')),
      );
    }

    final st = _status!;
    final scheme = Theme.of(context).colorScheme;
    final disk = st['disk'] as Map?;
    final backup = st['backup'] as Map?;

    int n(String k) => (st[k] as num?)?.toInt() ?? 0;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
        children: [
          Row(
            children: [
              _Metric(label: '在线设备', value: '${n('onlineUsers')}', icon: Icons.devices),
              const SizedBox(width: 10),
              _Metric(label: '活跃情侣', value: '${n('activeCouples')}', icon: Icons.favorite),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Metric(label: '总用户', value: '${n('totalUsers')}', icon: Icons.people_outline),
              const SizedBox(width: 10),
              _Metric(label: '24h 事件', value: '${n('eventsToday')}', icon: Icons.bolt),
            ],
          ),
          const SizedBox(height: 18),

          _Card(
            title: '关系',
            rows: [
              ('进行中', '${n('activeCouples')}'),
              ('解散中', '${n('dissolvingCouples')}'),
              ('已归档', '${n('archivedCouples')}'),
              ('近 5 分钟活跃用户', '${n('recentlyActiveUsers')}'),
            ],
          ),
          const SizedBox(height: 14),

          if (disk != null)
            _Card(
              title: '磁盘',
              rows: [
                ('总容量', '${disk['totalGb']} GB'),
                ('剩余', '${disk['freeGb']} GB'),
                ('已用', '${disk['usedPercent']}%'),
              ],
            ),
          if (disk != null) const SizedBox(height: 14),

          _Card(
            title: '备份',
            rows: [
              ('最近备份', _fmtTime(backup?['lastAt'])),
              ('大小', '${backup?['lastSizeMb'] ?? 0} MB'),
              ('保留份数', '${backup?['count'] ?? 0}'),
            ],
            footer: Text(
              '每天 03:00 自动备份到 /data/backup，只保留最近 3 份。',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text('数据只读，管理端不能新增或修改任何业务数据',
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  static String _fmtTime(dynamic iso) {
    if (iso == null) return '无';
    final t = DateTime.tryParse(iso.toString());
    if (t == null) return '无';
    final l = t.toLocal();
    final d = DateTime.now().difference(l);
    final s = '${l.month}/${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
    if (d.inMinutes < 60) return '$s（${d.inMinutes} 分钟前）';
    if (d.inHours < 24) return '$s（${d.inHours} 小时前）';
    return '$s（${d.inDays} 天前）';
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 17, color: scheme.primary),
            const SizedBox(height: 10),
            Text(value,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.rows, this.footer});
  final String title;
  final List<(String, String)> rows;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                children: [
                  Text(r.$1,
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const Spacer(),
                  Text(r.$2,
                      style: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          if (footer != null) ...[const SizedBox(height: 4), footer!],
        ],
      ),
    );
  }
}

// ---------------- 情侣列表 ----------------

class _CouplesTab extends StatefulWidget {
  const _CouplesTab();

  @override
  State<_CouplesTab> createState() => _CouplesTabState();
}

class _CouplesTabState extends State<_CouplesTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  String? _error;
  String _status = 'active';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = context.read<AppState>();
    try {
      final r = await s.api.get<List<dynamic>>('/admin/couples', query: {
        'status': _status,
        'limit': 100,
      });
      if (mounted) setState(() {
        _list = r.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _error = null;
        _loading = false;
      });
    } on ApiProblem catch (e) {
      if (mounted) setState(() {
        _error = e.friendly;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            children: [
              for (final m in const [
                ['active', '进行中'],
                ['dissolving', '解散中'],
                ['dissolved', '已归档'],
                ['all', '全部'],
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _status = m[0]);
                      _load();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
                      decoration: BoxDecoration(
                        color: _status == m[0] ? scheme.primary : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                            color: _status == m[0]
                                ? scheme.primary
                                : scheme.outlineVariant.withValues(alpha: 0.7)),
                      ),
                      child: Text(m[1],
                          style: TextStyle(
                            fontSize: 12.5,
                            color: _status == m[0] ? Colors.white : scheme.onSurface,
                            fontWeight:
                                _status == m[0] ? FontWeight.w600 : FontWeight.w400,
                          )),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Loading()
              : _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off,
                      title: '读取失败',
                      subtitle: _error,
                      action: FilledButton(
                          onPressed: _load,
                          style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
                          child: const Text('重试')),
                    )
                  : _list.isEmpty
                      ? EmptyState(
                          icon: Icons.favorite_border,
                          title: '没有${_status == 'all' ? '' : '该状态的'}情侣',
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
                            itemCount: _list.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (c, i) => _CoupleCard(
                              data: _list[i],
                              onOpen: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => AdminCoupleDetail(coupleId: _list[i]['id'] as String),
                                ),
                              ),
                              onChanged: _load,
                            ),
                          ),
                        ),
        ),
      ],
    );
  }
}

class _CoupleCard extends StatelessWidget {
  const _CoupleCard({required this.data, required this.onOpen, required this.onChanged});

  final Map<String, dynamic> data;
  final VoidCallback onOpen;
  final VoidCallback onChanged;

  String get _statusLabel => switch (data['status']) {
        'active' => '进行中',
        'dissolving' => '解散中',
        'dissolved' => '已归档',
        _ => '${data['status']}',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final members = (data['members'] as List?)?.whereType<Map>().toList() ?? [];
    final archived = data['status'] == 'dissolved';

    return GestureDetector(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(15),
          border: archived
              ? null
              : Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    members.map((m) => m['nickname']?.toString() ?? '?').join('  ❤  '),
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                  ),
                ),
                TagChip(_statusLabel,
                    color: archived ? scheme.onSurfaceVariant : scheme.primary),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              members.map((m) => '${m['phone']}').join('  /  '),
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _mini(Icons.restaurant, '${data['dishCount'] ?? 0} 道菜'),
                const SizedBox(width: 14),
                _mini(Icons.receipt_long, '${data['orderCount'] ?? 0} 单'),
                const Spacer(),
                Icon(Icons.chevron_right, size: 17, color: scheme.outline),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _mini(IconData i, String t) {
    return Builder(builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return Row(
        children: [
          Icon(i, size: 13, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(t, style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
        ],
      );
    });
  }
}

// ---------------- 情侣详情（只读） ----------------

class AdminCoupleDetail extends StatefulWidget {
  const AdminCoupleDetail({super.key, required this.coupleId});
  final String coupleId;

  @override
  State<AdminCoupleDetail> createState() => _AdminCoupleDetailState();
}

class _AdminCoupleDetailState extends State<AdminCoupleDetail>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _menu = [];
  List<Map<String, dynamic>> _orders = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = context.read<AppState>();
    try {
      final results = await Future.wait([
        s.api.get<List<dynamic>>('/admin/couples/${widget.coupleId}/menu'),
        s.api.get<List<dynamic>>('/admin/couples/${widget.coupleId}/orders'),
      ]);
      if (!mounted) return;
      setState(() {
        _menu = (results[0]).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _orders = (results[1]).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
        _error = null;
      });
    } on ApiProblem catch (e) {
      if (mounted) setState(() {
        _error = e.friendly;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('情侣详情'),
        actions: [
          IconButton(
            tooltip: '强制解散',
            icon: Icon(Icons.gavel_outlined, size: 20, color: scheme.error),
            onPressed: _forceDissolve,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          labelColor: scheme.primary,
          unselectedLabelColor: scheme.onSurfaceVariant,
          indicatorColor: scheme.primary,
          indicatorSize: TabBarIndicatorSize.label,
          tabs: [Tab(text: '菜品 ${_menu.length}'), Tab(text: '订单 ${_orders.length}')],
        ),
      ),
      body: _loading
          ? const Loading()
          : _error != null
              ? EmptyState(icon: Icons.cloud_off, title: '读取失败', subtitle: _error)
              : TabBarView(
                  controller: _tab,
                  children: [
                    _menu.isEmpty
                        ? const EmptyState(icon: Icons.ramen_dining_outlined, title: '菜单为空')
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                            itemCount: _menu.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (c, i) {
                              final d = _menu[i];
                              final flavors =
                                  (d['flavors'] as List?)?.map((e) => e.toString()).toList() ?? [];
                              return Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 46,
                                      height: 46,
                                      child: DishPhoto(
                                        url: (d['imageUrl'] ?? '').toString(),
                                        name: (d['name'] ?? '').toString(),
                                        radius: 8,
                                      ),
                                    ),
                                    const SizedBox(width: 11),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Flexible(
                                                child: Text(
                                                  (d['name'] ?? '').toString(),
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w500),
                                                ),
                                              ),
                                              if (d['deletedAt'] != null) ...[
                                                const SizedBox(width: 6),
                                                TagChip('已删',
                                                    color: scheme.onSurfaceVariant),
                                              ],
                                              if (d['isAvailable'] == false) ...[
                                                const SizedBox(width: 6),
                                                TagChip('下架'),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            [
                                              if ((d['typeName'] ?? '').toString().isNotEmpty)
                                                d['typeName'].toString(),
                                              ...flavors,
                                            ].join(' · '),
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color: scheme.onSurfaceVariant),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                    _orders.isEmpty
                        ? const EmptyState(icon: Icons.receipt_long_outlined, title: '没有订单')
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                            itemCount: _orders.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (c, i) {
                              final o = _orders[i];
                              final items = (o['items'] as List?) ?? [];
                              final summary = items
                                  .whereType<Map>()
                                  .map((e) {
                                    final q = (e['quantity'] as num?)?.toInt() ?? 1;
                                    final n = e['name']?.toString() ?? '';
                                    return q > 1 ? '$n×$q' : n;
                                  })
                                  .join('、');
                              return Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        TagChip(_orderLabel(o['status']?.toString() ?? '')),
                                        const SizedBox(width: 8),
                                        Text(_meal(o['meal_type']?.toString() ?? ''),
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color: scheme.onSurfaceVariant)),
                                        const Spacer(),
                                        Text(_shortTime(o['created_at']),
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: scheme.onSurfaceVariant)),
                                      ],
                                    ),
                                    const SizedBox(height: 7),
                                    Text(summary.isEmpty ? '（无明细）' : summary,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13.5, height: 1.4)),
                                  ],
                                ),
                              );
                            },
                          ),
                  ],
                ),
    );
  }

  static String _orderLabel(String s) => switch (s) {
        'pending' => '待接单',
        'accepted' => '已接单',
        'cooking' => '烹饪中',
        'served' => '已出餐',
        'completed' => '已完成',
        'rejected' => '被拒绝',
        'cancelled' => '已取消',
        _ => s,
      };

  static String _meal(String s) => switch (s) {
        'breakfast' => '早餐',
        'lunch' => '午餐',
        'dinner' => '晚餐',
        'night_snack' => '夜宵',
        _ => s,
      };

  static String _shortTime(dynamic iso) {
    final t = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
    if (t == null) return '';
    return '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _forceDissolve() async {
    final note = await promptText(
      context,
      title: '强制解散这段关系',
      hint: '填写原因（会记入审计日志）',
      maxLength: 200,
    );
    if (note == null || note.isEmpty || !mounted) return;

    final ok = await confirm(
      context,
      title: '确认强制解散？',
      body: '双方会立刻解除关系，菜单和订单归档保留。该操作会记入审计日志。',
      okText: '强制解散',
      danger: true,
    );
    if (!ok || !mounted) return;

    final s = context.read<AppState>();
    await runGuarded(context, () async {
      await s.api.post<Map<String, dynamic>>(
          '/admin/couples/${widget.coupleId}/dissolve', {'reason': note});
    }, success: '已强制解散');
    if (mounted) Navigator.of(context).maybePop();
  }
}

// ---------------- 用户列表 ----------------

class _UsersTab extends StatefulWidget {
  const _UsersTab();

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = context.read<AppState>();
    try {
      final r = await s.api.get<List<dynamic>>('/admin/users', query: {'limit': 100});
      if (mounted) setState(() {
        _list = r.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        _loading = false;
        _error = null;
      });
    } on ApiProblem catch (e) {
      if (mounted) setState(() {
        _error = e.friendly;
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _resetPassword(Map<String, dynamic> u) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('重置 ${u['nickname']} 的密码'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新密码（至少 8 位）', isDense: true),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(minimumSize: const Size(88, 42)),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    final pwd = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || pwd.length < 8 || !mounted) {
      if (mounted && ok == true && pwd.length < 8) {
        context.snack('新密码至少 8 位', error: true);
      }
      return;
    }

    final s = context.read<AppState>();
    await runGuarded(context, () async {
      await s.api.post<Map<String, dynamic>>(
          '/admin/users/${u['id']}/reset-password', {'newPassword': pwd});
    }, success: '已重置，该用户需要重新登录');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_loading) return const Loading();
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off,
        title: '读取失败',
        subtitle: _error,
        action: FilledButton(
            onPressed: _load,
            style: FilledButton.styleFrom(minimumSize: const Size(120, 44)),
            child: const Text('重试')),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
        itemCount: _list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (c, i) {
          final u = _list[i];
          final isAdmin = u['isAdmin'] == true;
          final last = DateTime.tryParse(u['lastSeenAt']?.toString() ?? '')?.toLocal();

          return Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(u['nickname']?.toString() ?? '?',
                              style: const TextStyle(
                                  fontSize: 14.5, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 7),
                          if (isAdmin) TagChip('超管'),
                          if (u['isActive'] == false) ...[
                            const SizedBox(width: 6),
                            TagChip('已停用', color: scheme.error),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        [
                          u['phone']?.toString() ?? '',
                          if (last != null)
                            '最近 ${last.month}/${last.day} ${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}',
                        ].join('　'),
                        style:
                            TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                if (!isAdmin)
                  TextButton(
                    onPressed: () => _resetPassword(u),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 34),
                    ),
                    child: const Text('重置密码', style: TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
