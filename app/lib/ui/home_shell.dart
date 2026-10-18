import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'dissolve_sheet.dart';
import 'menu_page.dart';
import 'orders_page.dart';
import 'profile_page.dart';

/// 主壳：三个 Tab + 全局冻结/解散提示条
///
/// 解散申请一旦发起，整个 App 变成只读。这里用一条常驻横幅把这件事
/// 讲清楚，而不是让用户在点"保存"时才吃到报错。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    final dissolution = s.couple?.dissolution;
    final iAmInitiator = s.couple?.iInitiatedDissolution ?? false;

    // 对方发起的解散：置顶强提示，必须处理
    final needMyDecision = dissolution != null && !iAmInitiator;

    return Scaffold(
      body: Column(
        children: [
          if (needMyDecision)
            _Banner(
              color: Theme.of(context).colorScheme.error,
              icon: Icons.warning_amber_rounded,
              text: '对方申请解除关系，菜单已冻结为只读',
              actionLabel: '去处理',
              onAction: () => showDissolveSheet(context),
            )
          else if (dissolution != null)
            _Banner(
              color: Theme.of(context).colorScheme.tertiary,
              icon: Icons.pause_circle_outline,
              text: '解散申请处理中，当前只能查看',
              actionLabel: '撤回',
              onAction: () => showDissolveSheet(context),
            ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: const [
                MenuPage(),
                OrdersPage(),
                ProfilePage(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.restaurant_menu_outlined),
            selectedIcon: Icon(Icons.restaurant_menu),
            label: '菜单',
          ),
          NavigationDestination(
            icon: _OrdersIcon(open: s.activeOrders.length, selected: false),
            selectedIcon: _OrdersIcon(open: s.activeOrders.length, selected: true),
            label: '订单',
          ),
          const NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

/// 订单 Tab 上带未处理数量的小红点
class _OrdersIcon extends StatelessWidget {
  const _OrdersIcon({required this.open, required this.selected});
  final int open;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(selected ? Icons.receipt_long : Icons.receipt_long_outlined);
    if (open == 0) return icon;
    return Badge(
      label: Text('$open', style: const TextStyle(fontSize: 10)),
      child: icon,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final Color color;
  final IconData icon;
  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withValues(alpha: 0.10),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(icon, size: 17, color: color),
              const SizedBox(width: 9),
              Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 12.6, color: color, fontWeight: FontWeight.w500)),
              ),
              TextButton(
                onPressed: onAction,
                style: TextButton.styleFrom(
                  foregroundColor: color,
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                child: Text(actionLabel, style: const TextStyle(fontSize: 12.6)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
